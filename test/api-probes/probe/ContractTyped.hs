-- Attack: pass a merely Typed document to the contract renderer,
-- bypassing normalization.  Must fail: renderCoreContract accepts
-- exactly a CoreDocument Normalized, and the stage indexes are
-- distinct nominal types — a document that has not passed the
-- normalizer can never be rendered as a security contract.
module Main
  ( main
  ) where

import Mithril.Core.Contract (renderCoreContract)
import Mithril.Core.Typing (Typed)
import Mithril.Core.Validation (CoreDocument)

render :: CoreDocument Typed -> Bool
render document =
  case renderCoreContract document of
    Left _ -> False
    Right _ -> True

main :: IO ()
main = render `seq` pure ()
