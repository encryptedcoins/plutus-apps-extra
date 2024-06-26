{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE NumericUnderscores   #-}
{-# LANGUAGE PatternSynonyms      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE UndecidableInstances #-}

module PlutusAppsExtra.IO.ChainIndex.Plutus where

import           Cardano.Api                      (FromJSON, ToJSON)
import           Control.Applicative              (Applicative (..))
import           Control.Monad.Extra              (mconcatMapM)
import           Control.Monad.IO.Class           (MonadIO (..))
import           Data.Default                     (Default (def))
import           Data.Map                         (Map)
import qualified Data.Map                         as Map
import           Data.Maybe                       (catMaybes)
import           GHC.Generics                     (Generic)
import           Ledger                           (Address, CardanoTx, DecoratedTxOut (..), POSIXTime, TxOutRef (..))
import           Network.HTTP.Client              (HttpExceptionContent, Request)
import           Plutus.ChainIndex                (ChainIndexTx, Page (..), PageQuery)
import           Plutus.ChainIndex.Api            (UtxoAtAddressRequest (..), UtxoWithCurrencyRequest (..), UtxosResponse (..))
import qualified Plutus.ChainIndex.Client         as Client
import           Plutus.ChainIndex.Types          (ChainIndexTx (_citxCardanoTx))
import           Plutus.V1.Ledger.Address         (Address (addressCredential))
import           Plutus.V1.Ledger.Value           (AssetClass)
import           Plutus.V2.Ledger.Tx              (TxId)
import           PlutusAppsExtra.IO.Time          (currentTime)
import           PlutusAppsExtra.Types.Error      (ConnectionError)
import           PlutusAppsExtra.Utils.ChainIndex (MapUTXO)
import           PlutusAppsExtra.Utils.Servant    (Endpoint, getFromEndpointOnPort, handle404Maybe, pattern ConnectionErrorOnPort)
import           PlutusTx.Prelude                 hiding (fmap, mapM, mconcat, pure, traverse, (<$>), (<>))
import           Prelude                          (IO, Show (..), fmap, mapM, traverse, (<$>), (<>))

----------------------------------- Chain index cache -----------------------------------

data ChainIndexCache = ChainIndexCache {
    cacheAddresses  :: [Address],
    cacheData       :: MapUTXO,
    cacheTime       :: POSIXTime
}
    deriving (Show, Generic, FromJSON, ToJSON)

newCache :: [Address] -> ChainIndexCache
newCache addresses = ChainIndexCache addresses Map.empty 0

-- Cache validity is 30 seconds
cacheValidityPeriod :: POSIXTime
cacheValidityPeriod = 30_000

class HasUtxoData m where
    updateChainIndexCache :: ChainIndexCache -> m ChainIndexCache

instance MonadIO m => HasUtxoData m where
    updateChainIndexCache oldCache@(ChainIndexCache addrs _ cTime) = do
        curTime <- currentTime
        if curTime - cTime <= cacheValidityPeriod
            then return oldCache
            else do
                utxos <- liftIO $ mconcatMapM getUtxosAt addrs
                ChainIndexCache addrs utxos <$> currentTime

----------------------------------- Chain index queries ---------------------------------

getFromEndpointChainIndex :: Endpoint a
getFromEndpointChainIndex = getFromEndpointOnPort 9083

pattern PlutusChainIndexConnectionError :: Request -> HttpExceptionContent -> ConnectionError
pattern PlutusChainIndexConnectionError req content <- ConnectionErrorOnPort 9083 req content

-- Get all utxos at a given address
getUtxosAt :: Address -> IO MapUTXO
getUtxosAt addr = Map.mapMaybe id <$> foldUtxoRefsAt f Map.empty addr
    where
        f acc page' = do
          let utxoRefs = pageItems page'
          txOuts <- traverse (fmap Just . getUnspentTxOutFromRef) utxoRefs
          let utxos = Map.fromList
                    $ mapMaybe (\(ref, txOut) -> fmap (ref,) txOut)
                    $ zip utxoRefs txOuts
          pure $ acc <> utxos

-- Get all utxos and txs at a given address
getUtxosTxsAt :: Address -> IO (Map TxOutRef (DecoratedTxOut, ChainIndexTx))
getUtxosTxsAt addr = do
        refTxOuts <- Map.toList <$> foldUtxoRefsAt f Map.empty addr
        let txIds = map (txOutRefId . fst) refTxOuts
        ciTxs <- getFromEndpointChainIndex $ Client.getTxs txIds
        pure $ Map.fromList $ catMaybes $ zipWith (\tx (ref, mbTxOut) -> (ref,) . (,tx) <$> mbTxOut) ciTxs refTxOuts
    where
        f acc page' = do
            let utxoRefs = pageItems page'
            txOuts <- traverse (fmap Just . getUnspentTxOutFromRef) utxoRefs
            let utxos = Map.fromList
                      $ mapMaybe (\(ref, txOut) -> fmap (ref,) txOut)
                      $ zip utxoRefs txOuts
            pure $ acc <> utxos

-- Fold through each 'Page's of unspent 'TxOutRef's at a given 'Address', and
-- accumulate the result.
foldUtxoRefsAt :: forall a.
    (a -> Page TxOutRef -> IO a) -- ^ Accumulator function
    -> a -- ^ Initial value
    -> Address -- ^ Address which contain the UTXOs
    -> IO a
foldUtxoRefsAt f ini addr = go ini (Just def)
    where
        go acc Nothing = pure acc
        go acc (Just pq) = do
            page' <- page <$> utxoRefsAt pq addr
            newAcc <- f acc page'
            go newAcc (nextPageQuery page')

getUnspentTxOutFromRef :: TxOutRef -> IO (Maybe DecoratedTxOut)
getUnspentTxOutFromRef = handle404Maybe. getFromEndpointChainIndex . Client.getUnspentTxOut

-- Get the unspent transaction output references at an address.
utxoRefsAt :: PageQuery TxOutRef -> Address -> IO UtxosResponse
utxoRefsAt pageQ =
    getFromEndpointChainIndex . Client.getUtxoSetAtAddress . UtxoAtAddressRequest (Just pageQ) . addressCredential

getChainIndexTxFromId :: TxId -> IO (Maybe ChainIndexTx)
getChainIndexTxFromId = handle404Maybe . getFromEndpointChainIndex . Client.getTx

getTxFromId :: TxId -> IO (Maybe CardanoTx)
getTxFromId = fmap (>>= _citxCardanoTx) . getChainIndexTxFromId

getUtxosWithCurrency :: AssetClass -> IO MapUTXO
getUtxosWithCurrency asset = go [] (Just def)
    >>= fmap (Map.fromList . catMaybes) . mapM (\ref -> fmap sequence $ (ref,) <$> getUnspentTxOutFromRef ref)
    where
        go acc Nothing = pure acc
        go acc (Just pq) = do
            page' <- page <$> getFromEndpointChainIndex (Client.getUtxoSetWithCurrency $ UtxoWithCurrencyRequest (Just pq) asset)
            let newAcc = acc <> pageItems page'
            go newAcc (nextPageQuery page')