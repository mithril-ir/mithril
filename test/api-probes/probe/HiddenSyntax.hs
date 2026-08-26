-- Attack: import the internal module that owns the decoded Core
-- surface syntax and the actor-availability contexts.  Must fail:
-- Mithril.Core.Internal.Syntax is an exposed module of the
-- package-private core-internal sublibrary of mithril-ir
-- (visibility: private), so it is hidden from an external package
-- dependency like this one, and no downstream code can construct
-- syntax nodes or actor-context witnesses.  Every imported
-- constructor is consumed, so visibility could never surface an
-- incidental unused-import failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Syntax (ActorContext (..), Document (..))

main :: IO ()
main = WithActor `seq` WithoutActor `seq` Document `seq` pure ()
