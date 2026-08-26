-- Attack: import the internal module that owns the CoreDocument
-- constructor.  Must fail: Mithril.Core.Internal.Document is an
-- exposed module of the package-private core-internal sublibrary of
-- mithril-ir (visibility: private), so it is hidden from an external
-- package dependency like this one.  The imported constructor is
-- consumed, so visibility could never surface an incidental
-- unused-import failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Document (CoreDocument (..))

main :: IO ()
main = CoreDocument `seq` pure ()
