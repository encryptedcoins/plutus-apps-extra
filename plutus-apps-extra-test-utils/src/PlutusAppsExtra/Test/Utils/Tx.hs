{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications   #-}

module PlutusAppsExtra.Test.Utils.Tx where

import           Cardano.Api                          (BabbageEra, TxMetadataInEra)
import           Cardano.Node.Emulator                (Params (..))
import           Control.Exception                    (try)
import           Control.Monad                        (when)
import           Control.Monad.State                  (MonadIO (..), StateT, evalStateT, execState, get, modify)
import           Data.Either                          (isRight)
import qualified Data.Map                             as Map
import           Data.Maybe                           (fromJust, isNothing, listToMaybe, mapMaybe)
import           Ledger                               (Address (..), CardanoTx (..), DecoratedTxOut (..), TxOutRef (..), adaValueOf,
                                                       toCardanoValue)
import           Plutus.V1.Ledger.Api                 (Credential (..))
import qualified Plutus.V2.Ledger.Api                 as P
import           PlutusAppsExtra.Constraints.Balance  (balanceExternalTx)
import           PlutusAppsExtra.Constraints.OffChain (useAsCollateralTx')
import           PlutusAppsExtra.IO.Time              (currentTime)
import           PlutusAppsExtra.Test.Utils.Gen       (genTxOutRef)
import           PlutusAppsExtra.Types.Error          (BalanceExternalTxError)
import           PlutusAppsExtra.Types.Tx             (TransactionBuilder, TxConstructor (..), buildTxConstraints, mkTxConstructor)
import           PlutusAppsExtra.Utils.ChainIndex     (MapUTXO)
import           PlutusAppsExtra.Utils.Datum          (inlinedUnitInTxOut)
import           Test.Hspec                           (Expectation, expectationFailure, shouldSatisfy)
import           Test.QuickCheck                      (generate)

type TxTestM a = StateT TxTestState IO a

type TxTestState = MapUTXO

buildTx
    :: Params
    -> Maybe TxOutRef
    -> Address -> [TransactionBuilder ()]
    -> Maybe (TxMetadataInEra BabbageEra)
    -> TxTestM (Either BalanceExternalTxError CardanoTx)
buildTx pParams collateral addr txs mbMeta = get >>= \utxos -> liftIO $ do
    ct <- currentTime
    let constrInit = mkTxConstructor ct utxos
        txs' = map (useAsCollateralTx' collateral >>) txs
        lookupsAndCons = listToMaybe $ mapMaybe (`buildTxConstraints` constrInit) txs'
    when (isNothing lookupsAndCons) $ liftIO $ expectationFailure $ "AllConstructorsFailed:\n"
        <> show (concatMap (txConstructorErrors . (`execState` constrInit)) txs')
    let (lookups, cons) = fromJust lookupsAndCons
    try @BalanceExternalTxError $ balanceExternalTx pParams utxos addr lookups cons mbMeta

runTxTest :: TxTestM (Either BalanceExternalTxError CardanoTx) -> Expectation
runTxTest test = evalStateT test mempty >>= (`shouldSatisfy` isRight)

withAdaUtxo :: Integer -> Address -> TxTestM ()
withAdaUtxo i addr = do
    let val = adaValueOf $ fromInteger $ i * 1_000_000
        adaOut = case addr of
            (Address (PubKeyCredential pkh) mbSc) -> PublicKeyDecoratedTxOut pkh mbSc val Nothing Nothing
            (Address (ScriptCredential vh)  mbSc) -> ScriptDecoratedTxOut vh mbSc val inlinedUnitInTxOut Nothing Nothing
    ref <- liftIO $ generate genTxOutRef
    modify (<> Map.fromList [(ref, adaOut)])

withValueUtxo :: P.Value -> Address -> TxTestM ()
withValueUtxo val addr = do
    let val' = either (error . show) id $ toCardanoValue val
        tokensOut = case addr of
            (Address (PubKeyCredential pkh) mbSc) -> PublicKeyDecoratedTxOut pkh mbSc val' Nothing Nothing
            (Address (ScriptCredential vh)  mbSc) -> ScriptDecoratedTxOut vh mbSc val' inlinedUnitInTxOut Nothing Nothing
    ref <- liftIO $ generate genTxOutRef
    modify (<> Map.fromList [(ref, tokensOut)])