{-# LANGUAGE TemplateHaskell #-}

-- | __Internal module — never expose.__
--
-- Compile-time embedding of the trusted generic Agda kernel modules
-- the verifier's generated obligation module imports: the exact bytes
-- of @agda\/Mithril\/Base.agda@, @Core.agda@, @Policy.agda@,
-- @Effect.agda@, and @Guarantee.agda@ are read from the source tree
-- while this module compiles and become literals inside the library,
-- following the embedded-schema provenance pattern of
-- "Mithril.Core.Internal.BundledSchema".  Each file is registered as
-- a dependent file, so editing it triggers recompilation.
--
-- Because the kernel travels inside the compiled code, the verifier
-- never reads kernel modules from the current repository, the working
-- directory, a data directory, or any environment-selected location
-- at run time: the checker materializes exactly these bytes into a
-- fresh isolated workspace for every invocation
-- ("Mithril.Core.Internal.AgdaChecker").  This is provenance by
-- construction, not a cryptographic-integrity claim; the kernel
-- sources themselves remain authored, reviewed Agda in @agda\/@ and
-- are part of the trusted computing base.
module Mithril.Core.Internal.AgdaKernel
  ( kernelModules
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)

-- | The trusted kernel sources, as (path inside the checking tree,
-- exact embedded bytes) pairs.  The paths are fixed constants —
-- never derived from a document — and match the module names the
-- generated obligation module imports.
kernelModules :: [(FilePath, ByteString)]
kernelModules =
  [ ("Mithril/Base.agda", baseBytes)
  , ("Mithril/Core.agda", coreBytes)
  , ("Mithril/Policy.agda", policyBytes)
  , ("Mithril/Effect.agda", effectBytes)
  , ("Mithril/Guarantee.agda", guaranteeBytes)
  ]

baseBytes :: ByteString
baseBytes =
  $( do
       addDependentFile "agda/Mithril/Base.agda"
       bytes <- runIO (ByteString.readFile "agda/Mithril/Base.agda")
       lift bytes
   )

coreBytes :: ByteString
coreBytes =
  $( do
       addDependentFile "agda/Mithril/Core.agda"
       bytes <- runIO (ByteString.readFile "agda/Mithril/Core.agda")
       lift bytes
   )

policyBytes :: ByteString
policyBytes =
  $( do
       addDependentFile "agda/Mithril/Policy.agda"
       bytes <- runIO (ByteString.readFile "agda/Mithril/Policy.agda")
       lift bytes
   )

effectBytes :: ByteString
effectBytes =
  $( do
       addDependentFile "agda/Mithril/Effect.agda"
       bytes <- runIO (ByteString.readFile "agda/Mithril/Effect.agda")
       lift bytes
   )

guaranteeBytes :: ByteString
guaranteeBytes =
  $( do
       addDependentFile "agda/Mithril/Guarantee.agda"
       bytes <- runIO (ByteString.readFile "agda/Mithril/Guarantee.agda")
       lift bytes
   )
