-- Attack: import the internal module that owns the CoreDocument
-- constructor.  Must fail: Mithril.Core.Internal.Document is listed
-- under other-modules, so it is a hidden module of the mithril-ir
-- package.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Document (CoreDocument (..))

main :: IO ()
main = pure ()
