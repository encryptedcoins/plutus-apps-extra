{-# LANGUAGE RankNTypes #-}

module Utils.Servant where

import           Control.Exception                 (throw)
import           Control.Monad.IO.Class            (MonadIO(..))
import           Servant.Client                    (mkClientEnv, runClientM, ClientM, BaseUrl(..), Scheme(..) )
import           Network.HTTP.Client               (newManager, defaultManagerSettings)

type Endpoint a = forall m. MonadIO m => ClientM a -> m a

getFromEndpointOnPort :: Int -> Endpoint a
getFromEndpointOnPort port endpoint = liftIO $ do
    manager <- newManager defaultManagerSettings
    responseOrError <- runClientM 
        endpoint
        (mkClientEnv manager (BaseUrl Http "localhost" port ""))
    case responseOrError of
        Left err       -> throw err -- "Error while accessing the endpoint."
        Right response -> pure response