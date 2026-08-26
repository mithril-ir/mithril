-- Attack: import the internal module that owns the one shared
-- NoSelfPrivilegeEscalation support gate and plan.  Must fail:
-- Mithril.Core.Internal.NspeSupportPlan lives in the package-private
-- core-internal sublibrary of mithril-ir, so an external package
-- cannot import it — and therefore cannot run the support gate
-- outside the staged pipeline, forge a plan, or feed either consumer
-- (the verifier or the Wasp emitter) evidence of its own.  The
-- imported gate is consumed, so visibility could never surface an
-- incidental unused-import failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.NspeSupportPlan (supportPlan)

main :: IO ()
main = supportPlan `seq` pure ()
