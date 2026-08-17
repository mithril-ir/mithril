-- Attack: promote a Resolved document to Typed with Data.Coerce,
-- bypassing typecheckCoreDocument.  Must fail: the stage index of
-- CoreDocument is declared nominal, so coerce cannot change it — a
-- document that has not passed the static typechecker can never pose
-- as typed.
module Main
  ( main
  ) where

import Data.Coerce (coerce)
import Mithril.Core.Resolution (Resolved)
import Mithril.Core.Typing (Typed)
import Mithril.Core.Validation (CoreDocument)

promote :: CoreDocument Resolved -> CoreDocument Typed
promote = coerce

main :: IO ()
main = promote `seq` pure ()
