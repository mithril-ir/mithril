-- Attack: pass a merely Resolved document to the public Wasp emitter,
-- bypassing static typing and normalization.  Must fail:
-- renderWaspBundle accepts exactly a CoreDocument Normalized, and the
-- stage indexes are distinct nominal types — a document that has not
-- been typechecked and normalized can never be lowered to a Wasp
-- bundle.
module Main
  ( main
  ) where

import Mithril.Core.Resolution (Resolved)
import Mithril.Core.Validation (CoreDocument)
import Mithril.Core.Wasp (renderWaspBundle)

render :: CoreDocument Resolved -> Bool
render document =
  case renderWaspBundle document of
    Left _ -> False
    Right _ -> True

main :: IO ()
main = render `seq` pure ()
