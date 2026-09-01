{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Provenance of the distinguished @User@ anchor through the real
-- pipeline — resolution, the stored resolved identity, the typing
-- signature, the normalized anchor — rather than downstream
-- correlation over an already-normalized model.
--
-- The one place that selects the distinguished @User@ entity by its
-- schema-designated name is the resolver, whose entity-namespace
-- lookup resolves every @Actor@ term and is recorded once in the
-- resolved model ('R.modelUserEntity').  The typechecker's signature
-- carries exactly that stored identity — validating the declaration
-- it names and refusing, as an internal invariant, any
-- post-resolution drift of the descriptive metadata — and the
-- normalizer propagates it ('N.modelUserEntity').  These checks
-- establish that chain on the real S0 fixture, through the public
-- stage functions, with the package-private sublibrary as the
-- white-box seam:
--
-- 1. /User not at position zero./  The fixture with its entity list
--    rotated so that @User@ is the last declaration is a valid
--    authored document: the resolver stores the nonzero identity,
--    every @Actor@ term resolves to it, typing mints @Typed@ (which,
--    under the @Actor@ judgment, means the signature carried exactly
--    that identity), normalization propagates it, the shared support
--    gate anchors the subject at it, the injected checker runner is
--    invoked exactly once, the production verifier reports VERIFIED,
--    and the contract renders.  A forged copy whose stored anchor
--    says entity 0 (@Organization@ after the rotation) is refused at
--    the anchor: the signature reads the stored identity, never a
--    name scan (which would have found @User@ at entity 2 and passed).
-- 2. /Post-resolution name relocation./  Renaming the anchored
--    declaration away from @User@ and another declaration to @User@
--    — with or without redirecting every subject, parameter, and
--    @Actor@ evidence coherently to the renamed entity (the forgery a
--    name-scanning signature accepted, normalized, and verified) — is
--    refused as internal invariants naming the retained anchor
--    (entity 0); the renamed entity is never selected, and the forged
--    @Typed@ stage is refused by the normalizer's gate too.
-- 3. /Duplicate descriptive names./  A second (or a second and a
--    third) declaration named @User@ after resolution is refused
--    deterministically; no first match wins.
-- 4. /Stored-anchor metadata drift./  The anchored declaration
--    renamed, the stored identity moved to another declaration, the
--    stored identity naming no declaration, and the anchored
--    declaration's stored identifier displaced from its position are
--    each refused at the anchor, without any search for a replacement
--    — the displaced identifier by exactly the one missing-anchor
--    invariant, at the typechecker and at the normalizer's gate.
-- 5. /Actor inventories./  The @Actor@ occurrences the checks above
--    reason about are enumerated by two equivalent path-aware
--    traversals of the resolved and the normalized representation
--    ('resolvedActors', 'normalizedActors') that match every
--    term-bearing constructor explicitly.  Their exact path\/identity
--    inventories are pinned as literal lists — on S0 unrotated and
--    rotated, on the syntax-coverage fixture (lookup endpoints,
--    value-policy operands, an attribute-projection source, the
--    authenticated branch of an @AnyPrincipal@ pair, a @CreateEntity@
--    initializer), on a variant of it whose @Observe@ result and
--    @DeleteEntity@ target are the @Actor@, and on the two-case
--    fixture (a @SetRelation@ endpoint binding) — at both stages, so
--    the normalizer is shown to neither drop, add, reorder, nor
--    redirect an @Actor@ occurrence, and no check here can pass on an
--    empty or truncated traversal.
--
-- The downstream regressions over the normalized anchor (coherent
-- subject redirection, zero checker invocations, no production
-- checker discovery, Wasp 'RenderInvariant', S0 and the rule-2
-- fixtures still VERIFIED, the Wasp profile dispatcher lowering S0 as
-- Profile v0 and R1 as Profile v1 while refusing every other plan)
-- stay in "Mithril.CoreVerificationTests" and
-- "Mithril.CoreWaspTests".
module Mithril.DistinguishedUserTests
  ( tests
  ) where

import Data.Aeson (Result (..), Value (..), fromJSON, toJSON)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text

import Mithril.Core.Contract (renderCoreContract)
import Mithril.Core.Internal.Document (CoreDocument (..))
import qualified Mithril.Core.Internal.Normalized as N
import Mithril.Core.Internal.NspeSupportPlan (NspeSupportPlan (..), supportPlan)
import qualified Mithril.Core.Internal.Resolved as R
import Mithril.Core.Internal.Resolved (EntityId (..), Ref (..))
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , memberPath
  , rootPath
  , sourcePathSegments
  )
import Mithril.Core.Internal.Syntax (OneOrTwo (..))
import Mithril.Core.Internal.Verify (verifyModelWith)
import Mithril.Core.Normalization
  ( NormalizationFailure (..)
  , Normalized
  , NormalizerInvariantViolation (..)
  , normalizeCoreDocument
  )
import Mithril.Core.Resolution (Resolved, resolveCoreDocument)
import Mithril.Core.Typing
  ( TypecheckerInvariantViolation (..)
  , Typed
  , TypingFailure (..)
  , typecheckCoreDocument
  )
