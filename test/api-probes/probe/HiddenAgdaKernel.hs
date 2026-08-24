-- Attack: import the internal module that owns the
-- compile-time-embedded trusted Agda kernel bytes.  Must fail:
-- Mithril.Core.Internal.AgdaKernel is a hidden (other-modules)
-- module of mithril-ir, so an external package cannot read the
-- embedded kernel sources or substitute its own — the only kernel
-- the verifier can materialize is the one pinned into the binary at
-- compile time.
module Main
  ( main
  ) where

import Mithril.Core.Internal.AgdaKernel (kernelModules)

main :: IO ()
main = kernelModules `seq` pure ()
