-- Attack: pass a merely Typed document to the public verifier,
-- bypassing normalization.  Must fail: verifyCoreDocument accepts
-- exactly a CoreDocument Normalized, and the stage indexes are
-- distinct nominal types — a document that has not passed the
-- normalizer can never reach the verifier boundary.
module Main
  ( main
  ) where

import Mithril.Core.Typing (Typed)
import Mithril.Core.Validation (CoreDocument)
import Mithril.Core.Verification (verifyCoreDocument)

verify :: CoreDocument Typed -> IO ()
verify document = do
  _ <- verifyCoreDocument document
  pure ()

main :: IO ()
main = verify `seq` pure ()
