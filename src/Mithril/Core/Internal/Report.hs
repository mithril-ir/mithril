-- | __Internal module — never expose.__
--
-- The diagnostic vocabulary shared by the frontend's decoder
-- ("Mithril.Core.Internal.Decode") and resolver
-- ("Mithril.Core.Resolution"): the two violation types of the
-- name-resolution boundary — re-exported publicly, with their exact
-- current shape, from "Mithril.Core.Resolution" — and the small
-- error-collecting applicative both passes are written in.
--
-- 'Collect' is a validation-style applicative: combining two
-- computations reports the problems of /both/ sides, so independent
-- problems aggregate across the whole document instead of stopping at
-- the first, and a computation can end up with no value and no
-- problem of its own ('suppressed') when its prerequisite already
-- reported the root cause — the no-cascade behavior of the resolver.
-- It is deliberately not a 'Monad': sequencing that needs an earlier
-- result goes through 'andThen', which cannot invent a value after a
-- failure, so no lawless @ap@\/@<*>@ mismatch exists.
module Mithril.Core.Internal.Report
  ( -- * Violations
    ResolutionViolation (..)
  , ResolverInvariantViolation (..)
  , violationAt
  , invariantAt

    -- * Error-collecting computations
  , Collect
  , runCollect
  , refuse
  , suppressed
  , reporting
  , andThen

    -- * Message helpers
  , quoted
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

import Mithril.Core.Internal.SourcePath (SourcePath, sourcePathSegments)

-- | One name-resolution violation in the user's document: a duplicate
-- declaration name or an unresolvable name reference.
data ResolutionViolation = ResolutionViolation
  { resolutionViolationPath :: [Text]
    -- ^ Instance path of the failing name site, as raw (unescaped)
    -- segments; render with
    -- 'Mithril.Core.Validation.renderJsonPointer'.
  , resolutionViolationMessage :: Text
    -- ^ Description of the violation, with every referenced name
    -- quoted.
  }
  deriving (Eq, Ord, Show)

-- | One resolver-invariant violation: a shape the frontend cannot
-- interpret even though the document passed structural validation.
-- This is evidence of schema\/frontend drift or a decoder\/resolver
-- bug — an internal error of the @mithril@ tool, never a problem with
-- the user's document.
data ResolverInvariantViolation = ResolverInvariantViolation
  { resolverInvariantPath :: [Text]
    -- ^ Instance path of the uninterpretable shape, as raw segments;
    -- render with 'Mithril.Core.Validation.renderJsonPointer'.
  , resolverInvariantMessage :: Text
    -- ^ Description of the expectation that failed.
  }
  deriving (Eq, Ord, Show)

-- | A resolution violation at a source path.
violationAt :: SourcePath -> Text -> ResolutionViolation
violationAt path = ResolutionViolation (sourcePathSegments path)

-- | An invariant violation at a source path.
invariantAt :: SourcePath -> Text -> ResolverInvariantViolation
invariantAt path = ResolverInvariantViolation (sourcePathSegments path)

-- | A computation that collects problems of type @e@ while trying to
-- build an @a@.  The problem list and the result are independent: a
-- computation may fail with problems, fail silently because the root
-- problem was already reported elsewhere ('suppressed'), or even
-- carry problems /and/ a value (via 'reporting') when construction
-- can continue — duplicates are reported that way while the
-- first-declaration-wins namespaces keep resolving the rest of the
-- document.
data Collect e a = Collect [e] (Maybe a)

instance Functor (Collect e) where
  fmap adjust (Collect problems value) = Collect problems (fmap adjust value)

-- | Validation-style combination: problems of both sides are kept,
-- and a value exists only when both sides produced one.
instance Applicative (Collect e) where
  pure = Collect [] . Just
  Collect problems function <*> Collect moreProblems value =
    Collect (problems <> moreProblems) (function <*> value)

-- | The collected problems (in traversal order, unnormalized) and the
-- result, if every part of the computation produced one.
runCollect :: Collect e a -> ([e], Maybe a)
runCollect (Collect problems value) = (problems, value)

-- | Fail with one problem.
refuse :: e -> Collect e a
refuse problem = Collect [problem] Nothing

-- | Fail with no problem of this site's own: the prerequisite that
-- makes this site unresolvable is already reported at its root cause,
-- and reporting again here would cascade.
suppressed :: Collect e a
suppressed = Collect [] Nothing

-- | Attach already-collected problems to a computation that still
-- carries on (used for duplicate-declaration reports, which do not
-- stop the rest of the document from being checked).
reporting :: [e] -> Collect e ()
reporting problems = Collect problems (Just ())

-- | Sequence a dependent step: the continuation runs only when a
-- value exists, and problems of both steps are kept.  This is
-- deliberately a named combinator rather than a 'Monad' instance —
-- see the module header.
andThen :: Collect e a -> (a -> Collect e b) -> Collect e b
andThen (Collect problems value) continue =
  case value of
    Nothing -> Collect problems Nothing
    Just x ->
      case continue x of
        Collect moreProblems result -> Collect (problems <> moreProblems) result

-- | Quote a document-supplied name for a diagnostic.  'show' on
-- 'Text' renders a double-quoted string literal with any unusual
-- character escaped, so no name can smuggle line breaks or terminal
-- controls into a message.
quoted :: Text -> Text
quoted = Text.pack . show
