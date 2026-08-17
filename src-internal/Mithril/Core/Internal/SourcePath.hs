-- | __Internal module — never expose.__
--
-- The source-location abstraction of the frontend representation:
-- where a node of the decoded or resolved Core representation came
-- from in the authored JSON document.
--
-- Locations are document JSON paths — the raw member-name and
-- array-index segments from the document root — because that is
-- exactly what the JSON parser can attest; the current parser
-- preserves no line or column information, so none is invented here.
-- A 'SourcePath' renders with the RFC 6901-style convention of
-- 'Mithril.Core.Validation.renderJsonPointer' (via
-- 'sourcePathSegments'), keeping representation-carried locations
-- byte-compatible with every existing diagnostic.
module Mithril.Core.Internal.SourcePath
  ( SourcePath
  , rootPath
  , memberPath
  , indexPath
  , sourcePathSegments
  , Sourced (..)
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

-- | The location of one node in the authored JSON document: the raw
-- (unescaped) path segments from the document root, in order.  Opaque
-- outside this module so that paths are only ever built by descending
-- from 'rootPath'; the segments come back out through
-- 'sourcePathSegments' for diagnostic rendering.
newtype SourcePath = SourcePath [Text]
  deriving (Eq, Ord, Show)

-- | The document root.
rootPath :: SourcePath
rootPath = SourcePath []

-- | The location of an object member under a location.
memberPath :: SourcePath -> Text -> SourcePath
memberPath (SourcePath segments) name = SourcePath (segments <> [name])

-- | The location of an array item under a location.
indexPath :: SourcePath -> Int -> SourcePath
indexPath (SourcePath segments) index =
  SourcePath (segments <> [Text.pack (show index)])

-- | The raw segments, for rendering with
-- 'Mithril.Core.Validation.renderJsonPointer' or for embedding in a
-- diagnostic value.
sourcePathSegments :: SourcePath -> [Text]
sourcePathSegments (SourcePath segments) = segments

-- | A value together with the source location it was decoded from —
-- used for declaration names, reference names, and every other
-- located leaf of the frontend representation.
data Sourced a = Sourced
  { sourcedPath :: SourcePath
  , sourcedValue :: a
  }
  deriving (Eq, Ord, Show)
