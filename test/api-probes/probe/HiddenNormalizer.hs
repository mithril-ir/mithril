-- Attack: import the internal module that owns the Core v0
-- normalization pass — its model transformation and its invariant
-- violation constructors.  Must fail: Mithril.Core.Internal.Normalize
-- is a hidden (other-modules) module of mithril-ir, so an external
-- package cannot import it — and therefore cannot run the pass
-- outside the staged pipeline or construct raw invariant violations.
-- The public surface is exactly Mithril.Core.Normalization, whose
-- normalizeCoreDocument is the only direct public producer of the
-- typed-to-normalized stage transition.  The imported pass is
-- consumed, so visibility could never surface an incidental
-- unused-import failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Normalize (normalizeModel)

main :: IO ()
main = normalizeModel `seq` pure ()
