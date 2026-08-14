-- Attack: promote a StructurallyValid document to Resolved with
-- Data.Coerce, bypassing resolveCoreDocument.  Must fail: the stage
-- index of CoreDocument is declared nominal, so coerce cannot change
-- it.
module Main
  ( main
  ) where

import Data.Coerce (coerce)
import Mithril.Core.Resolution (Resolved)
import Mithril.Core.Validation (CoreDocument, StructurallyValid)

promote :: CoreDocument StructurallyValid -> CoreDocument Resolved
promote = coerce

main :: IO ()
main = promote `seq` pure ()
