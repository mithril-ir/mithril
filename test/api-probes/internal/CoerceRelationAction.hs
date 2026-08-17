-- | Attack: cross-namespace coercion of global identifiers, from
-- /inside/ the package — the 'RelationId'-to-'ActionId' variant of
-- the attack in @CoerceEntityEnum.hs@.  Both types are distinct
-- @data@ types with no @Coercible@ relation, so GHC must reject this
-- with a representation mismatch even though the definitions are
-- legitimately importable here.
module Main
  ( main
  ) where

import Data.Coerce (coerce)

import Mithril.Core.Internal.Resolved (ActionId, RelationId (..))

relationAsAction :: RelationId -> ActionId
relationAsAction = coerce

main :: IO ()
main = relationAsAction (RelationId 0) `seq` pure ()
