{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}

-- | __Internal module — never expose.__
--
-- The Wasp emitter of the Core v0 host tool: deterministic lowering of
-- the one shared NoSelfPrivilegeEscalation support plan
-- ("Mithril.Core.Internal.NspeSupportPlan") into a closed Wasp 0.25.0
-- application bundle — the /Wasp Confinement Profile v0/ for a
-- singleton rule-1 plan, or the /Wasp Confinement Profile v1/ for
-- exactly the ordered rule-1, rule-2 case pair.  The public boundary
-- is exactly "Mithril.Core.Wasp"; the effectful filesystem boundary
-- is "Mithril.Core.Internal.WaspFilesystem" behind the CLI boundary
-- "Mithril.Command.Wasp"; the pure checker that decides whether a
-- source-root snapshot is exactly a regenerated bundle is
-- "Mithril.Core.Internal.WaspConfinement".
--
-- == What is generated
--
-- Exactly the supported case shapes, and nothing else: a normal Wasp
-- 0.25.0 application whose complete security-sensitive input surface
-- is owned by this emitter —
--
-- * the TypeScript specification @main.wasp.ts@ (Wasp auth with
--   username-and-password, exactly one route\/page, and exactly the
--   profile's authenticated Actions: one for Profile v0, two for
--   Profile v1);
-- * the Prisma schema (PostgreSQL datasource; the subject and scope
--   entities as models, the authority relation as a model with a
--   composite identity over its endpoint fields and the payload enum
--   as its payload column, the authority enum's values in declaration
--   order);
-- * the generated TypeScript Action implementation(s), all in the one
--   file @src\/mithrilCaseAction.ts@: every Action requires Wasp
--   authentication, uses @context.user.id@ as the only identity,
--   validates its arguments, reads the authority tuples it needs and
--   performs the authorized @SetRelation@ write inside one Prisma
--   interactive transaction at @Serializable@ isolation, retries
--   Prisma @P2034@ conflicts a fixed number of times, and uses no raw
--   SQL — the rule-1 Action @mithrilCaseAction@ changes /another/
--   subject's authority behind the privilege floor, the actor\/subject
--   guard, and the subject-membership condition; the rule-2 Action
--   @mithrilSelfUpdateAction@ (Profile v1 only) writes the actor's
--   /own/ tuple to a payload bounded by the actor's pre-state
--   authority, with no caller-supplied subject argument;
-- * the dependency configuration, TypeScript and Vite configuration,
--   the Wasp root marker, the Mithril ownership marker, the ignore
--   files, a minimal static client page (the client shell Wasp
--   requires), and a deterministic generation manifest.
--
-- == Target names: fixed, role-derived, collision-free
--
-- No authored Core name ever becomes an identifier of the generated
-- application.  Every Prisma model, enum, value, and field name,
-- every TypeScript identifier, each Wasp operation, its route, and
-- every managed path is a fixed name of the profile derived from the
-- /role/ a declaration plays in the supported shape (subject entity,
-- scope entity, authority relation, payload enum, subject\/scope
-- endpoint, subject\/scope\/payload parameter, change-other case
-- action, bounded-self-update case action) or, for the enum's values,
-- from the canonical declaration position carried by the value's
-- identity (@Value0@, @Value1@, …).  The fixed names ('targetNames')
-- are pairwise distinct and are none of Prisma's scalar type names,
-- Prisma's reserved names, Wasp's injected auth models, or
-- JavaScript\/TypeScript reserved words — pinned by the test suite
-- against closed lists.  Consequently the closed path inventory
-- ('managedPaths') never depends on authored names or on the profile,
-- a supported document renders whatever its declarations are called,
-- and renaming a declaration or an action changes only metadata.
--
-- Authored names and identities survive as display metadata only:
-- inside line comments (through 'quotedName', which escapes every
-- control character, so no name can end a comment line) and inside
-- JSON\/JavaScript string literals (through 'jsStringLiteral').  The
-- manifest states the complete authored-to-target mapping explicitly.
--
-- == The profile dispatcher
--
-- Two profiles exist, and the dispatcher ('selectWaspProfile')
-- selects one from the /ordered rule tags/ of the shared plan's case
-- collection alone — it never inspects or reclassifies the normalized
-- model, and it never re-derives a rule:
--
-- * @[rule 1]@ — exactly one change-other case — selects Profile v0
--   ('WaspProfileV0Plan');
-- * @[rule 1, rule 2]@ — exactly two cases, the change-other case at
--   position 0 and the bounded-self-update case at position 1, in
--   authored order — selects Profile v1 ('WaspProfileV1Plan');
-- * every other sequence — a singleton rule-2 case, two rule-1 cases,
--   the reversed pair, two rule-2 cases, three or more cases — is
--   refused as unsupported to every profile, with deterministic
--   reasons anchored at the offending case (a pair whose tag at some
--   position is not the one Profile v1 requires there; a singleton
--   rule-2 case) or at the guarantee (any other case count), before
--   anything is lowered and therefore before the CLI touches any
--   destination.
--
-- The selected profile is an explicit identity ('WaspProfile') carried
-- by the plan, the bundle, its summary, its ownership marker, and its
-- manifest; no later stage infers it from an operation count.
--
-- == Determinism
--
-- The bundle depends only on the plan — never on file paths, time,
-- or environment — every file uses Unix line endings, no tabs, and
-- exactly one final newline.  The same normalized document always
-- renders to the same bytes, and the golden fixture of each profile
-- is pinned byte-for-byte against a fresh bundle.
--
-- == Provenance
--
-- Rendering is pure lowering of a /supported/ shape: constructing the
-- plan attests that the shared support gate accepted the normalized
-- document, nothing more.  No rendered byte claims that the document
-- was verified; whether the production verifier reported VERIFIED
-- before generation is stated only by the generating command's
-- report ("Mithril.Command.Wasp", which requires it).
--
-- == Scope
--
-- Arbitrary multi-case lowering is not implemented: Profile v1 lowers
-- exactly the ordered rule-1, rule-2 pair and nothing wider.  The
-- templates below and this lowering are trusted components; see
-- @docs\/current-scope.md@ for the supported slice, result meanings,
-- trusted components, and explicit non-claims.
module Mithril.Core.Internal.Wasp
  ( -- * The bundle
    WaspBundle
  , bundleProfile
  , bundleFiles
  , bundleSummary
  , WaspManagedFile (..)
  , WaspBundleSummary
      ( ..
      , WaspBundleSummary
      , summaryModelName
      , summaryGuarantee
      , summaryCaseAction
      , summaryOperation
      , summaryRoute
      , summaryManagedPaths
      )
  , WaspOperationSummary (..)

    -- * The profiles and the dispatcher
  , WaspProfile (..)
  , profileNameOf
  , profileLabel
  , manifestFormatVersion
  , WaspProfilePlan (..)
  , WaspProfileV0Plan (..)
  , WaspProfileV1Plan (..)
  , selectWaspProfile
  , profilePlanProfile
  , profileOperations

    -- * Rendering
  , WaspRenderingRefusal (..)
  , renderBundleFromModel
  , renderBundleFromPlan

    -- * The fixed constants, target names, and managed paths
  , waspVersion
  , prismaVersion
  , databaseProvider
  , WaspTargetNames (..)
  , targetNames
  , memberTargetName
  , managedPaths
  , ownershipMarkerPath
  , ownershipMarkerBytesOf
  , recognizedOwnershipMarkers
  , manifestPath
  , specPath
  , schemaPath
  , packagePath
  , clientPagePath
  , operationPath

    -- * Rendering helpers
  , camelToKebabCase
  , jsStringLiteral
  ) where

