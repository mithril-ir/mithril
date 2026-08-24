-- Attack: import the internal module that owns the production Agda
-- checker runner — the one place the verifier crosses the
-- file/process boundary to the Agda toolchain.  Must fail:
-- Mithril.Core.Internal.AgdaChecker is a hidden (other-modules)
-- module of mithril-ir, so an external package cannot invoke the
-- checker runner directly, bypass the support gate, or feed the
-- checker a module of its own.  The imported runner is consumed, so
-- visibility could never surface an incidental unused-import failure
-- instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.AgdaChecker (agdaCheckerRunner)

main :: IO ()
main = agdaCheckerRunner `seq` pure ()
