{-# LANGUAGE LambdaCase          #-}

module PlutusAppsExtra.IO.Node where

import           Cardano.Api.Shelley                                 (CardanoMode, ConsensusModeParams (..), EpochSlots (..),
                                                                      LocalChainSyncClient (NoLocalChainSyncClient),
                                                                      LocalNodeClientProtocols (..), LocalNodeConnectInfo (..),
                                                                      NetworkId, TxInMode (..), TxValidationErrorInMode,
                                                                      connectToLocalNode)
import           Control.Concurrent.STM                              (atomically, newEmptyTMVarIO, putTMVar, takeTMVar)
import           Control.Monad.Catch                                 (Exception (fromException), handle, throwM)
import           GHC.IO.Exception                                    (IOErrorType (NoSuchThing), IOException (..))
import           Ledger.Tx                                           (CardanoTx (..), SomeCardanoApiTx (..))
import           Ouroboros.Network.Protocol.LocalTxSubmission.Client (SubmitResult (..))
import qualified Ouroboros.Network.Protocol.LocalTxSubmission.Client as Net.Tx
import           PlutusAppsExtra.Types.Error                         (SubmitTxToLocalNodeError (..))

sumbitTxToNodeLocal
    :: FilePath
    -> NetworkId
    -> CardanoTx
    -> IO (Net.Tx.SubmitResult (TxValidationErrorInMode CardanoMode))
sumbitTxToNodeLocal socketPath networkId (CardanoApiTx (SomeTx txInEra eraInMode)) = handleConnectionAbscence $ do
        resultVar <- newEmptyTMVarIO
        _ <- connectToLocalNode
            connctInfo
            LocalNodeClientProtocols
                { localChainSyncClient    = NoLocalChainSyncClient
                , localTxSubmissionClient = Just (localTxSubmissionClientSingle resultVar)
                , localStateQueryClient   = Nothing
                , localTxMonitoringClient = Nothing
                }
        atomically (takeTMVar resultVar) >>= \case
            SubmitSuccess -> pure SubmitSuccess
            SubmitFail reason -> throwM $ FailedSumbit reason
    where
        connctInfo = LocalNodeConnectInfo
            { localConsensusModeParams = CardanoModeParams $ EpochSlots 0
            , localNodeNetworkId       = networkId
            , localNodeSocketPath      = socketPath
            }
        localTxSubmissionClientSingle resultVar =
            Net.Tx.LocalTxSubmissionClient
            $ pure $ Net.Tx.SendMsgSubmitTx (TxInMode txInEra eraInMode) $ \result -> do
                atomically $ putTMVar resultVar result
                pure (Net.Tx.SendMsgDone ())
sumbitTxToNodeLocal _ _ etx = throwM $ CantSubmitEmulatorTx etx

handleConnectionAbscence :: IO a -> IO a
handleConnectionAbscence = handle $ \e -> case fromException e of
    Just IOError{ioe_type = NoSuchThing} -> throwM NoConnectionToLocalNode
    _ -> throwM e