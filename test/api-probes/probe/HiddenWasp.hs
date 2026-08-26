-- Attack: import the internal module that owns the Wasp emitter — the
-- fixed target names, the templates, and the bundle constructor.  Must
-- fail: Mithril.Core.Internal.Wasp lives in the package-private
-- core-internal sublibrary of mithril-ir, so an external package
-- cannot render a bundle from a forged plan, construct a bundle by
-- hand, or reach the templates outside the staged pipeline.  The
-- public surface is exactly Mithril.Core.Wasp, whose renderWaspBundle
-- accepts only a CoreDocument Normalized.
module Main
  ( main
  ) where

import Mithril.Core.Internal.Wasp (renderBundleFromPlan)

main :: IO ()
main = renderBundleFromPlan `seq` pure ()
