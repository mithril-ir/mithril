{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE TypeFamilies #-}

-- | __Internal module — never expose.__
--
-- This module owns the pipeline-stage machinery shared by the
-- frontend stages: the opaque 'CoreDocument' representation, its
-- nominal role annotation, the type-level stage indexes, and the
-- 'StagePayload' family that fixes what each stage carries.  It
-- lives in the package-private @core-internal@ sublibrary
-- (@visibility: private@), so no code outside this package can import
-- it, while the package's own test suite and in-package probes can —
-- that sublibrary is the one deliberate white-box seam.  The public
-- surface consists exclusively of the abstract re-exports from
-- "Mithril.Core.Validation", "Mithril.Core.Resolution",
-- "Mithril.Core.Typing", and "Mithril.Core.Normalization".
--
-- Keeping the constructor here — importable by the frontend stage
-- modules, invisible to everything else — is what lets structural
-- validation, name resolution, static typing, and normalization each
-- perform their stage transition while external code can neither
-- construct a 'CoreDocument', nor extract its underlying payload,
-- nor coerce one stage index into another.  The one public function
-- outside these stage modules that hands out a 'CoreDocument' —
-- 'Mithril.Command.Validate.validateCoreFile', which returns the
-- 'Normalized' result of a successful run — orchestrates the
-- complete pipeline through exactly the four stage-transition
-- producers below and mints no stage independently.
module Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , StagePayload
  , Parsed
  , StructurallyValid
  , Resolved
  , Typed
  , Normalized
  ) where

import Data.Aeson (Value)

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.Resolved (Model)

-- | Type-level stage index: the bytes parsed as JSON, with no further
-- fact established.
data Parsed

-- | Type-level stage index: structurally valid against the
-- compiled-in canonical Core v0 schema profile.  Structural validity
-- is a fact about JSON shape only; it is not resolution, typing,
-- normalization, or any semantic or security property.
data StructurallyValid

-- | Type-level stage index: every Core v0 name site of the document
-- has been checked by the resolver — declaration names are unique in
-- their namespaces and every name reference resolves in its correct
-- namespace — and the document has been decoded into the explicit
-- resolved representation ("Mithril.Core.Internal.Resolved").  This
-- is an attestation about names only: a @'CoreDocument' 'Resolved'@
-- is /not/ typed, not normalized, not verified, and carries no
-- semantic or security property beyond name resolution.
data Resolved

-- | Type-level stage index: the resolved document additionally
-- satisfies every Core v0 static-typing judgment — term, policy,
-- effect, and result typing, operand compatibility, enum-order
-- permutation validity, relation endpoint and payload compatibility,
-- @CreateEntity@ initializer completeness and value typing, and
-- guarantee well-typedness ("Mithril.Core.Typing" states the exact
-- judgment).  This is an attestation about static types only: a
-- @'CoreDocument' 'Typed'@ is /not/ normalized, not verified, and
-- carries no semantic or security property beyond well-typedness —
-- in particular no guarantee is established by it.
data Typed

-- | Type-level stage index: the well-typed document has additionally
-- been normalized into the explicit typed normalized Core
-- representation ("Mithril.Core.Internal.Normalized") — typed terms,
-- materialized enum ranks, explicit endpoint bindings,
-- declaration-ordered initializers, and explicit guarantee structure,
-- the single form the contract renderer (implemented, in
-- "Mithril.Core.Contract"), the future Agda backend, and the future
-- target emitters consume.  This is an attestation about
-- deterministic structural normalization only: a
-- @'CoreDocument' 'Normalized'@ is /not/ verified, carries no
-- semantic or security property beyond well-typed normalized
-- structure, and in particular no policy was evaluated and no
-- guarantee was established by producing it.
data Normalized

-- | What a document at each stage carries.  The two syntactic stages
-- still hold the opaque parsed JSON value; the resolved and typed
-- stages hold the explicit decoded and name-resolved Core
-- representation — the raw JSON is discarded at the resolution
-- boundary, so no later compiler stage can be written over generic
-- JSON, and the typechecker adds a judgment over that same explicit
-- model, not a second representation.  The normalized stage holds
-- the distinct explicit typed normalized model the normalizer
-- constructs from the typed payload.
type family StagePayload stage where
  StagePayload Parsed = Value
  StagePayload StructurallyValid = Value
  StagePayload Resolved = Model
  StagePayload Typed = Model
  StagePayload Normalized = Normalized.Model

-- | A Mithril Core v0 document at a pipeline stage, opaque by design.
--
-- The constructor and the stage payloads never leave the package:
-- later compiler stages must not be able to consume a merely 'Parsed'
-- value while bypassing structural validation, nor a merely
-- 'StructurallyValid' value while bypassing name resolution — and no
-- external code can reach the resolved representation, extract a JSON
-- value, or mint identifiers.  The only public producer of a
-- @'CoreDocument' 'StructurallyValid'@ is structural validation
-- against the compiled-in gated schema
-- ('Mithril.Core.Validation.validateCoreDocument'), the only public
-- producer of a @'CoreDocument' 'Resolved'@ is
-- 'Mithril.Core.Resolution.resolveCoreDocument', the only public
-- producer of a @'CoreDocument' 'Typed'@ is
-- 'Mithril.Core.Typing.typecheckCoreDocument', and the only direct
-- public producer of the @'Typed'@ → @'Normalized'@ stage transition
-- is 'Mithril.Core.Normalization.normalizeCoreDocument' (the
-- pipeline-orchestrating 'Mithril.Command.Validate.validateCoreFile'
-- publicly returns the resulting normalized document, but obtains it
-- from exactly that transition).
newtype CoreDocument stage = CoreDocument (StagePayload stage)

-- The stage index only appears under the 'StagePayload' family, which
-- already forces its role to nominal; the annotation keeps the intent
-- explicit — without nominality, 'Data.Coerce.coerce' could forge a
-- stage transition without going through the stage's checking
-- function.
type role CoreDocument nominal
