-- | Control: proves the in-package probe environment genuinely
-- reaches the real internal identifier definitions of the private
-- @core-internal@ sublibrary — module, constructors, and instances.
-- This executable must COMPILE (and runs trivially), so that the
-- non-coercion attacks beside it cannot fail for an accidental
-- reason: with this control green, a failing attack fails on the
-- coercibility of the identifier types alone, never on module
-- visibility or a broken probe environment.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Resolved
  ( ActionId (..)
  , EntityId (..)
  , EnumId (..)
  , RelationId (..)
  )

-- | Construct every global identifier the attacks target and use
-- their 'Eq', 'Ord', and 'Show' instances, so the attacks' imports
-- and vocabulary are demonstrably available here.
main :: IO ()
main =
  print
    ( EntityId 0 == EntityId 0
    , EnumId 0 < EnumId 1
    , show (RelationId 0)
    , show (ActionId 0)
    )