import Mithril.Core.Validation
  ( bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Core.Verification
  ( NspeRule (..)
  , VerificationResult (..)
  , VerifiedCase (..)
  , VerifiedObligation (..)
  , verifyCoreDocument
  )
import Mithril.Test (Check, check)

fixturePath :: FilePath
fixturePath = "test/fixtures/acme-nspe.mir.json"

-- | The well-typed syntax-coverage fixture (every Core v0 construct
-- through normalization), whose @Actor@ occurrences span lookup
-- endpoints, value-policy operands, an attribute-projection source,
-- the authenticated branch of an @AnyPrincipal@ allow pair, and a
-- @CreateEntity@ initializer.
welltypedPath :: FilePath
welltypedPath = "test/fixtures/welltyped.mir.json"

-- | The two-case rule-1/rule-2 fixture, whose bounded self-update
-- action binds the subject endpoint of its @SetRelation@ effect to
-- @Actor@.
selfUpdatePath :: FilePath
selfUpdatePath = "test/fixtures/acme-nspe-self-update.mir.json"

tests :: IO [Check]
tests = do
  bytes <- ByteString.readFile fixturePath
  welltypedBytes <- ByteString.readFile welltypedPath
  selfUpdateBytes <- ByteString.readFile selfUpdatePath
  let rotated = encodeValue (rotateEntities (decodeValue bytes))
      inventories =
        inventoryChecks "the syntax-coverage fixture" welltypedBytes welltypedActors
          <> inventoryChecks
            "the syntax-coverage fixture with User.inspect observing and Ticket.purge deleting the Actor"
            (encodeValue (actorObservedAndDeleted (decodeValue welltypedBytes)))
            welltypedActorsObservedAndDeleted
          <> inventoryChecks "the two-case rule-1/rule-2 fixture" selfUpdateBytes selfUpdateActors
  provenance <-
    case (resolveBytes bytes, resolveBytes rotated) of
      (Just baseDocument@(CoreDocument base), Just rotatedDocument) -> do
        rotatedChecks <- nonzeroUserChecks base rotatedDocument
        pure
          ( rotatedChecks
              <> relocationChecks base
              <> duplicateChecks base
              <> driftChecks base
              <> [ check
                    "the unrotated fixture typechecks and normalizes as before (control)"
                    ( case typecheckCoreDocument baseDocument of
                        Right typed -> either (const False) (const True) (normalizeCoreDocument typed)
                        Left _ -> False
                    )
                 ]
          )
      _ ->
        pure
          [ check
              "the S0 fixture and its entity-rotated variant resolve through the public pipeline (prerequisite)"
              False
          ]
  pure (provenance <> inventories)

--------------------------------------------------------------------
-- 1. User not at position zero
--------------------------------------------------------------------

-- | The rotated fixture — entities @[Organization, Project, User]@,
-- so the distinguished entity is @EntityId 2@ — followed through
-- every stage, with the unrotated model as the control that the
-- stored identity is the resolver's lookup and not a constant.
nonzeroUserChecks :: R.Model -> CoreDocument Resolved -> IO [Check]
nonzeroUserChecks base rotatedDocument@(CoreDocument rotated) = do
  let stored = R.modelUserEntity rotated
      userDeclarations =
        [ R.entityId entity
        | entity <- R.modelEntities rotated
        , sourcedValue (R.entityName entity) == "User"
        ]
      resolutionChecks =
        [ check
            "the rotated fixture declares User last: the resolver stores the nonzero identity of the one entity declared as User (entity 2), not entity 0"
            (stored == EntityId 2 && userDeclarations == [EntityId 2])
        , check
            "the unrotated fixture stores entity 0 and its Actor inventory is exactly the six S0 sites carrying entity 0: the stored identity is the resolver's lookup of the User declaration, not a constant"
            (R.modelUserEntity base == EntityId 0 && resolvedActors base == s0Actors (EntityId 0))
        , check
            "the Actor inventory of the rotated resolved model is exactly the six S0 sites, each resolved to the stored identity (entity 2)"
            (resolvedActors rotated == s0Actors (EntityId 2))
        , check
            "the rotated document's authority subject endpoint references the stored identity (entity 2)"
            (subjectEntityOf rotated == Just (EntityId 2))
        , check
            "a rotated copy whose stored anchor is forged to entity 0 (Organization) is refused at the anchor and at every one of the six Actor sites: the signature reads the stored identity, never a name scan that would have found User at entity 2"
            ( typingInvariants (withStoredAnchor (EntityId 0) rotated)
                == Just (sort ([driftAt 0 0 "Organization", otherAt 0 2] <> s0ActorInvariants))
            )
        ]
  case typecheckCoreDocument rotatedDocument of
    Left _ ->
      pure
        ( resolutionChecks
            <> [check "typechecking the rotated document mints Typed (prerequisite)" False]
        )
    Right typed ->
      case normalizeCoreDocument typed of
        Left _ ->
          pure
            ( resolutionChecks
                <> [check "normalizing the rotated document mints Normalized (prerequisite)" False]
            )
        Right normalized@(CoreDocument nmodel) -> do
          calls <- newIORef (0 :: Int)
          injected <-
            verifyModelWith
              (\_ -> modifyIORef' calls (+ 1) >> pure (Right ()))
              nmodel
          count <- readIORef calls
          production <- verifyCoreDocument normalized
          pure
            ( resolutionChecks
                <> [ check
                      "typechecking the rotated document mints Typed: under the Actor judgment the signature carried exactly the stored identity every Actor term denotes"
                      True
                   , check
                      "normalization propagates the stored identity into the normalized anchor (entity 2), and the normalized Actor inventory is exactly the six S0 sites carrying it"
                      ( N.modelUserEntity nmodel == EntityId 2
                          && normalizedActors nmodel == s0Actors (EntityId 2)
                      )
                   , check
                      "the shared support gate anchors the rotated document's subject at the propagated identity (entity 2, declared User)"
                      ( case supportPlan nmodel of
                          Right plan ->
                            planSubjectEntityId plan == EntityId 2
                              && sourcedValue (planSubjectEntityName plan) == "User"
                          Left _ -> False
                      )
                   , check
                      "the injected checker runner is invoked exactly once for the rotated document, and the obligation is the S0 rule-1 case"
                      (count == 1 && isS0Verdict injected)
                   , check
                      "the production verifier (real Agda 2.8.0) reports the rotated document VERIFIED"
                      (isS0Verdict production)
                   , check
                      "the contract renders for the rotated document"
                      (either (const False) (const True) (renderCoreContract normalized))
                   ]
            )

-- | The S0 verdict: the one @NoSelfPrivilegeEscalation@ obligation
-- with exactly the rule-1 @Membership.changeRole@ case at position 0.
isS0Verdict :: Either failure VerificationResult -> Bool
isS0Verdict outcome =
  case outcome of
    Right (VerificationVerified obligation) ->
      verifiedGuarantee obligation == "NoSelfPrivilegeEscalation"
        && fmap caseShape (verifiedCases obligation)
          == (0, ChangeOtherRule, "Membership.changeRole") :| []
    _ -> False
  where
    caseShape verified =
      (verifiedCasePosition verified, verifiedCaseRule verified, verifiedCaseAction verified)

--------------------------------------------------------------------
-- 2. Post-resolution name relocation
--------------------------------------------------------------------

relocationChecks :: R.Model -> [Check]
relocationChecks base =
  [ check
      "post-resolution relocation of the User name (entity 0 -> Person, entity 2 -> User) is refused at the retained anchor (entity 0) and at the renamed declaration; entity 2 is never selected"
      (typingInvariants relocated == Just relocationInvariants)
  , check
      "the forged Typed stage of the relocated model is refused by the normalizer's gate with the same anchor invariants"
      (normalizerInvariants relocated == Just (map reclassified relocationInvariants))
  , check
      "coherent relocation really redirects the subject endpoint and every one of the six Actor sites to the renamed entity 2 (the forgery under test)"
      ( subjectEntityOf coherent == Just (EntityId 2)
          && resolvedActors coherent == s0Actors (EntityId 2)
      )
  , check
      "coherent relocation — every subject, parameter, and Actor evidence redirected to the renamed entity 2 — is refused at the retained anchor and at every Actor term; no Typed stage exists"
      (typingInvariants coherent == Just coherentInvariants)
  , check
      "every anchor diagnostic of the coherent relocation names the retained anchor (entity 0), none another"
      ( case typingInvariants coherent of
          Just violations ->
            let anchored = filter (Text.isInfixOf "anchor the resolver stored" . typecheckerInvariantMessage) violations
             in not (null anchored)
                  && all (Text.isInfixOf "(entity 0)" . typecheckerInvariantMessage) anchored
          Nothing -> False
      )
  , check
      "the forged Typed stage of the coherently relocated model is refused by the normalizer's gate: the same anchor and Actor invariants plus the reclassified subject-endpoint judgment (the endpoint references the renamed entity, not the anchor)"
      ( normalizerInvariants coherent
          == Just (sort (map reclassified coherentInvariants <> [redirectedSubject]))
      )
  ]
  where
    relocated = renameEntity 2 "User" (renameEntity 0 "Person" base)
    relocationInvariants = [driftAt 0 0 "Person", otherAt 0 2]
    coherent = redirectEntity (EntityId 0) (EntityId 2) relocated
    coherentInvariants = sort (relocationInvariants <> s0ActorInvariants)
    -- The user-level typing judgment the typechecker drops when
    -- invariants dominate, resurfacing under the normalizer's
    -- reclassification prefix: the subject endpoint references the
    -- renamed entity (declared \"User\" after the relocation), not the
    -- anchored one.
    redirectedSubject =
      NormalizerInvariantViolation
        ["guarantees", "0", "authority", "subjectEndpoint"]
        "the typed document fails a static-typing judgment:\
        \ the subject endpoint \"user\" of relation \"Membership\" must reference\
        \ the distinguished \"User\" entity, but it references entity \"User\""

--------------------------------------------------------------------
-- 3. Duplicate descriptive names
--------------------------------------------------------------------

duplicateChecks :: R.Model -> [Check]
duplicateChecks base =
  [ check
      "a second declaration named User after resolution (entity 1) is refused deterministically at that declaration; the anchor stays entity 0 and no first match wins"
      (typingInvariants duplicated == Just [otherAt 0 1])
  , check
      "a second and a third declaration named User are both refused, in path order"
      (typingInvariants duplicatedTwice == Just [otherAt 0 1, otherAt 0 2])
  , check
      "the forged Typed stage of the duplicated model is refused by the normalizer's gate"
      (normalizerInvariants duplicated == Just [reclassified (otherAt 0 1)])
  ]
  where
    duplicated = renameEntity 1 "User" base
    duplicatedTwice = renameEntity 2 "User" duplicated

--------------------------------------------------------------------
-- 4. Stored-anchor metadata drift
--------------------------------------------------------------------

driftChecks :: R.Model -> [Check]
driftChecks base =
  [ check
      "renaming the anchored declaration (entity 0 -> Person) is refused at its name as drift of the stored anchor, with no search for a replacement"
      (typingInvariants renamed == Just [driftAt 0 0 "Person"])
  , check
      "the forged Typed stage of the renamed-anchor model is refused by the normalizer's gate"
      (normalizerInvariants renamed == Just [reclassified (driftAt 0 0 "Person")])
  , check
      "a stored anchor moved to another declaration (entity 2, Project) is refused at that declaration, at the real User declaration, and at every Actor term"
      ( typingInvariants (withStoredAnchor (EntityId 2) base)
          == Just (sort ([driftAt 2 2 "Project", otherAt 2 0] <> s0ActorInvariants))
      )
  , check
      "a stored anchor naming no declaration (entity 3) is refused at the document root and at every Actor term"
      ( typingInvariants (withStoredAnchor (EntityId 3) base)
          == Just (sort (missingAnchor 3 : s0ActorInvariants))
      )
  , check
      "an anchored declaration whose stored identifier is displaced from its position is refused by exactly the one missing-anchor invariant at the document root — no other diagnostic, none selecting another anchor"
      (typingInvariants displaced == Just [missingAnchor 0])
  , check
      "the forged Typed stage of the displaced-identifier model is refused by the normalizer's gate with exactly the reclassified missing-anchor invariant"
      (normalizerInvariants displaced == Just [reclassified (missingAnchor 0)])
  ]
  where
    renamed = renameEntity 0 "Person" base
    displaced = displaceEntityId 0 (EntityId 3) base

--------------------------------------------------------------------
-- 5. Actor inventories: resolved versus normalized
--------------------------------------------------------------------

-- | Pin the exact resolved and normalized @Actor@ inventories of one
-- authored document — the same literal path\/identity list at both
-- stages, so a traversal returning too few nodes, or none, fails.
inventoryChecks :: String -> ByteString -> [(SourcePath, EntityId)] -> [Check]
inventoryChecks label bytes expected =
  case resolveBytes bytes of
    Nothing ->
      [check (label <> " resolves through the public pipeline (prerequisite)") False]
    Just document@(CoreDocument model) ->
      [ check
          (label <> ": the resolved Actor inventory is exactly the expected path/identity list")
          (resolvedActors model == expected)
      , check
          ( label
              <> ": the normalized Actor inventory is exactly the same path/identity list"
              <> " — the normalizer neither drops, adds, reorders, nor redirects an Actor occurrence"
          )
          (normalizedActorsOf document == Just expected)
      ]

-- | The normalized inventory of a resolved document, through the
-- public typing and normalization stages.
normalizedActorsOf :: CoreDocument Resolved -> Maybe [(SourcePath, EntityId)]
normalizedActorsOf document =
  case typecheckCoreDocument document of
    Left _ -> Nothing
    Right typed ->
      case normalizeCoreDocument typed of
        Left _ -> Nothing
        Right (CoreDocument nmodel) -> Just (normalizedActors nmodel)

-- | A source path from its raw segments (array indices as their
-- decimal text, exactly as the decoder records them).
documentPath :: [Text] -> SourcePath
documentPath = foldl memberPath rootPath

-- | The six @Actor@ sites of the S0 fixture in traversal order: the
-- first @Membership@ lookup endpoint of @Project.read@,
-- @Project.create@, and @Project.delete@, the same endpoint under the
-- left conjunct of @Membership.addMember@ and of
-- @Membership.changeRole@, and the left @Equal@ operand under
-- @changeRole@'s @Not@.  Rotating the entity list moves no action, so
-- the rotated fixture has exactly these sites, carrying entity 2.
s0ActorPaths :: [SourcePath]
s0ActorPaths =
  map
    documentPath
    [ ["actions", "0", "allow", "right", "endpoints", "0"]
    , ["actions", "1", "allow", "right", "endpoints", "0"]
    , ["actions", "2", "allow", "right", "endpoints", "0"]
    , ["actions", "3", "allow", "left", "right", "endpoints", "0"]
    , ["actions", "4", "allow", "left", "right", "endpoints", "0"]
    , ["actions", "4", "allow", "right", "left", "value", "left"]
    ]

-- | The S0 inventory with every site carrying one identity.
s0Actors :: EntityId -> [(SourcePath, EntityId)]
s0Actors identity = [(site, identity) | site <- s0ActorPaths]

-- | The @Actor@ invariant the typechecker reports at each S0 site
-- whose term does not carry the stored anchor.
s0ActorInvariants :: [TypecheckerInvariantViolation]
s0ActorInvariants = map actorAt s0ActorPaths

-- | The seven @Actor@ sites of the syntax-coverage fixture in
-- traversal order, each carrying its distinguished entity (entity 0):
-- the first @Membership@ lookup endpoint of @Ticket.read@'s allow
-- policy; @Ticket.file@'s lookup endpoint and then its @CreateEntity@
-- @owner@ initializer; the attribute-projection source under
-- @User.inspect@'s @Equal@; the right @Equal@ operand of
-- @Ticket.purge@; the left @Equal@ operand under
-- @Membership.assign@'s @Not@; and the @Marked@ lookup endpoint of
-- @Status.check@'s authenticated @AnyPrincipal@ branch.
welltypedActors :: [(SourcePath, EntityId)]
welltypedActors =
  [ (documentPath segments, EntityId 0)
  | segments <-
      [ ["actions", "0", "allow", "right", "endpoints", "0"]
      , ["actions", "1", "allow", "value", "endpoints", "0"]
      , ["actions", "1", "effect", "attributes", "owner"]
      , ["actions", "2", "allow", "right", "left", "source"]
      , ["actions", "3", "allow", "right"]
      , ["actions", "4", "allow", "left", "value", "left"]
      , ["actions", "6", "allow", "authenticated", "value", "endpoints", "0"]
      ]
  ]

-- | The nine sites of 'actorObservedAndDeleted': 'welltypedActors'
-- plus @User.inspect@'s @Observe@ result (after its allow policy) and
-- @Ticket.purge@'s @DeleteEntity@ target (after its allow policy).
welltypedActorsObservedAndDeleted :: [(SourcePath, EntityId)]
welltypedActorsObservedAndDeleted =
  [ (documentPath segments, EntityId 0)
  | segments <-
      [ ["actions", "0", "allow", "right", "endpoints", "0"]
      , ["actions", "1", "allow", "value", "endpoints", "0"]
      , ["actions", "1", "effect", "attributes", "owner"]
      , ["actions", "2", "allow", "right", "left", "source"]
      , ["actions", "2", "result", "entity"]
      , ["actions", "3", "allow", "right"]
      , ["actions", "3", "effect", "target"]
      , ["actions", "4", "allow", "left", "value", "left"]
      , ["actions", "6", "allow", "authenticated", "value", "endpoints", "0"]
      ]
  ]

-- | The eight sites of the two-case fixture: the six S0 sites, then
-- in @Membership.changeOwnRole@ (action 5) the first @Membership@
-- lookup endpoint of its allow policy and the subject endpoint term
-- of its @SetRelation@ effect.
selfUpdateActors :: [(SourcePath, EntityId)]
selfUpdateActors =
  [ (documentPath segments, EntityId 0)
  | segments <-
      [ ["actions", "0", "allow", "right", "endpoints", "0"]
      , ["actions", "1", "allow", "right", "endpoints", "0"]
      , ["actions", "2", "allow", "right", "endpoints", "0"]
      , ["actions", "3", "allow", "left", "right", "endpoints", "0"]
      , ["actions", "4", "allow", "left", "right", "endpoints", "0"]
      , ["actions", "4", "allow", "right", "left", "value", "left"]
      , ["actions", "5", "allow", "right", "endpoints", "0"]
      , ["actions", "5", "effect", "endpoints", "0"]
      ]
  ]

--------------------------------------------------------------------
-- Expected diagnostics
--------------------------------------------------------------------

anchorLabel :: Int -> Text
anchorLabel position =
  "the distinguished \"User\" anchor the resolver stored (entity "
    <> Text.pack (show position)
    <> ")"

entityNamePath :: Int -> [Text]
entityNamePath position = ["schema", "entities", Text.pack (show position), "name"]

-- | The anchored declaration carries a name other than @User@.
driftAt :: Int -> Int -> Text -> TypecheckerInvariantViolation
driftAt anchor position name =
  TypecheckerInvariantViolation
    (entityNamePath position)
    ("the entity " <> anchorLabel anchor <> " names is declared as " <> Text.pack (show name))

-- | A declaration other than the anchored one carries the name @User@.
otherAt :: Int -> Int -> TypecheckerInvariantViolation
otherAt anchor position =
  TypecheckerInvariantViolation
    (entityNamePath position)
    ("an entity other than the one " <> anchorLabel anchor <> " names is declared as \"User\"")

-- | The stored anchor names no canonical declaration at its position.
missingAnchor :: Int -> TypecheckerInvariantViolation
missingAnchor anchor =
  TypecheckerInvariantViolation
    []
    (anchorLabel anchor <> " does not name the canonical entity declaration at its position")

-- | An @Actor@ term that does not carry the anchored identity.
actorAt :: SourcePath -> TypecheckerInvariantViolation
actorAt path =
  TypecheckerInvariantViolation
    (sourcePathSegments path)
    "an Actor term does not reference the distinguished \"User\" entity"

-- | The normalizer's verbatim reclassification of a typechecker
-- invariant.
reclassified :: TypecheckerInvariantViolation -> NormalizerInvariantViolation
reclassified (TypecheckerInvariantViolation path message) =
  NormalizerInvariantViolation path message

--------------------------------------------------------------------
-- Stage outcomes
--------------------------------------------------------------------

typingInvariants :: R.Model -> Maybe [TypecheckerInvariantViolation]
typingInvariants model =
  case typecheckCoreDocument (CoreDocument model :: CoreDocument Resolved) of
    Left (TypecheckerInvariantViolations violations) -> Just (NonEmpty.toList violations)
    _ -> Nothing

-- | The normalizer over a forged @Typed@ stage — the constructor the
-- package-private sublibrary exposes to this suite and no public
-- caller can use.
normalizerInvariants :: R.Model -> Maybe [NormalizerInvariantViolation]
normalizerInvariants model =
  case normalizeCoreDocument (CoreDocument model :: CoreDocument Typed) of
    Left (NormalizerInvariantViolations violations) -> Just (NonEmpty.toList violations)
    Right (_ :: CoreDocument Normalized) -> Nothing

resolveBytes :: ByteString -> Maybe (CoreDocument Resolved)
resolveBytes bytes = do
  schema <- rightMaybe bundledCoreSchema
  parsed <- rightMaybe (parseCoreDocument bytes)
  valid <- rightMaybe (validateCoreDocument schema parsed)
  rightMaybe (resolveCoreDocument valid)

rightMaybe :: Either e a -> Maybe a
rightMaybe = either (const Nothing) Just

--------------------------------------------------------------------
-- Authored-document surgery
--------------------------------------------------------------------

-- | Move the first entity declaration to the end of the entity list
-- (every reference in the document is by name, so the document stays
-- valid and @User@ becomes the last declaration).
rotateEntities :: Value -> Value
rotateEntities = overMember "schema" (overMember "entities" rotate)
  where
    rotate value =
      case asList value of
        first : rest -> toJSON (rest <> [first])
        [] -> value

-- | Replace the @Observe@ result of action 2 (@User.inspect@) and the
-- @DeleteEntity@ target of action 3 (@Ticket.purge@) of the
-- syntax-coverage fixture by the @Actor@ — both well-typed, since an
-- @Actor@ is an entity reference — so that the @Observe@-result and
-- @DeleteEntity@-target sites carry an @Actor@ occurrence too.
actorObservedAndDeleted :: Value -> Value
actorObservedAndDeleted =
  overMember
    "actions"
    ( overIndex 2 (overMember "result" (overMember "entity" (const actorTerm)))
        . overIndex 3 (overMember "effect" (overMember "target" (const actorTerm)))
    )

actorTerm :: Value
actorTerm = Object (KeyMap.fromList [(Key.fromText "kind", String "Actor")])

overMember :: Text -> (Value -> Value) -> Value -> Value
overMember name mutate value =
  case value of
    Object members ->
      case KeyMap.lookup key members of
        Just found -> Object (KeyMap.insert key (mutate found) members)
        Nothing -> value
    other -> other
  where
    key = Key.fromText name

overIndex :: Int -> (Value -> Value) -> Value -> Value
overIndex position mutate value =
  case fromJSON value of
    Success (items :: [Value]) ->
      toJSON
        [ if index == position then mutate item else item
        | (index, item) <- zip [0 :: Int ..] items
        ]
    Error _ -> value

asList :: Value -> [Value]
asList value =
  case fromJSON value of
    Success values -> values
    Error _ -> []

decodeValue :: ByteString -> Value
decodeValue bytes = fromMaybe Null (Aeson.decodeStrict bytes)

encodeValue :: Value -> ByteString
encodeValue = LazyByteString.toStrict . Aeson.encode

--------------------------------------------------------------------
-- Resolved-model surgery (post-resolution drift)
--------------------------------------------------------------------

renameEntity :: Int -> Text -> R.Model -> R.Model
renameEntity position newName model =
  model
    { R.modelEntities =
        [ if index == position
            then entity {R.entityName = (R.entityName entity) {sourcedValue = newName}}
            else entity
        | (index, entity) <- zip [0 :: Int ..] (R.modelEntities model)
        ]
    }

withStoredAnchor :: EntityId -> R.Model -> R.Model
withStoredAnchor anchor model = model {R.modelUserEntity = anchor}

displaceEntityId :: Int -> EntityId -> R.Model -> R.Model
displaceEntityId position identity model =
  model
    { R.modelEntities =
        [ if index == position then entity {R.entityId = identity} else entity
        | (index, entity) <- zip [0 :: Int ..] (R.modelEntities model)
        ]
    }

-- | Redirect every resolved reference to one entity — endpoint
-- entities, declared attribute and parameter types, @CreateEntity@
-- targets — and every @Actor@ term carrying it, to another entity.
redirectEntity :: EntityId -> EntityId -> R.Model -> R.Model
redirectEntity from to model =
  model
    { R.modelEntities = map entity (R.modelEntities model)
    , R.modelRelations = map relation (R.modelRelations model)
    , R.modelActions = map action (R.modelActions model)
    , R.modelGuarantees = map guarantee (R.modelGuarantees model)
    }
  where
    ref :: Ref EntityId -> Ref EntityId
    ref reference = if refTarget reference == from then reference {refTarget = to} else reference
    entity declaration = declaration {R.entityAttributes = map attribute (R.entityAttributes declaration)}
    attribute declaration =
      declaration
        { R.attributeType =
            case R.attributeType declaration of
              R.EntityRefAttributeType path reference -> R.EntityRefAttributeType path (ref reference)
              other -> other
        }
    relation declaration = declaration {R.relationEndpoints = fmap endpoint (R.relationEndpoints declaration)}
    endpoint declaration = declaration {R.endpointEntity = ref (R.endpointEntity declaration)}
    action declaration =
      declaration
        { R.actionParameters = map parameter (R.actionParameters declaration)
        , R.actionBody =
            case R.actionBody declaration of
              R.AuthenticatedOnlyBody allow shape -> R.AuthenticatedOnlyBody (policy allow) (shapeOf shape)
              R.AnyPrincipalBody (R.AnyPrincipalAllow anonymous authenticated) shape ->
                R.AnyPrincipalBody (R.AnyPrincipalAllow (policy anonymous) (policy authenticated)) (shapeOf shape)
        }
    parameter declaration =
      declaration
        { R.parameterType =
            case R.parameterType declaration of
              R.EntityRefParameterType path reference -> R.EntityRefParameterType path (ref reference)
              other -> other
        }
    shapeOf :: R.ActionShape availability -> R.ActionShape availability
    shapeOf shape =
      case shape of
        R.ReadShape path resultPath result -> R.ReadShape path resultPath (value result)
        R.CreateShape (R.CreateEntityEffect path target initializers) resultPath ->
          R.CreateShape
            ( R.CreateEntityEffect
                path
                (ref target)
                [R.Initializer key (value term) | R.Initializer key term <- initializers]
            )
            resultPath
        R.MutationShape effect resultPath -> R.MutationShape (effectOf effect) resultPath
    effectOf :: R.DoneEffect availability -> R.DoneEffect availability
    effectOf effect =
      case effect of
        R.NoChangeEffect path -> R.NoChangeEffect path
        R.DeleteEntityEffect path term -> R.DeleteEntityEffect path (value term)
        R.SetRelationEffect path relationRef terms payload ->
          R.SetRelationEffect path relationRef (fmap value terms) (value payload)
        R.RemoveRelationEffect path relationRef terms ->
          R.RemoveRelationEffect path relationRef (fmap value terms)
    value :: R.ValueTerm availability -> R.ValueTerm availability
    value term =
      case term of
        R.ActorTerm path carried -> R.ActorTerm path (if carried == from then to else carried)
        R.AttributeTerm path source member -> R.AttributeTerm path (value source) member
        other -> other
    policy :: R.PolicyTerm availability -> R.PolicyTerm availability
    policy term =
      case term of
        R.ValuePolicyTerm inner -> R.ValuePolicyTerm (value inner)
        R.LookupTerm path relationRef terms -> R.LookupTerm path relationRef (fmap value terms)
        R.NoneTerm path payload -> R.NoneTerm path payload
        R.SomeTerm path inner -> R.SomeTerm path (value inner)
        R.IsSomeTerm path inner -> R.IsSomeTerm path (policy inner)
        R.EqualTerm path left right -> R.EqualTerm path (policy left) (policy right)
        R.LessOrEqualTerm path left right -> R.LessOrEqualTerm path (policy left) (policy right)
        R.AndTerm path left right -> R.AndTerm path (policy left) (policy right)
        R.OrTerm path left right -> R.OrTerm path (policy left) (policy right)
        R.NotTerm path inner -> R.NotTerm path (policy inner)
    guarantee declaration =
      case declaration of
        R.NoSelfPrivilegeEscalationGuarantee path authority cases ->
          R.NoSelfPrivilegeEscalationGuarantee path authority (fmap escalationCase cases)
        other -> other
    escalationCase declaration =
      declaration {R.escalationCaseScope = fmap value (R.escalationCaseScope declaration)}

--------------------------------------------------------------------
-- Projections
--------------------------------------------------------------------

-- | The entity the first relation's first (subject) endpoint
-- references — the S0 authority's subject endpoint.
subjectEntityOf :: R.Model -> Maybe EntityId
subjectEntityOf model =
  case R.modelRelations model of
    relation : _ ->
      case R.relationEndpoints relation of
        Two subject _ -> Just (refTarget (R.endpointEntity subject))
        One subject -> Just (refTarget (R.endpointEntity subject))
    [] -> Nothing

--------------------------------------------------------------------
-- Actor inventories
--------------------------------------------------------------------

-- The two traversals below are the same walk over the two
-- representations, and both match every constructor of every
-- term-bearing type explicitly, with no wildcard: a constructor added
-- to either representation fails this suite's compilation under the
-- repository warning set (@-Wincomplete-patterns@) instead of
-- silently escaping the inventory.  Schema declarations (entities,
-- attributes, enums, relations, endpoints) hold no terms and are not
-- walked.  The @'ActorFree@ trees — an @AnyPrincipal@ action's
-- anonymous policy and shape, and @TenantIsolation@ case terms —
-- cannot contain an @Actor@ (the constructor inhabits only
-- @'ActorAvailable@ trees), so walking them contributes nothing by
-- construction; they are walked all the same, so no subtree is
-- skipped by assumption.

-- | Every @Actor@ term of a resolved model with its retained source
-- path and the entity it carries, in traversal order: action by
-- action in authored order — the allow policy (both branches of an
-- @AnyPrincipal@ pair, anonymous first), then the shape (the
-- @Observe@ result; the @CreateEntity@ initializers in the resolved
-- model's ascending-key listing; or the @Done@ effect's target,
-- endpoint, and payload terms) — followed by the guarantees' case
-- terms in authored order.
resolvedActors :: R.Model -> [(SourcePath, EntityId)]
resolvedActors model =
  concatMap action (R.modelActions model) <> concatMap guarantee (R.modelGuarantees model)
  where
    action :: R.Action -> [(SourcePath, EntityId)]
    action declaration =
      case R.actionBody declaration of
        R.AuthenticatedOnlyBody allow shape -> policy allow <> shapeOf shape
        R.AnyPrincipalBody (R.AnyPrincipalAllow anonymous authenticated) shape ->
          policy anonymous <> policy authenticated <> shapeOf shape
    shapeOf :: R.ActionShape availability -> [(SourcePath, EntityId)]
    shapeOf shape =
      case shape of
        R.ReadShape _ _ observed -> value observed
        R.CreateShape effect _ -> createEffect effect
        R.MutationShape effect _ -> doneEffect effect
    createEffect :: R.CreateEntityEffect availability -> [(SourcePath, EntityId)]
    createEffect (R.CreateEntityEffect _ _ initializers) =
      concatMap (value . R.initializerValue) initializers
    doneEffect :: R.DoneEffect availability -> [(SourcePath, EntityId)]
    doneEffect effect =
      case effect of
        R.NoChangeEffect _ -> []
        R.DeleteEntityEffect _ target -> value target
        R.SetRelationEffect _ _ terms payload -> concatMap value (endpointList terms) <> value payload
        R.RemoveRelationEffect _ _ terms -> concatMap value (endpointList terms)
    value :: R.ValueTerm availability -> [(SourcePath, EntityId)]
    value term =
      case term of
        R.BoolTerm _ _ -> []
        R.UnitTerm _ -> []
        R.EnumTerm _ _ _ -> []
        R.ArgumentTerm _ _ -> []
        R.ActorTerm path carried -> [(path, carried)]
        R.AttributeTerm _ source _ -> value source
    policy :: R.PolicyTerm availability -> [(SourcePath, EntityId)]
    policy term =
      case term of
        R.ValuePolicyTerm inner -> value inner
        R.LookupTerm _ _ terms -> concatMap value (endpointList terms)
        R.NoneTerm _ _ -> []
        R.SomeTerm _ inner -> value inner
        R.IsSomeTerm _ inner -> policy inner
        R.EqualTerm _ left right -> policy left <> policy right
        R.LessOrEqualTerm _ left right -> policy left <> policy right
        R.AndTerm _ left right -> policy left <> policy right
        R.OrTerm _ left right -> policy left <> policy right
        R.NotTerm _ inner -> policy inner
    guarantee :: R.Guarantee -> [(SourcePath, EntityId)]
    guarantee declaration =
      case declaration of
        R.AuthenticatedMutationGuarantee _ -> []
        R.TenantIsolationGuarantee _ _ cases ->
          concatMap
            (\c -> value (R.tenantIsolationCaseTenant c) <> policy (R.tenantIsolationCaseProtected c))
            (NonEmpty.toList cases)
        R.NoSelfPrivilegeEscalationGuarantee _ _ cases ->
          concatMap (maybe [] value . R.escalationCaseScope) (NonEmpty.toList cases)

-- | Every stored @Actor@ node of a normalized model with the term's
-- retained source path and the entity it carries — the same walk as
-- 'resolvedActors' over the normalized representation (endpoint
-- terms through their explicit bindings, escalation-case scopes
-- through their scope bindings).  The one ordering the normalizer
-- changes is a @CreateEntity@ effect's initializer listing (target
-- attribute declaration order instead of ascending key order); the
-- fixtures pinned here carry at most one @Actor@ initializer per
-- effect, so the two inventories coincide exactly.
normalizedActors :: N.Model -> [(SourcePath, EntityId)]
normalizedActors model =
  concatMap action (N.modelActions model) <> concatMap guarantee (N.modelGuarantees model)
  where
    action :: N.Action -> [(SourcePath, EntityId)]
    action declaration =
      case N.actionBody declaration of
        N.AuthenticatedOnlyBody allow shape -> policy allow <> shapeOf shape
        N.AnyPrincipalBody (N.AnyPrincipalAllow anonymous authenticated) shape ->
          policy anonymous <> policy authenticated <> shapeOf shape
    shapeOf :: N.ActionShape availability -> [(SourcePath, EntityId)]
    shapeOf shape =
      case shape of
        N.ReadShape _ _ observed -> value observed
        N.CreateShape effect _ -> createEffect effect
        N.MutationShape effect _ -> doneEffect effect
    createEffect :: N.CreateEntityEffect availability -> [(SourcePath, EntityId)]
    createEffect (N.CreateEntityEffect _ _ initializers) =
      concatMap (value . N.initializerValue) initializers
    doneEffect :: N.DoneEffect availability -> [(SourcePath, EntityId)]
    doneEffect effect =
      case effect of
        N.NoChangeEffect _ -> []
        N.DeleteEntityEffect _ target -> value target
        N.SetRelationEffect _ _ bindings payload ->
          concatMap binding (endpointList bindings) <> value payload
        N.RemoveRelationEffect _ _ bindings -> concatMap binding (endpointList bindings)
    binding :: N.EndpointBinding availability -> [(SourcePath, EntityId)]
    binding = value . N.endpointBindingTerm
    value :: N.ValueTerm availability -> [(SourcePath, EntityId)]
    value term =
      case N.valueTermNode term of
        N.BoolNode _ -> []
        N.UnitNode -> []
        N.EnumNode _ _ -> []
        N.ArgumentNode _ -> []
        N.ActorNode carried -> [(N.valueTermPath term, carried)]
        N.AttributeNode source _ -> value source
    policy :: N.PolicyTerm availability -> [(SourcePath, EntityId)]
    policy term =
      case N.policyTermNode term of
        N.ValuePolicyNode inner -> value inner
        N.LookupNode _ bindings -> concatMap binding (endpointList bindings)
        N.NoneNode _ -> []
        N.SomeNode inner -> value inner
        N.IsSomeNode inner -> policy inner
        N.EqualNode left right -> policy left <> policy right
        N.LessOrEqualNode _ left right -> policy left <> policy right
        N.AndNode left right -> policy left <> policy right
        N.OrNode left right -> policy left <> policy right
        N.NotNode inner -> policy inner
    guarantee :: N.Guarantee -> [(SourcePath, EntityId)]
    guarantee declaration =
      case declaration of
        N.AuthenticatedMutationGuarantee _ -> []
        N.TenantIsolationGuarantee _ _ cases ->
          concatMap
            (\c -> value (N.tenantIsolationCaseTenant c) <> policy (N.tenantIsolationCaseProtected c))
            (NonEmpty.toList cases)
        N.NoSelfPrivilegeEscalationGuarantee _ _ cases ->
          concatMap
            (maybe [] (value . N.scopeBindingTerm) . N.escalationCaseScope)
            (NonEmpty.toList cases)

endpointList :: OneOrTwo a -> [a]
endpointList (One a) = [a]
endpointList (Two a b) = [a, b]
