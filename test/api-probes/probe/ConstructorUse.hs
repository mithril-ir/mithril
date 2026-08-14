-- Attack: forge a StructurallyValid document by calling the
-- CoreDocument constructor via the public re-export.  Must fail: the
-- public modules re-export the type abstractly, so no constructor is
-- in scope.
module Main
  ( main
  ) where

import Data.Aeson (Value (Null))
import Mithril.Core.Validation (CoreDocument, StructurallyValid)

forged :: CoreDocument StructurallyValid
forged = CoreDocument Null

main :: IO ()
main = forged `seq` pure ()
