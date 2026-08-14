-- Attack: promote a merely Parsed document to StructurallyValid with
-- Data.Coerce, bypassing validateCoreDocument.  Must fail: the stage
-- index of CoreDocument is declared nominal, so coerce cannot change
-- it.
module Main
  ( main
  ) where

import Data.Coerce (coerce)
import Mithril.Core.Validation (CoreDocument, Parsed, StructurallyValid)

promote :: CoreDocument Parsed -> CoreDocument StructurallyValid
promote = coerce

main :: IO ()
main = promote `seq` pure ()
