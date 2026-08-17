-- | Attack: cross-namespace coercion of global identifiers, from
-- /inside/ the package.  The real internal definitions and their
-- constructors are legitimately in scope (the control probe proves
-- that), yet 'EntityId' and 'EnumId' are distinct @data@ types with
-- no @Coercible@ relation, so GHC itself must reject this with a
-- representation mismatch — not a hidden-module or scope error.
module Main
  ( main
  ) where

import Data.Coerce (coerce)

import Mithril.Core.Internal.Resolved (EntityId (..), EnumId)

entityAsEnum :: EntityId -> EnumId
entityAsEnum = coerce

main :: IO ()
main = entityAsEnum (EntityId 0) `seq` pure ()
