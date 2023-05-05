module PlutusAppsExtra.Utils.Scripts where

import           Cardano.Codec.Cbor    (toStrictByteString)
import qualified Codec.CBOR.Decoding   as CBOR
import           Codec.CBOR.Encoding   (encodeBytes)
import           Codec.CBOR.Read       (deserialiseFromBytes)
import           Codec.Serialise       (Serialise (encode), decode, deserialise, serialise)
import           Control.FromSum       (eitherToMaybe)
import qualified Data.ByteString.Lazy  as LBS
import           Data.ByteString.Short (ShortByteString)
import qualified Data.ByteString.Short as SBS
import           Data.Coerce           (coerce)
import qualified Flat
import qualified Flat.Decoder          as Flat
import           Ledger                (MintingPolicy (..), Script (..), Validator (..))
import           PlutusCore            (DefaultFun, DefaultUni)
import           Text.Hex              (Text, decodeHex, encodeHex)
import qualified UntypedPlutusCore     as UPLC

validatorToCBOR :: Validator -> Text
validatorToCBOR = encodeHex . toStrictByteString . encodeBytes . LBS.toStrict  . serialise

validatorFromCBOR :: Text -> Maybe Validator
validatorFromCBOR txt = do
    bs  <- decodeHex txt
    res <- eitherToMaybe $ deserialiseFromBytes CBOR.decodeBytes $ LBS.fromStrict bs
    deserialise $ LBS.fromStrict $ snd res

mintingPolicyToCBOR :: MintingPolicy -> Text
mintingPolicyToCBOR = encodeHex . SBS.fromShort . serialiseUPLC . coerce

mintingPolicyFromCBOR :: Text -> Maybe MintingPolicy
mintingPolicyFromCBOR = fmap (coerce . deserialiseUPLC . SBS.toShort) . decodeHex

type SerialisedScript = ShortByteString

serialiseUPLC :: UPLC.Program UPLC.DeBruijn DefaultUni DefaultFun () -> SerialisedScript
serialiseUPLC =
    -- See Note [Using Flat for serialising/deserialising Script]
    -- Currently, this is off because the old implementation didn't actually work, so we need to be careful
    -- about introducing a working versioPlutusLedgerApi.Common.SerialisedScriptn
    SBS.toShort . LBS.toStrict . serialise . SerialiseViaFlat

-- | Deserialises a 'SerialisedScript' back into an AST.
deserialiseUPLC :: SerialisedScript -> UPLC.Program UPLC.DeBruijn DefaultUni DefaultFun ()
deserialiseUPLC = unSerialiseViaFlat . deserialise . LBS.fromStrict . SBS.fromShort
    where
        unSerialiseViaFlat (SerialiseViaFlat a) = a

-- | Newtype to provide 'Serialise' instances for types with a 'Flat' instance that
-- just encodes the flat-serialized value as a CBOR bytestring
newtype SerialiseViaFlat a = SerialiseViaFlat a
instance Flat.Flat a => Serialise (SerialiseViaFlat a) where
    encode (SerialiseViaFlat a) = encode $ Flat.flat a
    decode = SerialiseViaFlat <$> decodeViaFlat Flat.decode

decodeViaFlat :: Flat.Get a -> CBOR.Decoder s a
decodeViaFlat decoder = do
    bs <- CBOR.decodeBytes
    -- lift any flat's failures to be cborg failures (MonadFail)
    either (fail . show) pure $
        Flat.unflatWith decoder bs