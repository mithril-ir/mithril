-- Attack: import the internal module that owns the Core v0
-- security-contract rendering pass — its model-to-text rendering and
-- its invariant violation constructors.  Must fail:
-- Mithril.Core.Internal.Contract is a hidden (other-modules) module
-- of mithril-ir, so an external package cannot import it — and
-- therefore cannot run the rendering pass outside the staged pipeline
-- or construct raw invariant violations.  The public surface is
-- exactly Mithril.Core.Contract, whose renderCoreContract accepts
-- only a CoreDocument Normalized.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Contract (renderModelContract)

main :: IO ()
main = renderModelContract `seq` pure ()
