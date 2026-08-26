-- Attack: import the internal module that owns the Core v0 static
-- typechecker — its checking pass and its violation constructors.
-- Must fail: Mithril.Core.Internal.Typecheck is a hidden
-- (other-modules) module of mithril-ir, so an external package
-- cannot import it — and therefore cannot run the checking pass
-- outside the staged pipeline, construct raw typing problems, or
-- reach the internal type language at all.  The public surface is
-- exactly Mithril.Core.Typing, whose only producer of a typed
-- document is typecheckCoreDocument.  The imported pass is consumed,
-- so visibility could never surface an incidental unused-import
-- failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Typecheck (checkModel)

main :: IO ()
main = checkModel `seq` pure ()