import Data.ByteString (ByteString)
import Data.Char (isUpper, ord, toLower)
import Data.List (sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Numeric (showHex)

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.NspeSupportPlan
  ( BoundedSelfUpdateFacts (..)
  , ChangeOtherFacts (..)
  , NspeCaseMatch (..)
  , NspeCasePlan (..)
  , NspeRule (..)
  , NspeSupportPlan (..)
  , PlanBinding (..)
  , PlanEnumMember (..)
  , PlanRankedMember (..)
  , PlanRefusal (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation
  , caseRule
  , normalizeUnsupportedReasons
  , nspeRuleLabel
  , quotedName
  , supportPlan
  )
import Mithril.Core.Internal.Resolved
  ( ActionId (..)
  , EndpointId (..)
  , EntityId (..)
  , EnumId (..)
  , EnumValueId (..)
  , ParameterId (..)
  , RelationId (..)
  )
import Mithril.Core.Internal.SourcePath (Sourced (..), sourcePathSegments)
import Mithril.Core.Internal.Syntax (AbsenceLevel (..))

--------------------------------------------------------------------
-- The bundle
--------------------------------------------------------------------

-- | One managed file of the bundle: its path relative to the Wasp
-- source root (forward slashes, no leading separator) and its exact
-- bytes.
data WaspManagedFile = WaspManagedFile
  { managedPath :: FilePath
  , managedBytes :: ByteString
  }
  deriving (Eq, Show)

-- | A deterministic closed Wasp bundle: the explicit profile it
-- instantiates, its report-facing summary, and its managed files,
-- sorted by path and pairwise distinct.  The constructor never leaves
-- this module; a bundle exists only as the result of
-- 'renderBundleFromPlan'.
data WaspBundle = WaspBundle
  { bundleProfile :: WaspProfile
  , bundleSummary :: WaspBundleSummary
  , bundleFiles :: [WaspManagedFile]
  }
  deriving (Eq, Show)

-- | The report-facing summary of a bundle: no bytes, no paths other
-- than the managed inventory.  The model name is the authored name
-- (metadata); the profile is the explicit selected identity; the
-- operations are the complete ordered operation list — one per
-- lowered case, in authored case order — each naming its case
-- position, rule, authored action, fixed operation, and fixed route.
--
-- The one constructor, 'WaspProfileSummary', is the complete trusted
-- representation: the renderer builds every summary through it, and
-- matching on it — or reading 'summaryProfile' and
-- 'summaryOperations' — never hides an operation.  The record form
-- @WaspBundleSummary { summaryModelName, summaryGuarantee,
-- summaryCaseAction, summaryOperation, summaryRoute,
-- summaryManagedPaths }@ is the bidirectional pattern synonym
-- 'WaspBundleSummary': a /first-operation compatibility view/ that
-- neither erases nor infers away the profile and the operation list
-- of a rendered summary.
data WaspBundleSummary = WaspProfileSummary
  { profileSummaryModelName :: Text
  , profileSummaryGuarantee :: Text
  , summaryProfile :: WaspProfile
  , summaryOperations :: NonEmpty WaspOperationSummary
  , profileSummaryManagedPaths :: [FilePath]
  }
  deriving (Eq, Show)

-- | The first-operation compatibility view of a summary: a record
-- surface total over every summary.
--
-- Matching (positionally, by record syntax, or through the selectors
-- 'summaryModelName', 'summaryGuarantee', 'summaryCaseAction',
-- 'summaryOperation', 'summaryRoute', and 'summaryManagedPaths')
-- reads the model name, the guarantee, and the managed paths of the
-- summary and, from operation 0, the authored case action, the fixed
-- operation identifier, and the fixed route: for Profile v0 the one
-- operation; for Profile v1 the rule-1 operation, while
-- 'summaryOperations' remains the authoritative complete list and
-- the CLI reports every operation.  Constructing
-- (positionally, by record syntax, or by record update through these
-- fields) builds the Profile-v0 singleton summary whose one rule-1
-- operation, at case position 0, carries the given case action,
-- operation, and route — never a Profile-v1 summary.
pattern WaspBundleSummary
  :: Text -> Text -> Text -> Text -> Text -> [FilePath] -> WaspBundleSummary
pattern WaspBundleSummary
  { summaryModelName
  , summaryGuarantee
  , summaryCaseAction
  , summaryOperation
  , summaryRoute
  , summaryManagedPaths
  } <-
  ( firstOperationView ->
      (summaryModelName, summaryGuarantee, summaryCaseAction, summaryOperation, summaryRoute, summaryManagedPaths)
  )
  where
    WaspBundleSummary modelName guarantee caseAction operation route paths =
      WaspProfileSummary
        { profileSummaryModelName = modelName
        , profileSummaryGuarantee = guarantee
        , summaryProfile = WaspProfileV0
        , summaryOperations =
            WaspOperationSummary
              { operationCasePosition = 0
              , operationRule = ChangeOtherRule
              , operationCaseAction = caseAction
              , operationName = operation
              , operationRoute = route
              }
              :| []
        , profileSummaryManagedPaths = paths
        }

{-# COMPLETE WaspBundleSummary #-}

-- | The projection behind the compatibility view: the shared fields
-- and operation 0 of the complete ordered operation list.
firstOperationView :: WaspBundleSummary -> (Text, Text, Text, Text, Text, [FilePath])
firstOperationView summary =
  ( profileSummaryModelName summary
  , profileSummaryGuarantee summary
  , operationCaseAction first
  , operationName first
  , operationRoute first
  , profileSummaryManagedPaths summary
  )
  where
    first = NonEmpty.head (summaryOperations summary)

-- | One lowered operation of a bundle, as the report states it.
data WaspOperationSummary = WaspOperationSummary
  { operationCasePosition :: Int
    -- ^ The zero-based authored position of the lowered case.
  , operationRule :: NspeRule
    -- ^ The rule the case matched (read from the plan's tag).
  , operationCaseAction :: Text
    -- ^ The authored name of the case action (metadata).
  , operationName :: Text
    -- ^ The fixed Wasp operation identifier.
  , operationRoute :: Text
    -- ^ The fixed HTTP route Wasp mounts the Action at.
  }
  deriving (Eq, Show)

-- | Why no bundle was rendered: the document is outside the shared
-- support rule or outside every profile's capability (authored
-- shapes, sorted and deduplicated reasons), or the normalized model
-- is internally inconsistent (forged or drifted — a tool error,
-- decided by the shared gate before anything is lowered).  The
-- lowering itself refuses nothing: every selected profile plan
-- renders.
data WaspRenderingRefusal
  = RenderUnsupported (NonEmpty UnsupportedReason)
  | RenderInvariant (NonEmpty VerifierInvariantViolation)
  deriving (Eq, Show)

--------------------------------------------------------------------
-- The profiles and the dispatcher
--------------------------------------------------------------------

-- | The explicit identity of a profile.  Carried by the selected plan,
-- the bundle, its summary, its ownership marker, and its manifest;
-- never inferred from an operation count.
data WaspProfile
  = -- | Exactly one rule-1 (change-other) case: one Action.
    WaspProfileV0
  | -- | Exactly the ordered rule-1, rule-2 case pair: two Actions.
    WaspProfileV1
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The name of a profile (the manifest's @profile@ field and the
-- ownership marker's last line).
profileNameOf :: WaspProfile -> Text
profileNameOf profile =
  case profile of
    WaspProfileV0 -> "wasp-confinement-profile-v0"
    WaspProfileV1 -> "wasp-confinement-profile-v1"

-- | The human-readable label of a profile, shared by the generated
-- comments, the confinement diagnostics, and the CLI reports.
profileLabel :: WaspProfile -> Text
profileLabel profile =
  case profile of
    WaspProfileV0 -> "Wasp Confinement Profile v0"
    WaspProfileV1 -> "Wasp Confinement Profile v1"

-- | The manifest format version a profile writes.
manifestFormatVersion :: WaspProfile -> Text
manifestFormatVersion profile =
  case profile of
    WaspProfileV0 -> "0"
    WaspProfileV1 -> "1"

-- | The one plan shape Profile v0 lowers: the shared plan (whose case
-- collection the dispatcher proved to be exactly one change-other
-- case), that case, and its rule-1 facts.  Only the dispatcher
-- constructs it; the renderer is total over it.
data WaspProfileV0Plan = WaspProfileV0Plan
  { profileShared :: NspeSupportPlan
  , profileCase :: NspeCasePlan
  , profileFacts :: ChangeOtherFacts
  }
  deriving (Eq)

-- | The one plan shape Profile v1 lowers: the shared plan (whose case
-- collection the dispatcher proved to be exactly the ordered rule-1,
-- rule-2 pair), the change-other case at position 0 with its rule-1
-- facts, and the bounded-self-update case at position 1 with its
-- rule-2 facts.  Only the dispatcher constructs it; the renderer is
-- total over it.
data WaspProfileV1Plan = WaspProfileV1Plan
  { v1Shared :: NspeSupportPlan
  , v1ChangeOtherCase :: NspeCasePlan
  , v1ChangeOtherFacts :: ChangeOtherFacts
  , v1SelfUpdateCase :: NspeCasePlan
  , v1SelfUpdateFacts :: BoundedSelfUpdateFacts
  }
  deriving (Eq)

-- | The plan of the selected profile.
data WaspProfilePlan
  = ProfileV0Plan WaspProfileV0Plan
  | ProfileV1Plan WaspProfileV1Plan
  deriving (Eq)

-- | The explicit profile identity of a selected plan.
profilePlanProfile :: WaspProfilePlan -> WaspProfile
profilePlanProfile plan =
  case plan of
    ProfileV0Plan _ -> WaspProfileV0
    ProfileV1Plan _ -> WaspProfileV1

-- | The profile dispatcher (module header): the ordered rule tags of
-- the shared plan's case collection select the profile, and every
-- other sequence is refused with deterministic, sorted, deduplicated
-- reasons before any lowering.  The rule tags are read from the plan,
-- never re-derived, and the normalized model is never inspected.
selectWaspProfile
  :: NspeSupportPlan -> Either (NonEmpty UnsupportedReason) WaspProfilePlan
selectWaspProfile plan =
  case NonEmpty.toList (planCases plan) of
    [onlyCase] ->
      case caseMatch onlyCase of
        ChangeOtherMatch facts ->
          Right
            ( ProfileV0Plan
                WaspProfileV0Plan
                  { profileShared = plan
                  , profileCase = onlyCase
                  , profileFacts = facts
                  }
            )
        BoundedSelfUpdateMatch _ ->
          refuse
            [ UnsupportedReason
                (sourcePathSegments (casePath onlyCase))
                ( profileCapability
                    <> "; this guarantee selects one case, which matches "
                    <> nspeRuleLabel (caseRule onlyCase)
                )
            ]
    [firstCase, secondCase] ->
      case (caseMatch firstCase, caseMatch secondCase) of
        (ChangeOtherMatch changeOtherFacts, BoundedSelfUpdateMatch selfUpdateFacts) ->
          Right
            ( ProfileV1Plan
                WaspProfileV1Plan
                  { v1Shared = plan
                  , v1ChangeOtherCase = firstCase
                  , v1ChangeOtherFacts = changeOtherFacts
                  , v1SelfUpdateCase = secondCase
                  , v1SelfUpdateFacts = selfUpdateFacts
                  }
            )
        _ ->
          refuse
            [ pairMismatch position expected actual
            | (position, expected, actual) <-
                [ (0 :: Int, ChangeOtherRule, firstCase)
                , (1, BoundedSelfUpdateRule, secondCase)
                ]
            , caseRule actual /= expected
            ]
    cases ->
      refuse
        [ UnsupportedReason
            (sourcePathSegments (planGuaranteePath plan))
            ( profileCapability
                <> "; this guarantee selects "
                <> countText (length cases)
                <> " cases"
            )
        ]
  where
    refuse reasons =
      case NonEmpty.nonEmpty (normalizeUnsupportedReasons reasons) of
        Just someReasons -> Left someReasons
        -- Unreachable: every refusing branch above lists at least one
        -- reason (a pair is refused only when a position mismatches).
        Nothing ->
          Left
            ( UnsupportedReason
                (sourcePathSegments (planGuaranteePath plan))
                (profileCapability <> "; this guarantee's case sequence selects no profile")
                :| []
            )
    pairMismatch position expected actual =
      UnsupportedReason
        (sourcePathSegments (casePath actual))
        ( profileCapability
            <> "; case "
            <> countText position
            <> " matches "
            <> nspeRuleLabel (caseRule actual)
            <> ", but Profile v1 requires "
            <> nspeRuleLabel expected
            <> " at position "
            <> countText position
        )

-- | The one statement of what the profiles lower, shared by every
-- dispatcher diagnostic.
profileCapability :: Text
profileCapability =
  "Wasp Profile v0 lowers exactly one Rule-1 case and Wasp Profile v1 exactly the ordered Rule-1, Rule-2 case pair"

-- | The complete ordered operation list of a selected plan: one
-- operation per lowered case, in authored case order.
profileOperations :: WaspProfilePlan -> NonEmpty WaspOperationSummary
profileOperations plan =
  case plan of
    ProfileV0Plan v0 ->
      changeOtherOperation (profileCase v0) :| []
    ProfileV1Plan v1 ->
      changeOtherOperation (v1ChangeOtherCase v1)
        :| [selfUpdateOperation (v1SelfUpdateCase v1)]
  where
    changeOtherOperation casePlan =
      WaspOperationSummary
        { operationCasePosition = casePosition casePlan
        , operationRule = ChangeOtherRule
        , operationCaseAction = sourcedValue (caseActionName casePlan)
        , operationName = targetOperation targetNames
        , operationRoute = targetRoute targetNames
        }
    selfUpdateOperation casePlan =
      WaspOperationSummary
        { operationCasePosition = casePosition casePlan
        , operationRule = BoundedSelfUpdateRule
        , operationCaseAction = sourcedValue (caseActionName casePlan)
        , operationName = targetSelfUpdateOperation targetNames
        , operationRoute = targetSelfUpdateRoute targetNames
        }

-- | Render the bundle of a normalized model: the shared support gate,
-- then the profile dispatcher, then the files.
renderBundleFromModel
  :: Normalized.Model -> Either WaspRenderingRefusal WaspBundle
renderBundleFromModel model =
  case supportPlan model of
    Left (PlanInvariant violations) -> Left (RenderInvariant violations)
    Left (PlanUnsupported reasons) -> Left (RenderUnsupported reasons)
    Right plan ->
      case selectWaspProfile plan of
        Left reasons -> Left (RenderUnsupported reasons)
        Right profile -> Right (renderBundleFromPlan profile)

-- | Render the bundle of a selected profile plan: total, because
-- every target name is fixed and every authored name is rendered as
-- escaped metadata only.
renderBundleFromPlan :: WaspProfilePlan -> WaspBundle
renderBundleFromPlan plan =
  WaspBundle
    { bundleProfile = profilePlanProfile plan
    , bundleSummary =
        WaspProfileSummary
          { profileSummaryModelName = sourcedValue (planModelName (sharedOf plan))
          , profileSummaryGuarantee = "NoSelfPrivilegeEscalation"
          , summaryProfile = profilePlanProfile plan
          , summaryOperations = profileOperations plan
          , profileSummaryManagedPaths = managedPaths
          }
    , bundleFiles =
        sortOn managedPath $
          case plan of
            ProfileV0Plan v0 -> renderFilesV0 v0
            ProfileV1Plan v1 -> renderFilesV1 v1
    }
  where
    sharedOf selected =
      case selected of
        ProfileV0Plan v0 -> profileShared v0
        ProfileV1Plan v1 -> v1Shared v1

--------------------------------------------------------------------
-- The fixed profile constants
--------------------------------------------------------------------

-- | The exact Wasp version the bundle pins.
waspVersion :: Text
waspVersion = "0.25.0"

-- | The Prisma version Wasp 0.25.0 requires in the application's
-- dependency configuration (the Prisma runtime itself is supplied by
-- Wasp; the bundle adds no database client).
prismaVersion :: Text
prismaVersion = "5.19.1"

-- | The only database provider of the profiles.
databaseProvider :: Text
databaseProvider = "postgresql"

-- | The fixed target names of the profiles (module header): one name
-- per role of the supported shapes, never an authored name.
data WaspTargetNames = WaspTargetNames
  { targetSubjectModel :: Text
    -- ^ The Prisma model of the subject entity (Wasp's auth user entity).
  , targetScopeModel :: Text
    -- ^ The Prisma model of the scope entity.
  , targetAuthorityModel :: Text
    -- ^ The Prisma model of the authority relation.
  , targetAuthorityAccessor :: Text
    -- ^ The Prisma client accessor of the authority model.
  , targetPayloadEnum :: Text
    -- ^ The Prisma enum of the authority payload.
  , targetSubjectIdField :: Text
    -- ^ The authority model's scalar field for the subject endpoint.
  , targetScopeIdField :: Text
    -- ^ The authority model's scalar field for the scope endpoint.
  , targetPayloadField :: Text
    -- ^ The authority model's payload column.
  , targetSubjectField :: Text
    -- ^ The authority model's relation field to the subject model.
  , targetScopeField :: Text
    -- ^ The authority model's relation field to the scope model.
  , targetBackField :: Text
    -- ^ The back-relation field on the subject and scope models.
  , targetCompoundKey :: Text
    -- ^ The Prisma client's name of the composite identity.
  , targetOperation :: Text
    -- ^ The rule-1 (change-other) Wasp operation identifier (its
    -- export and its file's base name).
  , targetOperationType :: Text
    -- ^ The Wasp-generated server operation type name of the rule-1
    -- Action.
  , targetRoute :: Text
    -- ^ The HTTP route Wasp mounts the rule-1 Action at.
  , targetSelfUpdateOperation :: Text
    -- ^ The rule-2 (bounded-self-update) Wasp operation identifier
    -- (its export inside the one generated operation file; Profile
    -- v1 only).
  , targetSelfUpdateOperationType :: Text
    -- ^ The Wasp-generated server operation type name of the rule-2
    -- Action.
  , targetSelfUpdateRoute :: Text
    -- ^ The HTTP route Wasp mounts the rule-2 Action at.
  , targetSubjectArgument :: Text
    -- ^ The rule-1 Action's argument carrying the subject parameter.
  , targetScopeArgument :: Text
    -- ^ The Actions' argument carrying the scope parameter.
  , targetPayloadArgument :: Text
    -- ^ The Actions' argument carrying the payload parameter.
  , targetAppName :: Text
    -- ^ The Wasp application name.
  }
  deriving (Eq, Show)

-- | The one instance of the fixed target names.
targetNames :: WaspTargetNames
targetNames =
  WaspTargetNames
    { targetSubjectModel = "MithrilSubject"
    , targetScopeModel = "MithrilScope"
    , targetAuthorityModel = "MithrilAuthority"
    , targetAuthorityAccessor = "mithrilAuthority"
    , targetPayloadEnum = "MithrilPayload"
    , targetSubjectIdField = "subjectId"
    , targetScopeIdField = "scopeId"
    , targetPayloadField = "payload"
    , targetSubjectField = "subject"
    , targetScopeField = "scope"
    , targetBackField = "authorities"
    , targetCompoundKey = "subjectId_scopeId"
    , targetOperation = operation
    , targetOperationType = "MithrilCaseAction"
    , targetRoute = "/operations/" <> camelToKebabCase operation
    , targetSelfUpdateOperation = selfUpdateOperation
    , targetSelfUpdateOperationType = "MithrilSelfUpdateAction"
    , targetSelfUpdateRoute = "/operations/" <> camelToKebabCase selfUpdateOperation
    , targetSubjectArgument = "subject"
    , targetScopeArgument = "scope"
    , targetPayloadArgument = "payload"
    , targetAppName = "mithrilWaspApp"
    }
  where
    operation = "mithrilCaseAction"
    selfUpdateOperation = "mithrilSelfUpdateAction"

-- | The fixed target name of an authority enum value: @Value@ followed
-- by the canonical declaration position its identity carries.
memberTargetName :: EnumValueId -> Text
memberTargetName (EnumValueId _ position) = "Value" <> countText position

manifestPath, specPath, schemaPath, packagePath, clientPagePath, operationPath :: FilePath
manifestPath = "mithril.manifest.json"
specPath = "main.wasp.ts"
schemaPath = "schema.prisma"
packagePath = "package.json"
clientPagePath = "src/MainPage.tsx"
operationPath = "src/" <> Text.unpack (targetOperation targetNames) <> ".ts"

-- | The Mithril ownership marker: a managed file with fixed bytes that
-- never depend on the document — only on the profile — so an owned
-- root stays recognizable whatever else in it was altered or removed.
ownershipMarkerPath :: FilePath
ownershipMarkerPath = ".mithril-wasp-profile"

-- | The exact bytes of a profile's ownership marker.  The two markers
-- are distinct byte sequences; replacement ownership recognizes
-- exactly these two literal markers and nothing else ('recognizedOwnershipMarkers').
ownershipMarkerBytesOf :: WaspProfile -> ByteString
ownershipMarkerBytesOf profile =
  Encoding.encodeUtf8
    ( Text.unlines
        [ "# Mithril ownership marker of a " <> profileLabel profile <> " root.  DO NOT EDIT."
        , "# mithril wasp generate replaces a nonempty root as a whole only when this file"
        , "# is byte-exact and every entry of the root is a managed path of the profile's"
        , "# fixed inventory; an unmarked nonempty root is never replaced."
        , "mithril-wasp-bundle " <> profileNameOf profile
        ]
    )

-- | The literal ownership markers replacement ownership recognizes:
-- exactly the Profile-v0 marker and the Profile-v1 marker, so an
-- owned root of either profile can be replaced as a whole by a
-- regeneration of either profile (a v0 → v1 or v1 → v0 transition).
-- No marker is parsed, and no future profile is promised.
recognizedOwnershipMarkers :: [(WaspProfile, ByteString)]
recognizedOwnershipMarkers =
  [(profile, ownershipMarkerBytesOf profile) | profile <- [minBound .. maxBound]]

-- | The closed path inventory of every bundle, sorted: fixed,
-- independent of every authored name, and the same for both
-- profiles (Profile v1 adds its second Action export to the one
-- generated operation file, never a fifteenth path).
managedPaths :: [FilePath]
managedPaths =
  sort
    [ ".gitignore"
    , ".npmrc"
    , ".wasproot"
    , ownershipMarkerPath
    , manifestPath
    , specPath
    , schemaPath
    , packagePath
    , "tsconfig.json"
    , "tsconfig.src.json"
    , "tsconfig.wasp.json"
    , "vite.config.ts"
    , clientPagePath
    , operationPath
    ]

--------------------------------------------------------------------
-- Rendering helpers
--------------------------------------------------------------------

-- | Wasp's operation-route lowering of a camel-case identifier: every
-- character lower-cased, with a hyphen inserted before each upper-case
-- letter that follows a non-upper-case character.
camelToKebabCase :: Text -> Text
camelToKebabCase name =
  case Text.unpack name of
    [] -> ""
    first : rest ->
      Text.pack (toLower first : concat (zipWith hump (first : rest) rest))
  where
    hump previous current
      | not (isUpper previous) && isUpper current = ['-', toLower current]
      | otherwise = [toLower current]

-- | A JavaScript (and JSON) string literal of the text: quotes,
-- backslashes, control characters, and the line terminators U+2028
-- and U+2029 are escaped, so no authored text can end the literal or
-- add a physical line.
jsStringLiteral :: Text -> Text
jsStringLiteral text = "\"" <> Text.concatMap escape text <> "\""
  where
    escape c =
      case c of
        '"' -> "\\\""
        '\\' -> "\\\\"
        '\n' -> "\\n"
        '\r' -> "\\r"
        '\t' -> "\\t"
        '\x2028' -> "\\u2028"
        '\x2029' -> "\\u2029"
        _
          | ord c < 0x20 || ord c == 0x7f -> "\\u" <> hex4 (ord c)
          | otherwise -> Text.singleton c
    hex4 code =
      let digits = showHex code ""
       in Text.pack (replicate (4 - length digits) '0' <> digits)

countText :: Int -> Text
countText = Text.pack . show

relationIndex :: RelationId -> Int
relationIndex (RelationId index) = index

enumIndex :: EnumId -> Int
enumIndex (EnumId index) = index

entityIndex :: EntityId -> Int
entityIndex (EntityId index) = index

actionIndex :: ActionId -> Int
actionIndex (ActionId index) = index

endpointIndex :: EndpointId -> Int
endpointIndex (EndpointId _ position) = position

parameterIndex :: ParameterId -> Int
parameterIndex (ParameterId _ position) = position

valueIndex :: EnumValueId -> Int
valueIndex (EnumValueId _ position) = position

absenceText :: AbsenceLevel -> Text
absenceText AbsenceBottom = "Bottom"

-- | An authored name as escaped comment text.
named :: Sourced Text -> Text
named = quotedName . sourcedValue

--------------------------------------------------------------------
-- The consumed evidence
--------------------------------------------------------------------

-- | The shared consumed normalized evidence, rendered as the Agda
-- generator's evidence block renders it (names through 'quotedName',
-- identities as declaration positions), so a reviewer can read the
-- same facts off both derived artifacts.
sharedEvidenceLines :: NspeSupportPlan -> [Text]
sharedEvidenceLines shared =
  [ "model: " <> named (planModelName shared)
  , "guarantee: NoSelfPrivilegeEscalation"
  , "authority relation: "
      <> named (planRelationName shared)
      <> " (relation "
      <> countText (relationIndex (planRelationId shared))
      <> ")"
  , "authority subject endpoint: "
      <> endpointEvidence
        (planSubjectEndpointName shared)
        (planSubjectEndpointId shared)
        (planSubjectEntityName shared)
        (planSubjectEntityId shared)
  , "authority scope endpoint: "
      <> endpointEvidence
        (planScopeEndpointName shared)
        (planScopeEndpointId shared)
        (planScopeEntityName shared)
        (planScopeEntityId shared)
  , "authority absence level: " <> absenceText (planAbsenceLevel shared)
  , "authority payload order: enum "
      <> named (planEnumName shared)
      <> " (enum "
      <> countText (enumIndex (planEnumId shared))
      <> ")"
  , "declared enum members: "
      <> Text.intercalate
        ", "
        [ valueEvidence shared (sourcedValue (planMemberName member)) (planMemberId member)
        | member <- planEnumMembers shared
        ]
  , "materialized authority ranking: "
      <> Text.intercalate
        ", "
        [ "rank " <> countText (planRankedRank ranked) <> " = "
            <> valueEvidence shared (planRankedName ranked) (planRankedId ranked)
        | ranked <- planRanking shared
        ]
  , "materialized bottom: " <> rankedEvidence shared (planRankBottom shared)
  , "privilege floor: " <> rankedEvidence shared (planRankTop shared)
  , "absent rank: " <> countText (planAbsentRank shared)
  ]
  where
    endpointEvidence endpointName endpointId entityName entityId =
      named endpointName
        <> " (endpoint "
        <> countText (endpointIndex endpointId)
        <> " of relation "
        <> countText (relationIndex (planRelationId shared))
        <> "), entity "
        <> named entityName
        <> " (entity "
        <> countText (entityIndex entityId)
        <> ")"

valueEvidence :: NspeSupportPlan -> Text -> EnumValueId -> Text
valueEvidence shared valueName valueId =
  quotedName valueName
    <> " (value "
    <> countText (valueIndex valueId)
    <> " of enum "
    <> countText (enumIndex (planEnumId shared))
    <> ")"

rankedEvidence :: NspeSupportPlan -> PlanRankedMember -> Text
rankedEvidence shared ranked =
  "rank " <> countText (planRankedRank ranked) <> " = "
    <> valueEvidence shared (planRankedName ranked) (planRankedId ranked)

bindingEvidence :: PlanBinding -> Text
bindingEvidence binding =
  "endpoint "
    <> quotedName (planBindingEndpointName binding)
    <> " (endpoint "
    <> countText (endpointIndex (planBindingEndpointId binding))
    <> ") = Argument "
    <> quotedName (planBindingParameterName binding)
    <> " (parameter "
    <> countText (parameterIndex (planBindingParameterId binding))
    <> ")"

-- | The per-case evidence of a rule-1 (change-other) case: the case
-- action, the verified case scope binding, the principal mode, the
-- three parameters, the exact allow conjunction, the effect, and the
-- result.
changeOtherCaseEvidence :: NspeSupportPlan -> NspeCasePlan -> ChangeOtherFacts -> [Text]
changeOtherCaseEvidence shared casePlan facts =
  [ "case action: "
      <> named (caseActionName casePlan)
      <> " (action "
      <> countText (actionIndex (caseActionId casePlan))
      <> ")"
  , "case scope binding: " <> bindingEvidence (caseScopeBinding casePlan)
  , "principal mode: AuthenticatedOnly"
  , "parameter "
      <> countText (parameterIndex (changeOtherSubjectParameterId facts))
      <> ": "
      <> named (changeOtherSubjectParameterName facts)
      <> " : EntityRef "
      <> named (planSubjectEntityName shared)
  , "parameter "
      <> countText (parameterIndex (caseScopeParameterId casePlan))
      <> ": "
      <> named (caseScopeParameterName casePlan)
      <> " : EntityRef "
      <> named (planScopeEntityName shared)
  , "parameter "
      <> countText (parameterIndex (casePayloadParameterId casePlan))
      <> ": "
      <> named (casePayloadParameterName casePlan)
      <> " : Enum "
      <> named (planEnumName shared)
  , "allow policy: And(LessOrEqual[order optional "
      <> named (planEnumName shared)
      <> ", absence as bottom](Some(Enum["
      <> named (planEnumName shared)
      <> "."
      <> quotedName (planRankedName (planRankTop shared))
      <> "]), Lookup["
      <> named (planRelationName shared)
      <> "]("
      <> named (planSubjectEndpointName shared)
      <> " = Actor, "
      <> named (planScopeEndpointName shared)
      <> " = Argument["
      <> named (caseScopeParameterName casePlan)
      <> "])), And(Not(Equal(Actor, Argument["
      <> named (changeOtherSubjectParameterName facts)
      <> "])), IsSome(Lookup["
      <> named (planRelationName shared)
      <> "]("
      <> named (planSubjectEndpointName shared)
      <> " = Argument["
      <> named (changeOtherSubjectParameterName facts)
      <> "], "
      <> named (planScopeEndpointName shared)
      <> " = Argument["
      <> named (caseScopeParameterName casePlan)
      <> "]))))"
  , "effect: SetRelation["
      <> named (planRelationName shared)
      <> "]("
      <> Text.intercalate ", " (map bindingEvidence (changeOtherEffectBindings facts))
      <> ") payload Argument["
      <> named (casePayloadParameterName casePlan)
      <> "]"
  , "result: Done"
  ]

-- | The per-case evidence of a rule-2 (bounded-self-update) case: the
-- case action, the verified case scope binding, the principal mode,
-- the two parameters, the exact allow comparison, the effect at the
-- actor's own tuple, and the result.
selfUpdateCaseEvidence :: NspeSupportPlan -> NspeCasePlan -> BoundedSelfUpdateFacts -> [Text]
selfUpdateCaseEvidence shared casePlan facts =
  [ "case action: "
      <> named (caseActionName casePlan)
      <> " (action "
      <> countText (actionIndex (caseActionId casePlan))
      <> ")"
  , "case scope binding: " <> bindingEvidence (caseScopeBinding casePlan)
  , "principal mode: AuthenticatedOnly"
  , "parameter "
      <> countText (parameterIndex (caseScopeParameterId casePlan))
      <> ": "
      <> named (caseScopeParameterName casePlan)
      <> " : EntityRef "
      <> named (planScopeEntityName shared)
  , "parameter "
      <> countText (parameterIndex (casePayloadParameterId casePlan))
      <> ": "
      <> named (casePayloadParameterName casePlan)
      <> " : Enum "
      <> named (planEnumName shared)
  , "allow policy: LessOrEqual[order optional "
      <> named (planEnumName shared)
      <> ", absence as bottom](Some(Argument["
      <> named (casePayloadParameterName casePlan)
      <> "]), Lookup["
      <> named (planRelationName shared)
      <> "]("
      <> named (planSubjectEndpointName shared)
      <> " = Actor, "
      <> named (planScopeEndpointName shared)
      <> " = Argument["
      <> named (caseScopeParameterName casePlan)
      <> "]))"
  , "effect: SetRelation["
      <> named (planRelationName shared)
      <> "](endpoint "
      <> named (planSubjectEndpointName shared)
      <> " (endpoint "
      <> countText (endpointIndex (planSubjectEndpointId shared))
      <> ") = Actor, "
      <> bindingEvidence (selfUpdateEffectScopeBinding facts)
      <> ") payload Argument["
      <> named (casePayloadParameterName casePlan)
      <> "]"
  , "result: Done"
  ]

-- | The complete evidence block of a Profile-v0 plan.
evidenceLinesV0 :: WaspProfileV0Plan -> [Text]
evidenceLinesV0 plan =
  sharedEvidenceLines (profileShared plan)
    <> changeOtherCaseEvidence (profileShared plan) (profileCase plan) (profileFacts plan)

-- | The complete evidence block of a Profile-v1 plan: the shared
-- facts, the case count, and both cases in authored order, each
-- introduced by its position and rule — as the generated Agda module
-- lays them out.
evidenceLinesV1 :: WaspProfileV1Plan -> [Text]
evidenceLinesV1 plan =
  sharedEvidenceLines shared
    <> ["selected cases: 2"]
    <> [caseHeading (v1ChangeOtherCase plan)]
    <> changeOtherCaseEvidence shared (v1ChangeOtherCase plan) (v1ChangeOtherFacts plan)
    <> [caseHeading (v1SelfUpdateCase plan)]
    <> selfUpdateCaseEvidence shared (v1SelfUpdateCase plan) (v1SelfUpdateFacts plan)
  where
    shared = v1Shared plan
    caseHeading casePlan =
      "case " <> countText (casePosition casePlan) <> ": " <> nspeRuleLabel (caseRule casePlan)

--------------------------------------------------------------------
-- The managed files
--------------------------------------------------------------------

-- | Every managed file of Profile v0, rendered from the plan.
renderFilesV0 :: WaspProfileV0Plan -> [WaspManagedFile]
renderFilesV0 plan =
  [ textFile ".gitignore" (gitignoreLines WaspProfileV0)
  , textFile ".npmrc" npmrcLines
  , textFile ".wasproot" ["File marking the root of Wasp project."]
  , WaspManagedFile ownershipMarkerPath (ownershipMarkerBytesOf WaspProfileV0)
  , textFile specPath (specLinesV0 plan)
  , textFile schemaPath (schemaLines WaspProfileV0 shared)
  , textFile packagePath packageLines
  , textFile "tsconfig.json" tsconfigLines
  , textFile "tsconfig.src.json" tsconfigSrcLines
  , textFile "tsconfig.wasp.json" tsconfigWaspLines
  , textFile "vite.config.ts" (viteConfigLines shared)
  , textFile clientPagePath (clientPageLinesV0 plan)
  , textFile operationPath (operationLinesV0 plan)
  , textFile manifestPath (manifestLinesV0 plan)
  ]
  where
    shared = profileShared plan

-- | Every managed file of Profile v1, rendered from the plan: the
-- same fourteen paths as Profile v0.
renderFilesV1 :: WaspProfileV1Plan -> [WaspManagedFile]
renderFilesV1 plan =
  [ textFile ".gitignore" (gitignoreLines WaspProfileV1)
  , textFile ".npmrc" npmrcLines
  , textFile ".wasproot" ["File marking the root of Wasp project."]
  , WaspManagedFile ownershipMarkerPath (ownershipMarkerBytesOf WaspProfileV1)
  , textFile specPath (specLinesV1 plan)
  , textFile schemaPath (schemaLines WaspProfileV1 shared)
  , textFile packagePath packageLines
  , textFile "tsconfig.json" tsconfigLines
  , textFile "tsconfig.src.json" tsconfigSrcLines
  , textFile "tsconfig.wasp.json" tsconfigWaspLines
  , textFile "vite.config.ts" (viteConfigLines shared)
  , textFile clientPagePath (clientPageLinesV1 plan)
  , textFile operationPath (operationLinesV1 plan)
  , textFile manifestPath (manifestLinesV1 plan)
  ]
  where
    shared = v1Shared plan

textFile :: FilePath -> [Text] -> WaspManagedFile
textFile path fileLines =
  WaspManagedFile
    { managedPath = path
    , managedBytes = Encoding.encodeUtf8 (Text.unlines fileLines)
    }

generatedHeader :: Text -> NspeSupportPlan -> Text
generatedHeader commentLead shared =
  commentLead
    <> " Generated by mithril wasp generate from Mithril Core v0 model "
    <> named (planModelName shared)
    <> ".  DO NOT EDIT."

-- | The provenance sentence every commented managed file carries: the
-- bytes attest lowering of a supported shape only.
provenanceLines :: Text -> [Text]
provenanceLines commentLead =
  [ commentLead <> " Lowering attests support of the shape only; the generating command's report,"
  , commentLead <> " not these bytes, states whether the document passed the proof gate."
  ]

gitignoreLines :: WaspProfile -> [Text]
gitignoreLines profile =
  [ "# Generated by mithril wasp generate.  DO NOT EDIT."
  , "# " <> profileLabel profile <> ": installation, build, migration, and"
  , "# environment outputs are never part of the confined source root."
  , ".wasp/"
  , "node_modules/"
  , "package-lock.json"
  , "migrations/"
  , ".env"
  , ".env.*"
  ]

npmrcLines :: [Text]
npmrcLines =
  [ "# Generated by mithril wasp generate.  DO NOT EDIT."
  , "min-release-age=7"
  ]

specLinesV0 :: WaspProfileV0Plan -> [Text]
specLinesV0 plan =
  [ generatedHeader "//" shared
  , "//"
  , "// Wasp Confinement Profile v0: this specification is a managed input of the"
  , "// closed generated profile; mithril wasp check rejects any byte that differs"
  , "// from the regenerated bundle.  It declares exactly one route and page (the"
  , "// minimal client shell) and exactly one authenticated Action, " <> operation <> ","
  , "// lowered from the supported NoSelfPrivilegeEscalation case action shape of the"
  , "// authored action " <> named (caseActionName (profileCase plan)) <> "."
  ]
    <> provenanceLines "//"
    <> [ "// No query, API, CRUD, job, seed, server setup, or middleware path exists."
       , "import { action, app, page, route } from \"@wasp.sh/spec\";"
       , "import { MainPage } from \"./src/MainPage\" with { type: \"ref\" };"
       , "import { " <> operation <> " } from \"./src/" <> operation <> "\" with { type: \"ref\" };"
       , ""
       , "export default app({"
       , "  name: " <> jsStringLiteral (targetAppName targetNames) <> ","
       , "  wasp: { version: " <> jsStringLiteral waspVersion <> " },"
       , "  title: " <> jsStringLiteral (sourcedValue (planModelName shared)) <> ","
       , "  auth: {"
       , "    userEntity: " <> jsStringLiteral (targetSubjectModel targetNames) <> ","
       , "    methods: { usernameAndPassword: {} },"
       , "    onAuthFailedRedirectTo: \"/\","
       , "  },"
       , "  spec: ["
       , "    route(\"RootRoute\", \"/\", page(MainPage)),"
       , "    action("
           <> operation
           <> ", { entities: ["
           <> jsStringLiteral (targetAuthorityModel targetNames)
           <> "], auth: true }),"
       , "  ],"
       , "});"
       ]
  where
    shared = profileShared plan
    operation = targetOperation targetNames

specLinesV1 :: WaspProfileV1Plan -> [Text]
specLinesV1 plan =
  [ generatedHeader "//" shared
  , "//"
  , "// Wasp Confinement Profile v1: this specification is a managed input of the"
  , "// closed generated profile; mithril wasp check rejects any byte that differs"
  , "// from the regenerated bundle.  It declares exactly one route and page (the"
  , "// minimal client shell) and exactly two authenticated Actions, both exported by"
  , "// the one generated operation file, in the authored case order:"
  , "//   " <> operation <> ", lowered from the change-other (rule-1) case action"
  , "//   " <> named (caseActionName (v1ChangeOtherCase plan)) <> " (case " <> countText (casePosition (v1ChangeOtherCase plan)) <> "), and"
  , "//   " <> selfUpdate <> ", lowered from the bounded self-update (rule-2) case action"
  , "//   " <> named (caseActionName (v1SelfUpdateCase plan)) <> " (case " <> countText (casePosition (v1SelfUpdateCase plan)) <> ")."
  ]
    <> provenanceLines "//"
    <> [ "// No query, API, CRUD, job, seed, server setup, or middleware path exists."
       , "import { action, app, page, route } from \"@wasp.sh/spec\";"
       , "import { MainPage } from \"./src/MainPage\" with { type: \"ref\" };"
       , "import { " <> operation <> ", " <> selfUpdate <> " } from \"./src/" <> operation <> "\" with { type: \"ref\" };"
       , ""
       , "export default app({"
       , "  name: " <> jsStringLiteral (targetAppName targetNames) <> ","
       , "  wasp: { version: " <> jsStringLiteral waspVersion <> " },"
       , "  title: " <> jsStringLiteral (sourcedValue (planModelName shared)) <> ","
       , "  auth: {"
       , "    userEntity: " <> jsStringLiteral (targetSubjectModel targetNames) <> ","
       , "    methods: { usernameAndPassword: {} },"
       , "    onAuthFailedRedirectTo: \"/\","
       , "  },"
       , "  spec: ["
       , "    route(\"RootRoute\", \"/\", page(MainPage)),"
       , "    action("
           <> operation
           <> ", { entities: ["
           <> jsStringLiteral (targetAuthorityModel targetNames)
           <> "], auth: true }),"
       , "    action("
           <> selfUpdate
           <> ", { entities: ["
           <> jsStringLiteral (targetAuthorityModel targetNames)
           <> "], auth: true }),"
       , "  ],"
       , "});"
       ]
  where
    shared = v1Shared plan
    operation = targetOperation targetNames
    selfUpdate = targetSelfUpdateOperation targetNames

schemaLines :: WaspProfile -> NspeSupportPlan -> [Text]
schemaLines profile shared =
  [ generatedHeader "//" shared
  , "//"
  , "// " <> profileLabel profile <> ": the PostgreSQL datasource, the subject and scope"
  , "// entities, the authority relation with its payload enum, and nothing else."
  , "// Every model, enum, value, and field name is a fixed target name of the"
  , "// profile; the authored Core names appear only in these comments and in the"
  , "// manifest.  Wasp injects its own auth models (Auth, AuthIdentity, Session)."
  , "datasource db {"
  , "  provider = " <> jsStringLiteral databaseProvider
  , "  url      = env(\"DATABASE_URL\")"
  , "}"
  , ""
  , "generator client {"
  , "  provider = \"prisma-client-js\""
  , "}"
  , ""
  , "// " <> subjectModel <> ": the subject entity " <> named (planSubjectEntityName shared)
      <> " (entity " <> countText (entityIndex (planSubjectEntityId shared)) <> ") — the"
  , "// authenticated principal and Wasp's auth user entity."
  , "model " <> subjectModel <> " {"
  , "  id          Int @id @default(autoincrement())"
  , "  authorities " <> authorityModel <> "[]"
  , "}"
  , ""
  , "// " <> scopeModel <> ": the scope entity " <> named (planScopeEntityName shared)
      <> " (entity " <> countText (entityIndex (planScopeEntityId shared)) <> ")."
  , "model " <> scopeModel <> " {"
  , "  id          Int @id @default(autoincrement())"
  , "  authorities " <> authorityModel <> "[]"
  , "}"
  , ""
  , "// " <> payloadEnum <> ": the authority payload enum " <> named (planEnumName shared)
      <> " (enum " <> countText (enumIndex (planEnumId shared)) <> "); value i"
  , "// of the enum is the value Value<i>, in declaration order:"
  , "//   " <> memberMapping <> "."
  , "// (The ranking is materialized in the generated Action, not here.)"
  , "enum " <> payloadEnum <> " {"
  ]
    <> ["  " <> memberTargetName (planMemberId member) | member <- planEnumMembers shared]
    <> [ "}"
       , ""
       , "// " <> authorityModel <> ": the authority relation " <> named (planRelationName shared)
           <> " (relation " <> countText (relationIndex (planRelationId shared)) <> "), identified"
       , "// by its endpoints — subjectId for the subject endpoint " <> named (planSubjectEndpointName shared)
           <> " (endpoint " <> countText (endpointIndex (planSubjectEndpointId shared)) <> ")"
       , "// and scopeId for the scope endpoint " <> named (planScopeEndpointName shared)
           <> " (endpoint " <> countText (endpointIndex (planScopeEndpointId shared)) <> ") — with"
       , "// the payload enum as its payload column."
       , "model " <> authorityModel <> " {"
       , "  subjectId Int"
       , "  scopeId   Int"
       , "  payload   " <> payloadEnum
       , "  subject   " <> subjectModel <> " @relation(fields: [subjectId], references: [id])"
       , "  scope     " <> scopeModel <> "   @relation(fields: [scopeId], references: [id])"
       , ""
       , "  @@id([subjectId, scopeId])"
       , "}"
       ]
  where
    subjectModel = targetSubjectModel targetNames
    scopeModel = targetScopeModel targetNames
    authorityModel = targetAuthorityModel targetNames
    payloadEnum = targetPayloadEnum targetNames
    memberMapping =
      Text.intercalate
        ", "
        [ memberTargetName (planMemberId member) <> " = " <> named (planMemberName member)
        | member <- planEnumMembers shared
        ]

packageLines :: [Text]
packageLines =
  [ "{"
  , "  \"name\": \"mithril-wasp-app\","
  , "  \"private\": true,"
  , "  \"type\": \"module\","
  , "  \"workspaces\": [\".wasp/out/*\", \".wasp/out/sdk/wasp\"],"
  , "  \"dependencies\": {"
  , "    \"react\": \"^19.2.1\","
  , "    \"react-dom\": \"^19.2.1\","
  , "    \"react-router\": \"^8.0.1\""
  , "  },"
  , "  \"devDependencies\": {"
  , "    \"@types/node\": \"^24.0.0\","
  , "    \"@types/react\": \"^19.2.7\","
  , "    \"@types/react-dom\": \"^19.2.3\","
  , "    \"@wasp.sh/spec\": \"file:.wasp/spec/\","
  , "    \"prisma\": " <> jsStringLiteral prismaVersion <> ","
  , "    \"typescript\": \"6.0.3\","
  , "    \"vite\": \"^8.1.0\","
  , "    \"vitest\": \"^4.1.9\""
  , "  }"
  , "}"
  ]

tsconfigLines :: [Text]
tsconfigLines =
  [ "{"
  , "  \"files\": [],"
  , "  \"references\": ["
  , "    { \"path\": \"./tsconfig.src.json\" },"
  , "    { \"path\": \"./tsconfig.wasp.json\" }"
  , "  ]"
  , "}"
  ]

tsconfigSrcLines :: [Text]
tsconfigSrcLines =
  [ "{"
  , "  \"compilerOptions\": {"
  , "    \"module\": \"esnext\","
  , "    \"composite\": true,"
  , "    \"target\": \"esnext\","
  , "    \"moduleResolution\": \"bundler\","
  , "    \"jsx\": \"preserve\","
  , "    \"strict\": true,"
  , "    \"esModuleInterop\": true,"
  , "    \"isolatedModules\": true,"
  , "    \"moduleDetection\": \"force\","
  , "    \"lib\": [\"dom\", \"dom.iterable\", \"esnext\"],"
  , "    \"skipLibCheck\": true,"
  , "    \"allowJs\": true,"
  , "    \"outDir\": \".wasp/out/user\","
  , "    \"types\": [\"react\", \"node\"]"
  , "  },"
  , "  \"include\": [\"src\"],"
  , "  \"exclude\": [\"**/*.wasp.ts\"]"
  , "}"
  ]

tsconfigWaspLines :: [Text]
tsconfigWaspLines =
  [ "{"
  , "  \"compilerOptions\": {"
  , "    \"skipLibCheck\": true,"
  , "    \"target\": \"ES2025\","
  , "    \"isolatedModules\": true,"
  , "    \"moduleDetection\": \"force\","
  , "    \"strict\": true,"
  , "    \"noUnusedLocals\": true,"
  , "    \"noUnusedParameters\": true,"
  , "    \"module\": \"esnext\","
  , "    \"moduleResolution\": \"bundler\","
  , "    \"jsx\": \"preserve\","
  , "    \"allowJs\": true,"
  , "    \"noEmit\": true,"
  , "    \"lib\": [\"ES2025\"],"
  , "    \"types\": [\"node\"]"
  , "  },"
  , "  \"include\": [\"**/*.wasp.ts\", \".wasp/out/types/spec\"]"
  , "}"
  ]

viteConfigLines :: NspeSupportPlan -> [Text]
viteConfigLines shared =
  [ generatedHeader "//" shared
  , "import { defineConfig } from \"vite\";"
  , "import { wasp } from \"wasp/client/vite\";"
  , ""
  , "export default defineConfig({"
  , "  plugins: [wasp()],"
  , "});"
  ]

clientPageLinesV0 :: WaspProfileV0Plan -> [Text]
clientPageLinesV0 plan =
  [ generatedHeader "//" shared
  , "// The minimal static client shell Wasp requires; the generated Action is"
  , "// exercised over Wasp's real HTTP and authentication path, not from here."
  , "export function MainPage() {"
  , "  return ("
  , "    <main>"
  , "      <h1>{" <> jsStringLiteral ("Mithril Core v0 model " <> named (planModelName shared)) <> "}</h1>"
  , "      <p>{"
      <> jsStringLiteral
        ( "Wasp Confinement Profile v0 demonstrator: one authenticated Wasp Action, "
            <> targetOperation targetNames
            <> " (POST "
            <> targetRoute targetNames
            <> "), lowered from the supported NoSelfPrivilegeEscalation case action shape of "
            <> named (caseActionName (profileCase plan))
            <> "."
        )
      <> "}</p>"
  , "    </main>"
  , "  );"
  , "}"
  ]
  where
    shared = profileShared plan

clientPageLinesV1 :: WaspProfileV1Plan -> [Text]
clientPageLinesV1 plan =
  [ generatedHeader "//" shared
  , "// The minimal static client shell Wasp requires; the generated Actions are"
  , "// exercised over Wasp's real HTTP and authentication path, not from here."
  , "export function MainPage() {"
  , "  return ("
  , "    <main>"
  , "      <h1>{" <> jsStringLiteral ("Mithril Core v0 model " <> named (planModelName shared)) <> "}</h1>"
  , "      <p>{"
      <> jsStringLiteral
        ( "Wasp Confinement Profile v1 demonstrator: two authenticated Wasp Actions in the authored case order, "
            <> targetOperation targetNames
            <> " (POST "
            <> targetRoute targetNames
            <> "), lowered from the change-other NoSelfPrivilegeEscalation case action "
            <> named (caseActionName (v1ChangeOtherCase plan))
            <> ", and "
            <> targetSelfUpdateOperation targetNames
            <> " (POST "
            <> targetSelfUpdateRoute targetNames
            <> "), lowered from the bounded self-update NoSelfPrivilegeEscalation case action "
            <> named (caseActionName (v1SelfUpdateCase plan))
            <> "."
        )
      <> "}</p>"
  , "    </main>"
  , "  );"
  , "}"
  ]
  where
    shared = v1Shared plan

--------------------------------------------------------------------
-- The generated operation file
--------------------------------------------------------------------

-- | The shared constants of the operation file: the payload type and
-- member list, the materialized ranking, the floor, the absent rank,
-- and the bounded retry — rendered identically by both profiles.
operationConstantLines :: NspeSupportPlan -> [Text]
operationConstantLines shared =
  [ "// The authority payload enum " <> payloadEnum <> " (" <> named (planEnumName shared) <> "): the values in"
  , "// declaration order,"
  , "//   " <> memberMapping <> "."
  , "type Payload = " <> Text.intercalate " | " (map jsStringLiteral memberValues) <> ";"
  , "const payloadMembers: readonly string[] = [" <> Text.intercalate ", " (map jsStringLiteral memberValues) <> "];"
  , ""
  , "// The materialized ranking (rank 0 is the bottom ranked value):"
  , "//   " <> rankingMapping <> ";"
  , "// the privilege floor is the rank of " <> rankedTarget (planRankTop shared) <> " ("
      <> quotedName (planRankedName (planRankTop shared)) <> "), and an absent authority"
  , "// tuple takes the absent rank below every member (absence level "
      <> absenceText (planAbsenceLevel shared) <> ")."
  , "const payloadRank: Readonly<Record<Payload, number>> = { "
      <> Text.intercalate
        ", "
        [ jsStringLiteral (rankedTarget ranked) <> ": " <> countText (planRankedRank ranked)
        | ranked <- planRanking shared
        ]
      <> " };"
  , "const floorRank = " <> countText (planRankedRank (planRankTop shared)) <> ";"
  , "const absentRank = " <> countText (planAbsentRank shared) <> ";"
  , ""
  , "// Bounded deterministic retry of Serializable write conflicts (Prisma P2034)."
  , "const serializationAttempts = 3;"
  ]
  where
    payloadEnum = targetPayloadEnum targetNames
    memberValues = [memberTargetName (planMemberId member) | member <- planEnumMembers shared]
    memberMapping =
      Text.intercalate
        ", "
        [ memberTargetName (planMemberId member) <> " = " <> named (planMemberName member)
        | member <- planEnumMembers shared
        ]
    rankedTarget ranked = memberTargetName (planRankedId ranked)
    rankingMapping =
      Text.intercalate
        ", "
        [ "rank " <> countText (planRankedRank ranked) <> " = " <> rankedTarget ranked
            <> " (" <> quotedName (planRankedName ranked) <> ")"
        | ranked <- planRanking shared
        ]

-- | The rule-1 (change-other) Action: its argument type and parser,
-- the shared argument validators and the conflict classifier, and the
-- Action itself — rendered identically by both profiles, so Profile
-- v1 preserves the rule-1 runtime semantics line for line.
changeOtherActionLines :: NspeSupportPlan -> NspeCasePlan -> ChangeOtherFacts -> [Text]
changeOtherActionLines shared casePlan facts =
  [ "// The action's arguments: " <> subjectArgument <> " carries " <> named (changeOtherSubjectParameterName facts)
      <> " : EntityRef " <> named (planSubjectEntityName shared) <> ","
  , "// " <> scopeArgument <> " carries " <> named (caseScopeParameterName casePlan) <> " : EntityRef "
      <> named (planScopeEntityName shared) <> ", and " <> payloadArgument <> " carries"
  , "// " <> named (casePayloadParameterName casePlan) <> " : Enum " <> named (planEnumName shared) <> "."
  , "type Args = { " <> subjectArgument <> ": number; " <> scopeArgument <> ": number; " <> payloadArgument <> ": Payload };"
  , ""
  , "function isEntityReference(value: unknown): value is number {"
  , "  return typeof value === \"number\" && Number.isSafeInteger(value) && value >= 1;"
  , "}"
  , ""
  , "function isPayload(value: unknown): value is Payload {"
  , "  return typeof value === \"string\" && payloadMembers.includes(value);"
  , "}"
  , ""
  , "function parseArgs(input: unknown): Args | null {"
  , "  if (typeof input !== \"object\" || input === null) {"
  , "    return null;"
  , "  }"
  , "  const record = input as Record<string, unknown>;"
  , "  const subjectArgument = record[" <> jsStringLiteral subjectArgument <> "];"
  , "  const scopeArgument = record[" <> jsStringLiteral scopeArgument <> "];"
  , "  const payloadArgument = record[" <> jsStringLiteral payloadArgument <> "];"
  , "  if (!isEntityReference(subjectArgument) || !isEntityReference(scopeArgument) || !isPayload(payloadArgument)) {"
  , "    return null;"
  , "  }"
  , "  return { " <> subjectArgument <> ": subjectArgument, " <> scopeArgument <> ": scopeArgument, "
      <> payloadArgument <> ": payloadArgument };"
  , "}"
  , ""
  , "function isSerializationConflict(error: unknown): boolean {"
  , "  return typeof error === \"object\" && error !== null && (error as { code?: unknown }).code === \"P2034\";"
  , "}"
  , ""
  , "export const " <> operation <> ": " <> operationType <> "<Args, void> = async (input, context) => {"
  , "  // Principal: Wasp authentication is required, and context.user.id is the only"
  , "  // identity the Action uses (the subject entity " <> subjectModel <> ", authored "
      <> named (planSubjectEntityName shared) <> ")."
  , "  if (!context.user) {"
  , "    throw new HttpError(401, \"authentication required\");"
  , "  }"
  , "  const actor: number = context.user.id;"
  , "  const args = parseArgs(input);"
  , "  if (args === null) {"
  , "    throw new HttpError(400, \"invalid arguments\");"
  , "  }"
  , "  for (let attempt = 1; ; attempt += 1) {"
  , "    try {"
  , "      await prisma.$transaction("
  , "        async (tx) => {"
  , "          // Lookup[" <> named (planRelationName shared) <> "](" <> named (planSubjectEndpointName shared)
      <> " = Actor, " <> named (planScopeEndpointName shared) <> " = Argument[" <> named (caseScopeParameterName casePlan) <> "]):"
  , "          // all mutable authorization state is read inside this Serializable transaction."
  , "          const actorTuple = await tx." <> accessor <> ".findUnique({"
  , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": actor, " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
  , "          });"
  , "          // Lookup[" <> named (planRelationName shared) <> "](" <> named (planSubjectEndpointName shared)
      <> " = Argument[" <> named (changeOtherSubjectParameterName facts) <> "], " <> named (planScopeEndpointName shared)
      <> " = Argument[" <> named (caseScopeParameterName casePlan) <> "])."
  , "          const targetTuple = await tx." <> accessor <> ".findUnique({"
  , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": args." <> subjectArgument <> ", " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
  , "          });"
  , "          const actorRank = actorTuple === null ? absentRank : payloadRank[actorTuple." <> payloadField <> "];"
  , "          // And(LessOrEqual(Some(" <> quotedName (planRankedName (planRankTop shared)) <> "), actor authority), And(Not(Equal(Actor, "
      <> named (changeOtherSubjectParameterName facts) <> ")), IsSome(target authority)))."
  , "          const allowed = floorRank <= actorRank && (!(actor === args." <> subjectArgument <> ") && targetTuple !== null);"
  , "          if (!allowed) {"
  , "            throw new HttpError(403, \"forbidden\");"
  , "          }"
  , "          // SetRelation[" <> named (planRelationName shared) <> "](" <> named (planSubjectEndpointName shared)
      <> " = Argument[" <> named (changeOtherSubjectParameterName facts) <> "], " <> named (planScopeEndpointName shared)
      <> " = Argument[" <> named (caseScopeParameterName casePlan) <> "]) payload Argument["
      <> named (casePayloadParameterName casePlan) <> "]."
  , "          await tx." <> accessor <> ".update({"
  , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": args." <> subjectArgument <> ", " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
  , "            data: { " <> payloadField <> ": args." <> payloadArgument <> " },"
  , "          });"
  , "        },"
  , "        { isolationLevel: \"Serializable\" },"
  , "      );"
  , "      return;"
  , "    } catch (error) {"
  , "      if (error instanceof HttpError) {"
  , "        throw error;"
  , "      }"
  , "      if (isSerializationConflict(error)) {"
  , "        if (attempt < serializationAttempts) {"
  , "          continue;"
  , "        }"
  , "        throw new HttpError(409, \"conflict\");"
  , "      }"
  , "      throw new HttpError(500, \"internal error\");"
  , "    }"
  , "  }"
  , "};"
  ]
  where
    operation = targetOperation targetNames
    operationType = targetOperationType targetNames
    subjectModel = targetSubjectModel targetNames
    accessor = targetAuthorityAccessor targetNames
    subjectIdField = targetSubjectIdField targetNames
    scopeIdField = targetScopeIdField targetNames
    payloadField = targetPayloadField targetNames
    compoundKey = targetCompoundKey targetNames
    subjectArgument = targetSubjectArgument targetNames
    scopeArgument = targetScopeArgument targetNames
    payloadArgument = targetPayloadArgument targetNames

-- | The rule-2 (bounded-self-update) Action of Profile v1: its own
-- argument type and parser (the fixed @scope@ and @payload@ arguments
-- and no subject argument), and the Action, which locates the actor's
-- own authority tuple at exactly (actor, scope), takes the shared
-- absent rank when it does not exist, authorizes exactly when the
-- requested payload's rank is at most the actor's rank — no separate
-- membership condition, no redundant @IsSome@ — and updates exactly
-- that same actor\/scope tuple, all inside one Serializable
-- transaction with the same bounded retry and the same uniform
-- responses as the rule-1 Action.
selfUpdateActionLines :: NspeSupportPlan -> NspeCasePlan -> [Text]
selfUpdateActionLines shared casePlan =
  [ "// The self-update action's arguments: " <> scopeArgument <> " carries " <> named (caseScopeParameterName casePlan)
      <> " : EntityRef " <> named (planScopeEntityName shared) <> " and"
  , "// " <> payloadArgument <> " carries " <> named (casePayloadParameterName casePlan) <> " : Enum " <> named (planEnumName shared) <> "; the subject of the"
  , "// write is the authenticated principal itself, so no subject argument exists."
  , "type SelfUpdateArgs = { " <> scopeArgument <> ": number; " <> payloadArgument <> ": Payload };"
  , ""
  , "function parseSelfUpdateArgs(input: unknown): SelfUpdateArgs | null {"
  , "  if (typeof input !== \"object\" || input === null) {"
  , "    return null;"
  , "  }"
  , "  const record = input as Record<string, unknown>;"
  , "  const scopeArgument = record[" <> jsStringLiteral scopeArgument <> "];"
  , "  const payloadArgument = record[" <> jsStringLiteral payloadArgument <> "];"
  , "  if (!isEntityReference(scopeArgument) || !isPayload(payloadArgument)) {"
  , "    return null;"
  , "  }"
  , "  return { " <> scopeArgument <> ": scopeArgument, " <> payloadArgument <> ": payloadArgument };"
  , "}"
  , ""
  , "export const " <> selfUpdate <> ": " <> selfUpdateType <> "<SelfUpdateArgs, void> = async (input, context) => {"
  , "  // Principal: Wasp authentication is required, and context.user.id is the only"
  , "  // identity the Action uses — it is also the subject of the write (the subject"
  , "  // entity " <> subjectModel <> ", authored " <> named (planSubjectEntityName shared) <> ")."
  , "  if (!context.user) {"
  , "    throw new HttpError(401, \"authentication required\");"
  , "  }"
  , "  const actor: number = context.user.id;"
  , "  const args = parseSelfUpdateArgs(input);"
  , "  if (args === null) {"
  , "    throw new HttpError(400, \"invalid arguments\");"
  , "  }"
  , "  for (let attempt = 1; ; attempt += 1) {"
  , "    try {"
  , "      await prisma.$transaction("
  , "        async (tx) => {"
  , "          // Lookup[" <> named (planRelationName shared) <> "](" <> named (planSubjectEndpointName shared)
      <> " = Actor, " <> named (planScopeEndpointName shared) <> " = Argument[" <> named (caseScopeParameterName casePlan) <> "]):"
  , "          // the actor's own authority tuple, read inside this Serializable transaction."
  , "          const actorTuple = await tx." <> accessor <> ".findUnique({"
  , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": actor, " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
  , "          });"
  , "          const actorRank = actorTuple === null ? absentRank : payloadRank[actorTuple." <> payloadField <> "];"
  , "          // LessOrEqual(Some(Argument[" <> named (casePayloadParameterName casePlan) <> "]), actor authority): the requested"
  , "          // payload is bounded by the actor's own pre-state authority; an absent tuple"
  , "          // takes the absent rank below every member, so no separate membership"
  , "          // condition exists."
  , "          const allowed = payloadRank[args." <> payloadArgument <> "] <= actorRank;"
  , "          if (!allowed) {"
  , "            throw new HttpError(403, \"forbidden\");"
  , "          }"
  , "          // SetRelation[" <> named (planRelationName shared) <> "](" <> named (planSubjectEndpointName shared)
      <> " = Actor, " <> named (planScopeEndpointName shared) <> " = Argument[" <> named (caseScopeParameterName casePlan)
      <> "]) payload Argument[" <> named (casePayloadParameterName casePlan) <> "]: exactly the tuple read above."
  , "          await tx." <> accessor <> ".update({"
  , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": actor, " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
  , "            data: { " <> payloadField <> ": args." <> payloadArgument <> " },"
  , "          });"
  , "        },"
  , "        { isolationLevel: \"Serializable\" },"
  , "      );"
  , "      return;"
  , "    } catch (error) {"
  , "      if (error instanceof HttpError) {"
  , "        throw error;"
  , "      }"
  , "      if (isSerializationConflict(error)) {"
  , "        if (attempt < serializationAttempts) {"
  , "          continue;"
  , "        }"
  , "        throw new HttpError(409, \"conflict\");"
  , "      }"
  , "      throw new HttpError(500, \"internal error\");"
  , "    }"
  , "  }"
  , "};"
  ]
  where
    selfUpdate = targetSelfUpdateOperation targetNames
    selfUpdateType = targetSelfUpdateOperationType targetNames
    subjectModel = targetSubjectModel targetNames
    accessor = targetAuthorityAccessor targetNames
    subjectIdField = targetSubjectIdField targetNames
    scopeIdField = targetScopeIdField targetNames
    payloadField = targetPayloadField targetNames
    compoundKey = targetCompoundKey targetNames
    scopeArgument = targetScopeArgument targetNames
    payloadArgument = targetPayloadArgument targetNames

-- | The shared target-name mapping comment of the operation file (the
-- lines up to and including the payload column).
targetMappingLines :: NspeSupportPlan -> [Text]
targetMappingLines shared =
  [ "//"
  , "// Target-name mapping: entity references are the Int identities of the Prisma"
  , "// models " <> subjectModel <> " (" <> named (planSubjectEntityName shared) <> ") and "
      <> scopeModel <> " (" <> named (planScopeEntityName shared) <> "); the"
  , "// authority relation " <> named (planRelationName shared) <> " is the Prisma model " <> authorityModel
  , "// identified by (" <> subjectIdField <> ", " <> scopeIdField <> "):"
  , "//   " <> subjectIdField <> " for the endpoint " <> named (planSubjectEndpointName shared) <> ","
  , "//   " <> scopeIdField <> " for the endpoint " <> named (planScopeEndpointName shared) <> ","
  ]
  where
    subjectModel = targetSubjectModel targetNames
    scopeModel = targetScopeModel targetNames
    authorityModel = targetAuthorityModel targetNames
    subjectIdField = targetSubjectIdField targetNames
    scopeIdField = targetScopeIdField targetNames

operationLinesV0 :: WaspProfileV0Plan -> [Text]
operationLinesV0 plan =
  [ generatedHeader "//" shared
  , "//"
  , "// Wasp Confinement Profile v0: the one generated security-sensitive operation of"
  , "// this application — the NoSelfPrivilegeEscalation case action"
  , "// " <> named (caseActionName casePlan) <> " (action " <> countText (actionIndex (caseActionId casePlan))
      <> "), lowered as the Wasp Action " <> operation
  , "// (POST " <> targetRoute targetNames <> ").  This is the only file of the profile"
  , "// permitted to import prisma from \"wasp/server\"; mithril wasp check rejects any"
  , "// byte that differs from the regenerated bundle.  Every identifier below is a"
  , "// fixed target name of the profile; the authored Core names appear only in"
  , "// comments and string metadata."
  ]
    <> provenanceLines "//"
    <> [ "//"
       , "// Consumed normalized evidence:"
       ]
    <> ["//   " <> line | line <- evidenceLinesV0 plan]
    <> targetMappingLines shared
    <> [ "// with the payload column " <> payloadField <> " of the enum " <> payloadEnum <> " ("
           <> named (planEnumName shared) <> ").  The arguments"
       , "//   " <> subjectArgument <> " carries the parameter " <> named (changeOtherSubjectParameterName facts) <> ","
       , "//   " <> scopeArgument <> " carries the parameter " <> named (caseScopeParameterName casePlan) <> ","
       , "//   " <> payloadArgument <> " carries the parameter " <> named (casePayloadParameterName casePlan) <> ";"
       , "// absence of a tuple takes the absent rank below every member."
       , "import { HttpError, prisma } from \"wasp/server\";"
       , "import type { " <> operationType <> " } from \"wasp/server/operations\";"
       , ""
       ]
    <> operationConstantLines shared
    <> [""]
    <> changeOtherActionLines shared casePlan facts
  where
    shared = profileShared plan
    casePlan = profileCase plan
    facts = profileFacts plan
    operation = targetOperation targetNames
    operationType = targetOperationType targetNames
    payloadEnum = targetPayloadEnum targetNames
    payloadField = targetPayloadField targetNames
    subjectArgument = targetSubjectArgument targetNames
    scopeArgument = targetScopeArgument targetNames
    payloadArgument = targetPayloadArgument targetNames

operationLinesV1 :: WaspProfileV1Plan -> [Text]
operationLinesV1 plan =
  [ generatedHeader "//" shared
  , "//"
  , "// Wasp Confinement Profile v1: the two generated security-sensitive operations of"
  , "// this application, in the authored case order — the NoSelfPrivilegeEscalation"
  , "// case action " <> named (caseActionName changeOther) <> " (action " <> countText (actionIndex (caseActionId changeOther))
      <> ", case " <> countText (casePosition changeOther) <> "), lowered as the Wasp Action"
  , "// " <> operation <> " (POST " <> targetRoute targetNames <> "), and the case action"
  , "// " <> named (caseActionName selfUpdate) <> " (action " <> countText (actionIndex (caseActionId selfUpdate))
      <> ", case " <> countText (casePosition selfUpdate) <> "), lowered as the Wasp Action"
  , "// " <> selfUpdateOperation <> " (POST " <> targetSelfUpdateRoute targetNames <> ").  This is the"
  , "// only file of the profile permitted to import prisma from \"wasp/server\"; mithril"
  , "// wasp check rejects any byte that differs from the regenerated bundle.  Every"
  , "// identifier below is a fixed target name of the profile; the authored Core"
  , "// names appear only in comments and string metadata."
  ]
    <> provenanceLines "//"
    <> [ "//"
       , "// Consumed normalized evidence:"
       ]
    <> ["//   " <> line | line <- evidenceLinesV1 plan]
    <> targetMappingLines shared
    <> [ "// with the payload column " <> payloadField <> " of the enum " <> payloadEnum <> " ("
           <> named (planEnumName shared) <> ").  The arguments of " <> operation
       , "//   " <> subjectArgument <> " carries the parameter " <> named (changeOtherSubjectParameterName changeOtherFacts) <> ","
       , "//   " <> scopeArgument <> " carries the parameter " <> named (caseScopeParameterName changeOther) <> ","
       , "//   " <> payloadArgument <> " carries the parameter " <> named (casePayloadParameterName changeOther) <> ";"
       , "// the arguments of " <> selfUpdateOperation
       , "//   " <> scopeArgument <> " carries the parameter " <> named (caseScopeParameterName selfUpdate) <> ","
       , "//   " <> payloadArgument <> " carries the parameter " <> named (casePayloadParameterName selfUpdate) <> ","
       , "// and its subject is the authenticated principal itself (no subject argument exists);"
       , "// absence of a tuple takes the absent rank below every member."
       , "import { HttpError, prisma } from \"wasp/server\";"
       , "import type { " <> operationType <> ", " <> selfUpdateType <> " } from \"wasp/server/operations\";"
       , ""
       ]
    <> operationConstantLines shared
    <> [""]
    <> changeOtherActionLines shared changeOther changeOtherFacts
    <> [""]
    <> selfUpdateActionLines shared selfUpdate
  where
    shared = v1Shared plan
    changeOther = v1ChangeOtherCase plan
    changeOtherFacts = v1ChangeOtherFacts plan
    selfUpdate = v1SelfUpdateCase plan
    operation = targetOperation targetNames
    operationType = targetOperationType targetNames
    selfUpdateOperation = targetSelfUpdateOperation targetNames
    selfUpdateType = targetSelfUpdateOperationType targetNames
    payloadEnum = targetPayloadEnum targetNames
    payloadField = targetPayloadField targetNames
    subjectArgument = targetSubjectArgument targetNames
    scopeArgument = targetScopeArgument targetNames
    payloadArgument = targetPayloadArgument targetNames

--------------------------------------------------------------------
-- The manifest: the explicit authored-to-target mapping
--------------------------------------------------------------------

-- | The manifest fields both profiles share, from the format header
-- through the absence object: the explicit profile identity, the
-- version pins, the model, and the shared authored-to-target mapping.
manifestSharedLines :: WaspProfile -> NspeSupportPlan -> [Text]
manifestSharedLines profile shared =
  [ "{"
  , field "format" (jsStringLiteral "mithril-wasp-bundle")
  , field "formatVersion" (jsStringLiteral (manifestFormatVersion profile))
  , field "profile" (jsStringLiteral (profileNameOf profile))
  , field "generator" (jsStringLiteral "mithril wasp generate")
  , field
      "provenance"
      ( jsStringLiteral
          "lowered from the supported NoSelfPrivilegeEscalation shape; the generating command's report, not this file, states whether the document passed the proof gate"
      )
  , field "wasp" (jsStringLiteral waspVersion)
  , field "database" (jsStringLiteral databaseProvider)
  , field "prisma" (jsStringLiteral prismaVersion)
  , field "model" (jsStringLiteral (sourcedValue (planModelName shared)))
  , field "guarantee" (jsStringLiteral "NoSelfPrivilegeEscalation")
  , field "ownershipMarker" (jsStringLiteral (Text.pack ownershipMarkerPath))
  ]

-- | The manifest fields from the subject entity through the absence
-- object, shared by both profiles.
manifestSchemaLines :: NspeSupportPlan -> [Text]
manifestSchemaLines shared =
  [ field
      "subjectEntity"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planSubjectEntityName shared)))
          , ("position", countText (entityIndex (planSubjectEntityId shared)))
          , ("model", jsStringLiteral (targetSubjectModel targetNames))
          ]
      )
  , field
      "scopeEntity"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planScopeEntityName shared)))
          , ("position", countText (entityIndex (planScopeEntityId shared)))
          , ("model", jsStringLiteral (targetScopeModel targetNames))
          ]
      )
  , field
      "authorityRelation"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planRelationName shared)))
          , ("position", countText (relationIndex (planRelationId shared)))
          , ("model", jsStringLiteral (targetAuthorityModel targetNames))
          , ("accessor", jsStringLiteral (targetAuthorityAccessor targetNames))
          , ( "identity"
            , "[" <> jsStringLiteral (targetSubjectIdField targetNames) <> ", "
                <> jsStringLiteral (targetScopeIdField targetNames) <> "]"
            )
          , ("payloadColumn", jsStringLiteral (targetPayloadField targetNames))
          ]
      )
  , field
      "subjectEndpoint"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planSubjectEndpointName shared)))
          , ("position", countText (endpointIndex (planSubjectEndpointId shared)))
          , ("field", jsStringLiteral (targetSubjectField targetNames))
          , ("idField", jsStringLiteral (targetSubjectIdField targetNames))
          ]
      )
  , field
      "scopeEndpoint"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planScopeEndpointName shared)))
          , ("position", countText (endpointIndex (planScopeEndpointId shared)))
          , ("field", jsStringLiteral (targetScopeField targetNames))
          , ("idField", jsStringLiteral (targetScopeIdField targetNames))
          ]
      )
  , field
      "payloadEnum"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planEnumName shared)))
          , ("position", countText (enumIndex (planEnumId shared)))
          , ("enum", jsStringLiteral (targetPayloadEnum targetNames))
          ]
      )
  , field
      "members"
      ( array
          [ object
              [ ("authored", jsStringLiteral (sourcedValue (planMemberName member)))
              , ("position", countText (valueIndex (planMemberId member)))
              , ("value", jsStringLiteral (memberTargetName (planMemberId member)))
              ]
          | member <- planEnumMembers shared
          ]
      )
  , field "ranking" (array (map rankedObject (planRanking shared)))
  , field "bottom" (rankedObject (planRankBottom shared))
  , field "floor" (rankedObject (planRankTop shared))
  , field
      "absence"
      ( object
          [ ("level", jsStringLiteral (absenceText (planAbsenceLevel shared)))
          , ("rank", countText (planAbsentRank shared))
          ]
      )
  ]
  where
    rankedObject ranked =
      object
        [ ("rank", countText (planRankedRank ranked))
        , ("authored", jsStringLiteral (planRankedName ranked))
        , ("position", countText (valueIndex (planRankedId ranked)))
        , ("value", jsStringLiteral (memberTargetName (planRankedId ranked)))
        ]

