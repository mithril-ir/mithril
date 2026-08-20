-- Attack: promote a Typed document to Normalized with Data.Coerce,
-- bypassing normalizeCoreDocument.  Must fail: the stage index of
-- CoreDocument is declared nominal, so coerce cannot change it — a
-- document that has not passed the normalizer can never pose as
-- typed normalized Core.
module Main
  ( main
  ) where

import Data.Coerce (coerce)
import Mithril.Core.Normalization (Normalized)
import Mithril.Core.Typing (Typed)
import Mithril.Core.Validation (CoreDocument)

promote :: CoreDocument Typed -> CoreDocument Normalized
promote = coerce

main :: IO ()
main = promote `seq` pure ()
