-- | Test-suite runner: names the check groups and hands them to the
-- shared harness in "Mithril.Test".  The checks themselves live in
-- "Mithril.CLITests" (pure CLI boundary),
-- "Mithril.CoreValidationTests" (structural validation boundary),
-- "Mithril.CoreResolutionTests" (name-resolution boundary),
-- "Mithril.CoreRepresentationTests" (the explicit resolved
-- representation through the public pipeline),
-- "Mithril.CoreModelTests" (white-box inspection of the real resolved
-- model through the package-private sublibrary), and
-- "Mithril.CLIProcessTests" (the real executable as a process).
module Main
  ( main
  ) where

import qualified Mithril.CLIProcessTests
import qualified Mithril.CLITests
import qualified Mithril.CoreModelTests
import qualified Mithril.CoreRepresentationTests
import qualified Mithril.CoreResolutionTests
import qualified Mithril.CoreValidationTests
import Mithril.Test (runGroups)

main :: IO ()
main =
  runGroups
    [ ("CLI", Mithril.CLITests.tests)
    , ("Core validation", Mithril.CoreValidationTests.tests)
    , ("Core resolution", Mithril.CoreResolutionTests.tests)
    , ("Core representation", Mithril.CoreRepresentationTests.tests)
    , ("Core model", Mithril.CoreModelTests.tests)
    , ("CLI process", Mithril.CLIProcessTests.tests)
    ]