-- | The manifest's closing managed-file inventory.
manifestInventoryLines :: [Text]
manifestInventoryLines =
  ["  \"managedFiles\": ["]
    <> [ "    " <> jsStringLiteral (Text.pack path) <> separator
       | (path, separator) <- zip inventory (replicate (length inventory - 1) "," <> [""])
       ]
    <> [ "  ]"
       , "}"
       ]
  where
    inventory = filter (/= manifestPath) managedPaths

field :: Text -> Text -> Text
field name value = "  " <> jsStringLiteral name <> ": " <> value <> ","

object :: [(Text, Text)] -> Text
object members =
  "{ "
    <> Text.intercalate ", " [jsStringLiteral name <> ": " <> value | (name, value) <- members]
    <> " }"

array :: [Text] -> Text
array items = "[" <> Text.intercalate ", " items <> "]"

parameterObject :: Text -> Sourced Text -> ParameterId -> Text -> Text
parameterObject role name identity argument =
  object
    [ ("role", jsStringLiteral role)
    , ("authored", jsStringLiteral (sourcedValue name))
    , ("position", countText (parameterIndex identity))
    , ("argument", jsStringLiteral argument)
    ]

bindingObject :: PlanBinding -> Text
bindingObject binding =
  object
    [ ("endpoint", jsStringLiteral (planBindingEndpointName binding))
    , ("endpointPosition", countText (endpointIndex (planBindingEndpointId binding)))
    , ("parameter", jsStringLiteral (planBindingParameterName binding))
    , ("parameterPosition", countText (parameterIndex (planBindingParameterId binding)))
    ]

