{-# LANGUAGE OverloadedStrings #-}

-- | The static-typing boundary of the Mithril Core v0 frontend:
-- complete static typing over the explicit resolved representation.
--
-- > resolved opaque document
-- >   -> complete static typing             ('typecheckCoreDocument')
-- >   -> typed opaque document
--
-- 'typecheckCoreDocument' consumes the resolved document produced by
-- "Mithril.Core.Resolution" — the explicit internal decoded and
-- name-resolved Core representation, never raw JSON, and never a
-- second reading of names — and checks every Core v0 static-typing
-- judgment the schema and the resolver defer:
--
-- * /term, policy, effect, and result typing/ over the Core v0 type
--   language — the value types @Bool@, @Unit@, @Enum E@, and
--   @EntityRef E@, plus the one-level optional types that model
--   relation-payload presence;
-- * /operand compatibility/: @And@\/@Or@\/@Not@ and every allow
--   policy at @Bool@; @IsSome@ over an optional type; @Equal@ over
--   two operands of one type (equality is total at every type);
--   @LessOrEqual@ over two operands of one /ordered/ type — an enum
--   with a declared order, directly or under @Optional@ with absence
--   as bottom;
-- * /enum-order validity/: a declared enum @order@ must be a
--   complete permutation of the enum's values;
-- * /relation compatibility/: @Lookup@, @SetRelation@, and
--   @RemoveRelation@ must match their relation's exact endpoint
--   arity and per-position endpoint entity types, and a
--   @SetRelation@ payload must have the relation's payload type;
-- * /effect and result targets/: @DeleteEntity@ targets and
--   @Observe@ results must be entity references;
-- * /@CreateEntity@ initializers/: complete over the target entity's
--   attributes, with every initializer term of its attribute's
--   declared type;
-- * /guarantee well-typedness/: a @TenantIsolation@ access relation
--   must be binary with two distinct endpoints and a subject endpoint
--   at the distinguished @User@ entity, and each case's actor-free
--   terms (the tenant term at exactly the tenant endpoint's entity
--   type, the @Bool@ @protected@ term) are typed in its action's
--   environment.  A @NoSelfPrivilegeEscalation@ authority must have
--   a @User@ subject endpoint; when it names a scope endpoint, that
--   endpoint must be distinct from the subject and together they
--   must cover the relation's endpoints, so an arity-two authority
--   relation requires one scope endpoint.  Its payload must be
--   exactly the declared-order @payloadOrder@ enum, and each case
--   must carry scope terms corresponding one-to-one with the
--   authority's scope endpoints, at their respective entity types.
--   An authority over a unary relation with no scope endpoint is
--   well-typed: the later verifier support gate, not the
--   typechecker, requires the supported binary shape.  Whether a
--   case's policy violates the obligation is a verifier question,
--   not a type error (@Mithril.Core.Internal.Typecheck@ states each
--   rule exactly).
--
-- A @'Mithril.Core.Validation.CoreDocument' 'Typed'@ attests exactly
-- this judgment and nothing more.  It is /not/ typed normalized
-- Core: no normalization, no policy evaluation, no guarantee
-- verification, no proof generation or checking, and no code
-- generation happened, and no semantic or security property is
-- established.  Selecting a guarantee remains selecting a proof
-- obligation; a well-typed document's guarantees are still
-- unverified.
--
-- == Failure classification
--
-- Typing problems in the user's document are 'TypeViolation's,
-- reported with raw path segments (render with
-- 'Mithril.Core.Validation.renderJsonPointer'), aggregated across
-- independent sites, deduplicated, and deterministically ordered.
-- After successful name resolution every term's type is determined,
-- so independent violations aggregate without cascades, and a root
-- cause is reported once (for example, an incomplete enum order is
-- reported at the enum declaration, not at every comparison that
-- uses the enum).
--
-- Shapes of the resolved representation the typechecker cannot
-- interpret are impossible after successful resolution; they
-- indicate frontend drift or a resolver\/typechecker bug, never a
-- user error.  They are 'TypecheckerInvariantViolation's, kept
-- separate from type violations, and they dominate: when the
-- typechecker cannot trust its reading of the model it reports
-- 'TypecheckerInvariantViolations' without an ordinary typing
-- verdict.  The checker never throws.
module Mithril.Core.Typing
  ( -- * Pipeline stage
    Typed

    -- * Failures and violations
  , TypingFailure (..)
  , TypeViolation (..)
  , TypecheckerInvariantViolation (..)

    -- * Static typing
  , typecheckCoreDocument

    -- * Violation normalization
  , normalizeTypeViolations
  ) where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty

import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Resolved
  , Typed
  )
