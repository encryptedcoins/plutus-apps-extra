{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MonoLocalBinds        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE NumericUnderscores    #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use uncurry"            #-}

-- | Implements a custom currency with a minting policy that allows
--   the minting of a fixed amount of units.
module PlutusAppsExtra.Scripts.OneShotCurrency
    ( -- Types
      OneShotCurrencyParams (..)
      -- On-Chain
    , oneShotCurrencyPolicy
      -- Off-Chain
    , mkCurrency
    , currencySymbol
    , currencyValue
    , oneShotCurrencyMintTx
    ) where

import           Data.Aeson                           (FromJSON, ToJSON)
import           GHC.Generics                         (Generic)
import           Ledger                               (DecoratedTxOut, Language (..), Versioned (..))
import           Ledger.Typed.Scripts                 (mkUntypedMintingPolicy)
import           Plutus.Script.Utils.V2.Scripts       (MintingPolicy, scriptCurrencySymbol)
import           Plutus.V2.Ledger.Api                 (CurrencySymbol, ScriptContext (..), TokenName, TxInfo (..), TxOutRef (..),
                                                       mkMintingPolicyScript, singleton)
import           Plutus.V2.Ledger.Contexts            (ownCurrencySymbol, spendsOutput)
import qualified PlutusTx
import qualified PlutusTx.AssocMap                    as AssocMap
import           PlutusTx.Prelude                     hiding (Monoid (..), Semigroup (..))
import qualified Prelude                              as Haskell

import qualified Plutus.V2.Ledger.Api                 as P
import           PlutusAppsExtra.Constraints.OffChain (tokensMintedTx, utxoSpentPublicKeyTx)
import           PlutusAppsExtra.Types.Tx             (TransactionBuilder)

---------------------------------- Types ------------------------------------

data OneShotCurrencyParams = OneShotCurrencyParams
    {
        curRef         :: TxOutRef,
        curAmounts     :: AssocMap.Map TokenName Integer
    }
    deriving stock (Generic, Haskell.Show, Haskell.Eq)
    deriving anyclass (ToJSON, FromJSON)

PlutusTx.makeLift ''OneShotCurrencyParams

-------------------------------- On-Chain ------------------------------------

oneShotCurrencyValue :: CurrencySymbol -> OneShotCurrencyParams -> P.Value
oneShotCurrencyValue s OneShotCurrencyParams{curAmounts = amts} =
    let values = map (\(tn, i) -> singleton s tn i) (AssocMap.toList amts)
    in fold values

checkPolicy :: OneShotCurrencyParams -> () -> ScriptContext -> Bool
checkPolicy c@(OneShotCurrencyParams (TxOutRef refHash refIdx) _) _ ctx@ScriptContext{scriptContextTxInfo=txinfo} =
    let ownSymbol = ownCurrencySymbol ctx

        minted = txInfoMint txinfo
        expected = oneShotCurrencyValue ownSymbol c

        -- True if the pending transaction mints the amount of
        -- currency that we expect
        mintOK =
            let v = expected == minted
            in traceIfFalse "C0" {-"Value minted different from expected"-} v

        -- True if the pending transaction spends the output
        -- identified by @(refHash, refIdx)@
        txOutputSpent =
            let v = spendsOutput txinfo refHash refIdx
            in  traceIfFalse "C1" {-"Pending transaction does not spend the designated transaction output"-} v

    in mintOK && txOutputSpent

oneShotCurrencyPolicy :: OneShotCurrencyParams -> MintingPolicy
oneShotCurrencyPolicy cur = mkMintingPolicyScript $
    $$(PlutusTx.compile [|| mkUntypedMintingPolicy . checkPolicy ||])
        `PlutusTx.applyCode`
            PlutusTx.liftCode cur

-------------------------------- Off-Chain -----------------------------------

mkCurrency :: TxOutRef -> [(TokenName, Integer)] -> OneShotCurrencyParams
mkCurrency ref amts =
    OneShotCurrencyParams
        {
            curRef     = ref,
            curAmounts = AssocMap.fromList amts
        }

currencySymbol :: OneShotCurrencyParams -> CurrencySymbol
currencySymbol = scriptCurrencySymbol . oneShotCurrencyPolicy

currencyValue :: OneShotCurrencyParams -> P.Value
currencyValue cur = oneShotCurrencyValue (currencySymbol cur) cur

-- Constraints that the OneShotCurrency is minted in the transaction
oneShotCurrencyMintTx :: OneShotCurrencyParams -> TransactionBuilder (Maybe (TxOutRef, DecoratedTxOut))
oneShotCurrencyMintTx par@(OneShotCurrencyParams ref _) = do
    tokensMintedTx (flip Versioned PlutusV2 $ oneShotCurrencyPolicy par) () (currencyValue par)
    utxoSpentPublicKeyTx (\r _ -> r == ref)