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
-- "Mithril.Core.Validation" and "Mithril.Core.Resolution".
--
-- Keeping the constructor here — importable by the frontend stage
-- modules, invisible to everything else — is what lets structural
-- validation and name resolution each perform their stage transition
-- while external code can neither construct a 'CoreDocument', nor
-- extract its underlying payload, nor coerce one stage index into
-- another.
module Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , StagePayload
  , Parsed
  , StructurallyValid
  , Resolved
  ) where

import Data.Aeson (Value)

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

-- | What a document at each stage carries.  The two syntactic stages
-- still hold the opaque parsed JSON value; the resolved stage holds
-- the explicit decoded and name-resolved Core representation — the
-- raw JSON is discarded at that boundary, so no later compiler stage
-- can be written over generic JSON.
type family StagePayload stage where
  StagePayload Parsed = Value
  StagePayload StructurallyValid = Value
  StagePayload Resolved = Model

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
-- ('Mithril.Core.Validation.validateCoreDocument'), and the only
-- public producer of a @'CoreDocument' 'Resolved'@ is
-- 'Mithril.Core.Resolution.resolveCoreDocument'.
newtype CoreDocument stage = CoreDocument (StagePayload stage)

-- The stage index only appears under the 'StagePayload' family, which
-- already forces its role to nominal; the annotation keeps the intent
-- explicit — without nominality, 'Data.Coerce.coerce' could forge a
-- stage transition without going through the stage's checking
-- function.
type role CoreDocument nominal
