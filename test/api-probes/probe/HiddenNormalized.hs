-- Attack: import the internal module that owns the explicit typed
-- normalized Core representation — its model nodes, its typed terms,
-- and its materialized rank and binding structures.  Must fail:
-- Mithril.Core.Internal.Normalized is an exposed module of the
-- package-private core-internal sublibrary of mithril-ir
-- (visibility: private), so it is hidden from an external package
-- dependency like this one.  Because the import itself is rejected,
-- no downstream code can even name the normalized model's types —
-- and so none can construct normalized nodes or recover the internal
-- model from a normalized document.  Both imported constructors are
-- consumed, so visibility could never surface an incidental
-- unused-import failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Normalized (Model (..), ValueTerm (..))

main :: IO ()
main = Model `seq` ValueTerm `seq` pure ()