import Mithril.Core.Internal.Report (runCollect)
import Mithril.Core.Internal.Typecheck
  ( TypeViolation (..)
  , TypecheckerInvariantViolation (..)
  , TypingProblem (..)
  , checkModel
  )

-- | Why 'typecheckCoreDocument' refused the stage transition.
data TypingFailure
  = -- | The document has static-typing problems.  The violations are
    -- sorted and deduplicated ('normalizeTypeViolations').
    TypeViolations (NonEmpty TypeViolation)
  | -- | The typechecker hit shapes of the resolved representation it
    -- cannot interpret.  This classification dominates: when the
    -- typechecker cannot trust its reading of the model, no ordinary
    -- typing verdict is reported.  The violations are sorted and
    -- deduplicated.
    TypecheckerInvariantViolations (NonEmpty TypecheckerInvariantViolation)
  deriving (Eq, Show)

-- | Check every Core v0 static-typing judgment of a resolved
-- document (the module header lists them).
--
-- Pure and deterministic: the same document always produces the same
-- result, with violations aggregated across independent sites,
-- sorted, and deduplicated.  On success the document is carried
-- onward as the same explicit resolved model under the 'Typed'
-- stage, and this function is the only public producer of a
-- @'CoreDocument' 'Typed'@.
typecheckCoreDocument
  :: CoreDocument Resolved
  -> Either TypingFailure (CoreDocument Typed)
typecheckCoreDocument (CoreDocument model) =
  case runCollect (checkModel model) of
    (problems, outcome) ->
      let (invariantProblems, userProblems) = partitionProblems problems
       in case NonEmpty.nonEmpty (normalizeInvariantViolations invariantProblems) of
            Just someInvariants ->
              Left (TypecheckerInvariantViolations someInvariants)
            Nothing ->
              case NonEmpty.nonEmpty (normalizeTypeViolations userProblems) of
                Just someViolations -> Left (TypeViolations someViolations)
                Nothing ->
                  case outcome of
                    Nothing -> Left internalCompletenessFailure
                    Just () -> Right (CoreDocument model)

-- | Split the one checking pass's problems into the internal and
-- user classes, preserving each class's order.
partitionProblems
  :: [TypingProblem]
  -> ([TypecheckerInvariantViolation], [TypeViolation])
partitionProblems = foldr classify ([], [])
  where
    classify problem (invariants, violations) =
      case problem of
        InternalTypingProblem violation ->
          (violation : invariants, violations)
        UserTypingProblem violation -> (invariants, violation : violations)

-- | The totality net: a checking pass that produced neither a result
-- nor a diagnostic is an implementation bug, classified as an
-- internal invariant failure rather than swallowed or thrown.
-- Unreachable while the checker upholds its contract that every
-- missing result traces to a reported problem.
internalCompletenessFailure :: TypingFailure
internalCompletenessFailure =
  TypecheckerInvariantViolations
    ( TypecheckerInvariantViolation
        []
        "the static typechecker produced neither a result nor a diagnostic"
        :| []
    )

-- | Deterministically sort type violations (by path, then message)
-- and remove duplicates.  This is the exact normalization applied by
-- 'typecheckCoreDocument' before violations are returned.
normalizeTypeViolations :: [TypeViolation] -> [TypeViolation]
normalizeTypeViolations = map NonEmpty.head . NonEmpty.group . sort

-- | The same normalization for invariant violations.
normalizeInvariantViolations
  :: [TypecheckerInvariantViolation] -> [TypecheckerInvariantViolation]
normalizeInvariantViolations = map NonEmpty.head . NonEmpty.group . sort
