-- | __Internal module — never expose.__
--
-- The one diagnostic-escaping convention shared by the command
-- boundaries ("Mithril.Command.Validate" and
-- "Mithril.Command.Contract"): both render their stderr diagnostics
-- through 'escapeControlChars' rather than restating the escape
-- rules.  This is an implementation helper of the @mithril@ command
-- layer, not part of the public API — it stays in @other-modules@ so
-- no downstream package can import it.
module Mithril.Command.Internal.Diagnostic
  ( escapeControlChars
  ) where

import Data.Char (isPrint, showLitChar)
import Data.Text (Text)
import qualified Data.Text as Text

-- | Escape control characters in diagnostic text ('showLitChar'
-- form), keeping every diagnostic on its intended line.
escapeControlChars :: Text -> Text
escapeControlChars = Text.concatMap escapeChar
  where
    escapeChar c
      | isPrint c = Text.singleton c
      | otherwise = Text.pack (showLitChar c "")