manifestLinesV0 :: WaspProfileV0Plan -> [Text]
manifestLinesV0 plan =
  manifestSharedLines WaspProfileV0 shared
    <> [ field
           "caseAction"
           ( object
               [ ("authored", jsStringLiteral (sourcedValue (caseActionName casePlan)))
               , ("position", countText (actionIndex (caseActionId casePlan)))
               , ("operation", jsStringLiteral (targetOperation targetNames))
               , ("operationType", jsStringLiteral (targetOperationType targetNames))
               , ("route", jsStringLiteral (targetRoute targetNames))
               , ("file", jsStringLiteral (Text.pack operationPath))
               ]
           )
       ]
    <> manifestSchemaLines shared
    <> [ field
           "parameters"
           ( array
               [ parameterObject "subject" (changeOtherSubjectParameterName facts) (changeOtherSubjectParameterId facts) (targetSubjectArgument targetNames)
               , parameterObject "scope" (caseScopeParameterName casePlan) (caseScopeParameterId casePlan) (targetScopeArgument targetNames)
               , parameterObject "payload" (casePayloadParameterName casePlan) (casePayloadParameterId casePlan) (targetPayloadArgument targetNames)
               ]
           )
       , field "effectBindings" (array (map bindingObject (changeOtherEffectBindings facts)))
       , field "caseScopeBinding" (bindingObject (caseScopeBinding casePlan))
       ]
    <> manifestInventoryLines
  where
    shared = profileShared plan
    casePlan = profileCase plan
    facts = profileFacts plan

