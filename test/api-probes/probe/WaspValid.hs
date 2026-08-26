-- Attack: pass a merely StructurallyValid document to the public Wasp
-- emitter, bypassing name resolution, static typing, and
-- normalization.  Must fail: renderWaspBundle accepts exactly a
-- CoreDocument Normalized, and the stage indexes are distinct nominal
-- types — a structurally valid document can never be lowered to a
-- Wasp bundle without the later stages.
module Main
  ( main
  ) where

import Mithril.Core.Validation (CoreDocument, StructurallyValid)
import Mithril.Core.Wasp (renderWaspBundle)

render :: CoreDocument StructurallyValid -> Bool
render document =
  case renderWaspBundle document of
    Left _ -> False
    Right _ -> True

main :: IO ()
main = render `seq` pure ()
