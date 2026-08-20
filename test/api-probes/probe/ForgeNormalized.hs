-- Attack: forge a Normalized document by calling the CoreDocument
-- constructor via the public modules, with an undefined payload so
-- the attack does not even need to name the internal normalized
-- model type.  Must fail: the public modules re-export the type
-- abstractly, so no constructor is in scope — the only public
-- producer of a CoreDocument Normalized is
-- Mithril.Core.Normalization.normalizeCoreDocument.
module Main
  ( main
  ) where

import Mithril.Core.Normalization (Normalized)
import Mithril.Core.Validation (CoreDocument)

forged :: CoreDocument Normalized
forged = CoreDocument undefined

main :: IO ()
main = forged `seq` pure ()
