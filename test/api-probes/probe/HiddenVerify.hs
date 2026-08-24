-- Attack: import the internal module that owns the verifier's
-- support gate, obligation generator, and checker-independent
-- orchestration (including the runner-injection seam).  Must fail:
-- Mithril.Core.Internal.Verify lives in the package-private
-- core-internal sublibrary of mithril-ir, so an external package
-- cannot import it — and therefore cannot run the support gate or
-- the generator outside the staged pipeline, inject a checker
-- runner, or forge plans.  The public surface is exactly
-- Mithril.Core.Verification, whose verifyCoreDocument accepts only a
-- CoreDocument Normalized.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Verify (renderObligationModule)

main :: IO ()
main = renderObligationModule `seq` pure ()