-- | The Profile-v1 manifest: the shared fields, then the complete
-- ordered @operations@ array — one object per lowered case in
-- authored order, each carrying the case position, the rule, the
-- authored action and its position, the fixed operation, type, route,
-- and file, its parameter mapping, its effect bindings, and its case
-- scope binding — then the inventory.
manifestLinesV1 :: WaspProfileV1Plan -> [Text]
manifestLinesV1 plan =
  manifestSharedLines WaspProfileV1 shared
    <> manifestSchemaLines shared
    <> [ "  \"operations\": ["
       , "    " <> changeOtherOperation <> ","
       , "    " <> selfUpdateOperation
       , "  ],"
       ]
    <> manifestInventoryLines
  where
    shared = v1Shared plan
    changeOther = v1ChangeOtherCase plan
    changeOtherFacts = v1ChangeOtherFacts plan
    selfUpdate = v1SelfUpdateCase plan
    selfUpdateFacts = v1SelfUpdateFacts plan
    changeOtherOperation =
      object
        [ ("case", countText (casePosition changeOther))
        , ("rule", jsStringLiteral (nspeRuleLabel (caseRule changeOther)))
        , ("authored", jsStringLiteral (sourcedValue (caseActionName changeOther)))
        , ("position", countText (actionIndex (caseActionId changeOther)))
        , ("operation", jsStringLiteral (targetOperation targetNames))
        , ("operationType", jsStringLiteral (targetOperationType targetNames))
        , ("route", jsStringLiteral (targetRoute targetNames))
        , ("file", jsStringLiteral (Text.pack operationPath))
        , ( "parameters"
          , array
              [ parameterObject "subject" (changeOtherSubjectParameterName changeOtherFacts) (changeOtherSubjectParameterId changeOtherFacts) (targetSubjectArgument targetNames)
              , parameterObject "scope" (caseScopeParameterName changeOther) (caseScopeParameterId changeOther) (targetScopeArgument targetNames)
              , parameterObject "payload" (casePayloadParameterName changeOther) (casePayloadParameterId changeOther) (targetPayloadArgument targetNames)
              ]
          )
        , ("effectBindings", array (map bindingObject (changeOtherEffectBindings changeOtherFacts)))
        , ("caseScopeBinding", bindingObject (caseScopeBinding changeOther))
        ]
    selfUpdateOperation =
      object
        [ ("case", countText (casePosition selfUpdate))
        , ("rule", jsStringLiteral (nspeRuleLabel (caseRule selfUpdate)))
        , ("authored", jsStringLiteral (sourcedValue (caseActionName selfUpdate)))
        , ("position", countText (actionIndex (caseActionId selfUpdate)))
        , ("operation", jsStringLiteral (targetSelfUpdateOperation targetNames))
        , ("operationType", jsStringLiteral (targetSelfUpdateOperationType targetNames))
        , ("route", jsStringLiteral (targetSelfUpdateRoute targetNames))
        , ("file", jsStringLiteral (Text.pack operationPath))
        , ( "parameters"
          , array
              [ parameterObject "scope" (caseScopeParameterName selfUpdate) (caseScopeParameterId selfUpdate) (targetScopeArgument targetNames)
              , parameterObject "payload" (casePayloadParameterName selfUpdate) (casePayloadParameterId selfUpdate) (targetPayloadArgument targetNames)
              ]
          )
        , ( "effectSubject"
          , object
              [ ("endpoint", jsStringLiteral (sourcedValue (planSubjectEndpointName shared)))
              , ("endpointPosition", countText (endpointIndex (planSubjectEndpointId shared)))
              , ("term", jsStringLiteral "Actor")
              ]
          )
        , ("effectScopeBinding", bindingObject (selfUpdateEffectScopeBinding selfUpdateFacts))
        , ("caseScopeBinding", bindingObject (caseScopeBinding selfUpdate))
        ]
