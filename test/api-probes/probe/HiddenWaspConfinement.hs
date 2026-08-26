-- Attack: import the internal module that owns the pure Wasp
-- confinement checker.  Must fail: Mithril.Core.Internal.WaspConfinement
-- lives in the package-private core-internal sublibrary of
-- mithril-ir, so an external package cannot reach the checker's
-- internals (the denylist scan and the path classification) other
-- than through the public Mithril.Core.Wasp boundary.  The imported
-- scan is consumed, so visibility could never surface an incidental
-- unused-import failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.WaspConfinement (scanFindings)

main :: IO ()
main = scanFindings `seq` pure ()
