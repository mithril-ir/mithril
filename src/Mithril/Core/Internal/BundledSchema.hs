{-# LANGUAGE TemplateHaskell #-}

-- | __Internal module — never expose.__
--
-- Compile-time embedding of the canonical Core v0 schema.  The bytes
-- of @core\/schema.json@ — the single authoritative source for the
-- external Core v0 JSON grammar — are read from the source tree while
-- this module compiles and become a literal inside the library.  The
-- file is registered as a dependent file, so editing it triggers
-- recompilation of this module and everything above it.
--
-- Because the schema travels inside the compiled code, no runtime
-- file lookup — in particular no @Paths_mithril_ir@ data-directory
-- resolution and no @mithril_ir_datadir@ environment override — can
-- influence which grammar the tool validates against.  The embedded
-- bytes are still parsed and profile-gated at use time by
-- "Mithril.Core.Validation"; this module deliberately knows nothing
-- about JSON.
module Mithril.Core.Internal.BundledSchema
  ( bundledCoreSchemaBytes
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)

-- | The exact bytes of @core\/schema.json@ at compile time.  The
-- 'ByteString' literal is produced by bytestring's own 'Lift'
-- instance, so the embedded value is byte-identical to the file.
bundledCoreSchemaBytes :: ByteString
bundledCoreSchemaBytes =
  $( do
       addDependentFile "core/schema.json"
       bytes <- runIO (ByteString.readFile "core/schema.json")
       lift bytes
   )
