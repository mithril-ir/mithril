{-# LANGUAGE RoleAnnotations #-}

-- | __Internal module — never expose.__
--
-- This module owns the pipeline-stage machinery shared by the
-- frontend stages: the opaque 'CoreDocument' representation, its
-- nominal role annotation, and the type-level stage indexes.  It is
-- listed under @other-modules@ in the Cabal description, so no code
-- outside this package can import it; the public surface consists
-- exclusively of the abstract re-exports from
-- "Mithril.Core.Validation" and "Mithril.Core.Resolution".
--
-- Keeping the constructor here — importable by the frontend stage
-- modules, invisible to everything else — is what lets structural
-- validation and name resolution each perform their stage transition
-- while external code can neither construct a 'CoreDocument', nor
-- extract its underlying JSON value, nor coerce one stage index into
-- another.
module Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Parsed
  , StructurallyValid
  , Resolved
  ) where

import Data.Aeson (Value)

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
-- namespace.  This is an attestation about names only: a
-- @'CoreDocument' 'Resolved'@ is /not/ typed, not normalized, not
-- verified, and carries no semantic or security property beyond name
-- resolution.
data Resolved

-- | A Mithril Core v0 document at a pipeline stage, opaque by design.
--
-- The constructor and the wrapped Aeson 'Value' never leave the
-- package: later compiler stages must not be able to consume a merely
-- 'Parsed' value while bypassing structural validation, nor a merely
-- 'StructurallyValid' value while bypassing name resolution.  The
-- only public producer of a @'CoreDocument' 'StructurallyValid'@ is
-- structural validation against the compiled-in gated schema
-- ('Mithril.Core.Validation.validateCoreDocument'), and the only
-- public producer of a @'CoreDocument' 'Resolved'@ is
-- 'Mithril.Core.Resolution.resolveCoreDocument'.
newtype CoreDocument stage = CoreDocument Value

-- The stage index is phantom; without this annotation GHC would infer
-- a phantom role and 'Data.Coerce.coerce' could forge a stage
-- transition without going through the stage's checking function.
type role CoreDocument nominal
