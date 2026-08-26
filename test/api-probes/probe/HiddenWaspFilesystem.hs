-- Attack: import the internal module that owns the effectful Wasp
-- filesystem boundary — root-path validation, the no-follow snapshot
-- walker, and the whole-directory installation swap with its
-- fault-injection seam.  Must fail: Mithril.Core.Internal.WaspFilesystem
-- lives in the package-private core-internal sublibrary of
-- mithril-ir, so an external package cannot install a bundle outside
-- the staged pipeline, inject faults between the installation steps,
-- or snapshot a root through the checker's own walker.  The public
-- surface is exactly Mithril.Command.Wasp.  The imported installer
-- is consumed, so visibility could never surface an incidental
-- unused-import failure instead of the boundary.
module Main
  ( main
  ) where

import Mithril.Core.Internal.WaspFilesystem (installBundle)

main :: IO ()
main = installBundle `seq` pure ()
