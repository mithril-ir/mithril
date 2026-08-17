-- Attack: forge a Typed document by calling the CoreDocument
-- constructor via the public modules, with an undefined payload so
-- the attack does not even need to name the internal model type.
-- Must fail: the public modules re-export the type abstractly, so no
-- constructor is in scope — the only public producer of a
-- CoreDocument Typed is Mithril.Core.Typing.typecheckCoreDocument.
module Main
  ( main
  ) where

import Mithril.Core.Typing (Typed)
import Mithril.Core.Validation (CoreDocument)

forged :: CoreDocument Typed
forged = CoreDocument undefined

main :: IO ()
main = forged `seq` pure ()
