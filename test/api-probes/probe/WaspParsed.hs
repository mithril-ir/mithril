-- Attack: pass a merely Parsed document to the public Wasp emitter,
-- bypassing structural validation, name resolution, static typing,
-- and normalization.  Must fail: renderWaspBundle accepts exactly a
-- CoreDocument Normalized, and the stage indexes are distinct nominal
-- types — parsed JSON can never be lowered to a Wasp bundle.
module Main
  ( main
  ) where

import Mithril.Core.Validation (CoreDocument, Parsed)
import Mithril.Core.Wasp (renderWaspBundle)

render :: CoreDocument Parsed -> Bool
render document =
  case renderWaspBundle document of
    Left _ -> False
    Right _ -> True

main :: IO ()
main = render `seq` pure ()
