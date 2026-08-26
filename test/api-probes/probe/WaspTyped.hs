-- Attack: pass a merely Typed document to the public Wasp emitter,
-- bypassing normalization.  Must fail: renderWaspBundle accepts
-- exactly a CoreDocument Normalized, and the stage indexes are
-- distinct nominal types — a document that has not passed the
-- normalizer can never be lowered to a Wasp bundle.
module Main
  ( main
  ) where

import Mithril.Core.Typing (Typed)
import Mithril.Core.Validation (CoreDocument)
import Mithril.Core.Wasp (renderWaspBundle)

render :: CoreDocument Typed -> Bool
render document =
  case renderWaspBundle document of
    Left _ -> False
    Right _ -> True

main :: IO ()
main = render `seq` pure ()
