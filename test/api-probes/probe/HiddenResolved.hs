-- Attack: import the internal module that owns the explicit resolved
-- Core representation — its model nodes and its namespace-specific
-- identifier types.  Must fail: Mithril.Core.Internal.Resolved is an
-- exposed module of the package-private core-internal sublibrary of
-- mithril-ir (visibility: private), so it is hidden from an external
-- package dependency like this one.  Because the import itself is
-- rejected, no downstream code can even name the representation's
-- types — and so none can construct resolved nodes, mint an
-- identifier, or coerce between identifier namespaces (EntityId vs
-- EnumId, or one owner's AttributeId vs another's).
module Main
  ( main
  ) where

import Mithril.Core.Internal.Resolved (EntityId (..), Model (..))

main :: IO ()
main = pure ()
