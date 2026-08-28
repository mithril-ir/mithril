{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The Wasp emitter of the Core v0 host tool: deterministic lowering of
-- the one shared NoSelfPrivilegeEscalation support plan
-- ("Mithril.Core.Internal.NspeSupportPlan") into a closed Wasp 0.25.0
-- application bundle — the /Wasp Confinement Profile v0/.  The
-- public boundary is exactly "Mithril.Core.Wasp"; the effectful
-- filesystem boundary is "Mithril.Core.Internal.WaspFilesystem"
-- behind the CLI boundary "Mithril.Command.Wasp"; the pure checker
-- that decides whether a source-root snapshot is exactly a
-- regenerated bundle is "Mithril.Core.Internal.WaspConfinement".
--
-- == What is generated
--
-- Exactly the supported @Membership.changeRole@-shaped slice, and
-- nothing else: a normal Wasp 0.25.0 application whose complete
-- security-sensitive input surface is owned by this emitter —
--
-- * the TypeScript specification @main.wasp.ts@ (Wasp auth with
--   username-and-password, exactly one route\/page, and exactly one
--   authenticated Action);
-- * the Prisma schema (PostgreSQL datasource; the subject and scope
--   entities as models, the authority relation as a model with a
--   composite identity over its endpoint fields and the payload enum
--   as its payload column, the authority enum's values in declaration
--   order);
-- * the generated TypeScript Action implementation, which requires
--   Wasp authentication, uses @context.user.id@ as the only identity,
--   validates its arguments, reads the actor's and the target's
--   authority tuples and performs the authorized @SetRelation@ write
--   inside one Prisma interactive transaction at @Serializable@
--   isolation, retries Prisma @P2034@ conflicts a fixed number of
--   times, and uses no raw SQL;
-- * the dependency configuration, TypeScript and Vite configuration,
--   the Wasp root marker, the Mithril ownership marker, the ignore
--   files, a minimal static client page (the client shell Wasp
--   requires), and a deterministic generation manifest.
--
-- == Target names: fixed, role-derived, collision-free
--
-- No authored Core name ever becomes an identifier of the generated
-- application.  Every Prisma model, enum, value, and field name,
-- every TypeScript identifier, the Wasp operation, its route, and
-- every managed path is a fixed name of the profile derived from the
-- /role/ a declaration plays in the supported shape (subject entity,
-- scope entity, authority relation, payload enum, subject\/scope
-- endpoint, subject\/scope\/payload parameter, case action) or, for
-- the enum's values, from the canonical declaration position carried
-- by the value's identity (@Value0@, @Value1@, …).  The fixed names
-- ('targetNames') are pairwise distinct and are none of Prisma's
-- scalar type names, Prisma's reserved names, Wasp's injected auth
-- models, or JavaScript\/TypeScript reserved words — pinned by the
-- test suite against closed lists.  Consequently the closed path
-- inventory ('managedPaths') never depends on authored names, a
-- supported document renders whatever its declarations are called,
-- and renaming a declaration or the action changes only metadata.
--
-- Authored names and identities survive as display metadata only:
-- inside line comments (through 'quotedName', which escapes every
-- control character, so no name can end a comment line) and inside
-- JSON\/JavaScript string literals (through 'jsStringLiteral').  The
-- manifest states the complete authored-to-target mapping explicitly.
--
-- == The Profile-v0 capability gate
--
-- The profile lowers exactly one case shape: a shared plan whose case
-- collection is exactly one rule-1 (change-other) case.  The gate
-- ('profileV0Plan') inspects the tagged case collection of the shared
-- plan — it never re-derives a rule — and refuses, before anything is
-- lowered and therefore before the CLI touches any destination, a
-- singleton rule-2 (bounded self-update) plan (anchored at the case)
-- and every multi-case plan (anchored at the guarantee) as
-- unsupported to this profile with deterministic reasons.  Only a
-- 'WaspProfileV0Plan' can be rendered.
--
-- == Determinism
--
-- The bundle depends only on the plan — never on file paths, time,
-- or environment — every file uses Unix line endings, no tabs, and
-- exactly one final newline.  The same normalized document always
-- renders to the same bytes, and the committed fixture under
-- @test\/fixtures\/wasp-acme@ is pinned byte-for-byte against a fresh
-- bundle.
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
-- == What this is not
--
-- Not a general Wasp backend, not a whole-product generator, not a
-- policy evaluator, and not a runtime sandbox.  No semantic
-- preservation theorem between the Core semantics and the generated
-- TypeScript exists: Wasp, Node, Prisma, PostgreSQL, the templates
-- below, and this lowering are trusted components.
module Mithril.Core.Internal.Wasp
  ( -- * The bundle
    WaspBundle
  , bundleFiles
  , bundleSummary
  , WaspManagedFile (..)
  , WaspBundleSummary (..)

    -- * Rendering
  , WaspRenderingRefusal (..)
  , WaspProfileV0Plan (..)
  , profileV0Plan
  , renderBundleFromModel
  , renderBundleFromPlan

    -- * The fixed profile: constants, target names, and managed paths
  , profileName
  , waspVersion
  , prismaVersion
  , databaseProvider
  , WaspTargetNames (..)
  , targetNames
  , memberTargetName
  , managedPaths
  , ownershipMarkerPath
  , ownershipMarkerBytes
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
  ( ChangeOtherFacts (..)
  , NspeCaseMatch (..)
  , NspeCasePlan (..)
  , NspeSupportPlan (..)
  , PlanBinding (..)
  , PlanEnumMember (..)
  , PlanRankedMember (..)
  , PlanRefusal (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation
  , caseRule
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

-- | A deterministic closed Wasp bundle: its report-facing summary and
-- its managed files, sorted by path and pairwise distinct.  The
-- constructor never leaves this module; a bundle exists only as the
-- result of 'renderBundleFromPlan'.
data WaspBundle = WaspBundle
  { bundleSummary :: WaspBundleSummary
  , bundleFiles :: [WaspManagedFile]
  }
  deriving (Eq, Show)

-- | The report-facing summary of a bundle: no bytes, no paths other
-- than the managed inventory.  The model and case-action names are
-- the authored names (metadata); the operation and route are the
-- fixed target names.
data WaspBundleSummary = WaspBundleSummary
  { summaryModelName :: Text
  , summaryGuarantee :: Text
  , summaryCaseAction :: Text
  , summaryOperation :: Text
  , summaryRoute :: Text
  , summaryManagedPaths :: [FilePath]
  }
  deriving (Eq, Show)

-- | Why no bundle was rendered: the document is outside the shared
-- support rule or outside this profile's capability (authored shapes,
-- sorted and deduplicated reasons), or the normalized model is
-- internally inconsistent (forged or drifted — a tool error, decided
-- by the shared gate before anything is lowered).  The lowering
-- itself refuses nothing: every Profile-v0 plan renders.
data WaspRenderingRefusal
  = RenderUnsupported (NonEmpty UnsupportedReason)
  | RenderInvariant (NonEmpty VerifierInvariantViolation)
  deriving (Eq, Show)

-- | The one plan shape the Wasp Confinement Profile v0 lowers: the
-- shared plan (whose case collection the gate proved to be exactly
-- one change-other case), that case, and its rule-1 facts.  Only the
-- gate constructs it; the renderer is total over it.
data WaspProfileV0Plan = WaspProfileV0Plan
  { profileShared :: NspeSupportPlan
  , profileCase :: NspeCasePlan
  , profileFacts :: ChangeOtherFacts
  }
  deriving (Eq)

-- | The Profile-v0 capability gate over the shared tagged plan
-- (module header): exactly one case, and that case a rule-1 case;
-- everything else is refused with a deterministic source-anchored
-- reason before any lowering.  The rule tag is read from the plan,
-- never re-derived.
profileV0Plan
  :: NspeSupportPlan -> Either (NonEmpty UnsupportedReason) WaspProfileV0Plan
profileV0Plan plan =
  case planCases plan of
    onlyCase :| [] ->
      case caseMatch onlyCase of
        ChangeOtherMatch facts ->
          Right
            WaspProfileV0Plan
              { profileShared = plan
              , profileCase = onlyCase
              , profileFacts = facts
              }
        BoundedSelfUpdateMatch _ ->
          Left
            ( UnsupportedReason
                (sourcePathSegments (casePath onlyCase))
                ( profileCapability
                    <> "; this case matches "
                    <> nspeRuleLabel (caseRule onlyCase)
                    <> ", which the profile does not lower"
                )
                :| []
            )
    cases ->
      Left
        ( UnsupportedReason
            (sourcePathSegments (planGuaranteePath plan))
            ( profileCapability
                <> "; this guarantee selects "
                <> countText (NonEmpty.length cases)
                <> " cases"
            )
            :| []
        )
  where
    profileCapability = "Wasp Profile v0 lowers exactly one Rule-1 case"

-- | Render the bundle of a normalized model: the shared support gate,
-- then the Profile-v0 capability gate, then the files.
renderBundleFromModel
  :: Normalized.Model -> Either WaspRenderingRefusal WaspBundle
renderBundleFromModel model =
  case supportPlan model of
    Left (PlanInvariant violations) -> Left (RenderInvariant violations)
    Left (PlanUnsupported reasons) -> Left (RenderUnsupported reasons)
    Right plan ->
      case profileV0Plan plan of
        Left reasons -> Left (RenderUnsupported reasons)
        Right profile -> Right (renderBundleFromPlan profile)

-- | Render the bundle of a Profile-v0 plan: total, because every
-- target name is fixed and every authored name is rendered as escaped
-- metadata only.
renderBundleFromPlan :: WaspProfileV0Plan -> WaspBundle
renderBundleFromPlan plan =
  WaspBundle
    { bundleSummary =
        WaspBundleSummary
          { summaryModelName = sourcedValue (planModelName (profileShared plan))
          , summaryGuarantee = "NoSelfPrivilegeEscalation"
          , summaryCaseAction = sourcedValue (caseActionName (profileCase plan))
          , summaryOperation = targetOperation targetNames
          , summaryRoute = targetRoute targetNames
          , summaryManagedPaths = managedPaths
          }
    , bundleFiles = sortOn managedPath (renderFiles plan)
    }

--------------------------------------------------------------------
-- The fixed profile
--------------------------------------------------------------------

-- | The name of the profile every bundle instantiates.
profileName :: Text
profileName = "wasp-confinement-profile-v0"

-- | The exact Wasp version the bundle pins.
waspVersion :: Text
waspVersion = "0.25.0"

-- | The Prisma version Wasp 0.25.0 requires in the application's
-- dependency configuration (the Prisma runtime itself is supplied by
-- Wasp; the bundle adds no database client).
prismaVersion :: Text
prismaVersion = "5.19.1"

-- | The only database provider of the profile.
databaseProvider :: Text
databaseProvider = "postgresql"

-- | The fixed target names of the profile (module header): one name
-- per role of the supported shape, never an authored name.
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
    -- ^ The Wasp operation identifier (its export and its file's base name).
  , targetOperationType :: Text
    -- ^ The Wasp-generated server operation type name.
  , targetRoute :: Text
    -- ^ The HTTP route Wasp mounts the Action at.
  , targetSubjectArgument :: Text
    -- ^ The Action's argument carrying the subject parameter.
  , targetScopeArgument :: Text
    -- ^ The Action's argument carrying the scope parameter.
  , targetPayloadArgument :: Text
    -- ^ The Action's argument carrying the payload parameter.
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
    , targetSubjectArgument = "subject"
    , targetScopeArgument = "scope"
    , targetPayloadArgument = "payload"
    , targetAppName = "mithrilWaspApp"
    }
  where
    operation = "mithrilCaseAction"

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
-- never depend on the document, so an owned root stays recognizable
-- whatever else in it was altered or removed.
ownershipMarkerPath :: FilePath
ownershipMarkerPath = ".mithril-wasp-profile"

-- | The exact bytes of the ownership marker.
ownershipMarkerBytes :: ByteString
ownershipMarkerBytes =
  Encoding.encodeUtf8
    ( Text.unlines
        [ "# Mithril ownership marker of a Wasp Confinement Profile v0 root.  DO NOT EDIT."
        , "# mithril wasp generate replaces a nonempty root as a whole only when this file"
        , "# is byte-exact and every entry of the root is a managed path of the profile's"
        , "# fixed inventory; an unmarked nonempty root is never replaced."
        , "mithril-wasp-bundle wasp-confinement-profile-v0"
        ]
    )

-- | The closed path inventory of every bundle, sorted: fixed, and
-- independent of every authored name.
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

-- | The consumed normalized evidence, rendered as the Agda
-- generator's evidence block renders it (names through 'quotedName',
-- identities as declaration positions), so a reviewer can read the
-- same facts off both derived artifacts.
evidenceLines :: WaspProfileV0Plan -> [Text]
evidenceLines plan =
  [ "model: " <> named (planModelName (profileShared plan))
  , "guarantee: NoSelfPrivilegeEscalation"
  , "authority relation: "
      <> named (planRelationName (profileShared plan))
      <> " (relation "
      <> countText (relationIndex (planRelationId (profileShared plan)))
      <> ")"
  , "authority subject endpoint: "
      <> endpointEvidence
        (planSubjectEndpointName (profileShared plan))
        (planSubjectEndpointId (profileShared plan))
        (planSubjectEntityName (profileShared plan))
        (planSubjectEntityId (profileShared plan))
  , "authority scope endpoint: "
      <> endpointEvidence
        (planScopeEndpointName (profileShared plan))
        (planScopeEndpointId (profileShared plan))
        (planScopeEntityName (profileShared plan))
        (planScopeEntityId (profileShared plan))
  , "authority absence level: " <> absenceText (planAbsenceLevel (profileShared plan))
  , "authority payload order: enum "
      <> named (planEnumName (profileShared plan))
      <> " (enum "
      <> countText (enumIndex (planEnumId (profileShared plan)))
      <> ")"
  , "declared enum members: "
      <> Text.intercalate
        ", "
        [ valueEvidence (sourcedValue (planMemberName member)) (planMemberId member)
        | member <- planEnumMembers (profileShared plan)
        ]
  , "materialized authority ranking: "
      <> Text.intercalate
        ", "
        [ "rank " <> countText (planRankedRank ranked) <> " = "
            <> valueEvidence (planRankedName ranked) (planRankedId ranked)
        | ranked <- planRanking (profileShared plan)
        ]
  , "materialized bottom: " <> rankedEvidence (planRankBottom (profileShared plan))
  , "privilege floor: " <> rankedEvidence (planRankTop (profileShared plan))
  , "absent rank: " <> countText (planAbsentRank (profileShared plan))
  , "case action: "
      <> named (caseActionName (profileCase plan))
      <> " (action "
      <> countText (actionIndex (caseActionId (profileCase plan)))
      <> ")"
  , "case scope binding: " <> bindingEvidence (caseScopeBinding (profileCase plan))
  , "principal mode: AuthenticatedOnly"
  , "parameter "
      <> countText (parameterIndex (changeOtherSubjectParameterId (profileFacts plan)))
      <> ": "
      <> named (changeOtherSubjectParameterName (profileFacts plan))
      <> " : EntityRef "
      <> named (planSubjectEntityName (profileShared plan))
  , "parameter "
      <> countText (parameterIndex (caseScopeParameterId (profileCase plan)))
      <> ": "
      <> named (caseScopeParameterName (profileCase plan))
      <> " : EntityRef "
      <> named (planScopeEntityName (profileShared plan))
  , "parameter "
      <> countText (parameterIndex (casePayloadParameterId (profileCase plan)))
      <> ": "
      <> named (casePayloadParameterName (profileCase plan))
      <> " : Enum "
      <> named (planEnumName (profileShared plan))
  , "allow policy: And(LessOrEqual[order optional "
      <> named (planEnumName (profileShared plan))
      <> ", absence as bottom](Some(Enum["
      <> named (planEnumName (profileShared plan))
      <> "."
      <> quotedName (planRankedName (planRankTop (profileShared plan)))
      <> "]), Lookup["
      <> named (planRelationName (profileShared plan))
      <> "]("
      <> named (planSubjectEndpointName (profileShared plan))
      <> " = Actor, "
      <> named (planScopeEndpointName (profileShared plan))
      <> " = Argument["
      <> named (caseScopeParameterName (profileCase plan))
      <> "])), And(Not(Equal(Actor, Argument["
      <> named (changeOtherSubjectParameterName (profileFacts plan))
      <> "])), IsSome(Lookup["
      <> named (planRelationName (profileShared plan))
      <> "]("
      <> named (planSubjectEndpointName (profileShared plan))
      <> " = Argument["
      <> named (changeOtherSubjectParameterName (profileFacts plan))
      <> "], "
      <> named (planScopeEndpointName (profileShared plan))
      <> " = Argument["
      <> named (caseScopeParameterName (profileCase plan))
      <> "]))))"
  , "effect: SetRelation["
      <> named (planRelationName (profileShared plan))
      <> "]("
      <> Text.intercalate ", " (map bindingEvidence (changeOtherEffectBindings (profileFacts plan)))
      <> ") payload Argument["
      <> named (casePayloadParameterName (profileCase plan))
      <> "]"
  , "result: Done"
  ]
  where
    endpointEvidence endpointName endpointId entityName entityId =
      named endpointName
        <> " (endpoint "
        <> countText (endpointIndex endpointId)
        <> " of relation "
        <> countText (relationIndex (planRelationId (profileShared plan)))
        <> "), entity "
        <> named entityName
        <> " (entity "
        <> countText (entityIndex entityId)
        <> ")"
    valueEvidence valueName valueId =
      quotedName valueName
        <> " (value "
        <> countText (valueIndex valueId)
        <> " of enum "
        <> countText (enumIndex (planEnumId (profileShared plan)))
        <> ")"
    rankedEvidence ranked =
      "rank " <> countText (planRankedRank ranked) <> " = "
        <> valueEvidence (planRankedName ranked) (planRankedId ranked)
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

--------------------------------------------------------------------
-- The managed files
--------------------------------------------------------------------

-- | Every managed file of the profile, rendered from the plan.
renderFiles :: WaspProfileV0Plan -> [WaspManagedFile]
renderFiles plan =
  [ textFile ".gitignore" gitignoreLines
  , textFile ".npmrc" npmrcLines
  , textFile ".wasproot" ["File marking the root of Wasp project."]
  , WaspManagedFile ownershipMarkerPath ownershipMarkerBytes
  , textFile specPath (specLines plan)
  , textFile schemaPath (schemaLines plan)
  , textFile packagePath packageLines
  , textFile "tsconfig.json" tsconfigLines
  , textFile "tsconfig.src.json" tsconfigSrcLines
  , textFile "tsconfig.wasp.json" tsconfigWaspLines
  , textFile "vite.config.ts" (viteConfigLines plan)
  , textFile clientPagePath (clientPageLines plan)
  , textFile operationPath (operationLines plan)
  , textFile manifestPath (manifestLines plan)
  ]

textFile :: FilePath -> [Text] -> WaspManagedFile
textFile path fileLines =
  WaspManagedFile
    { managedPath = path
    , managedBytes = Encoding.encodeUtf8 (Text.unlines fileLines)
    }

generatedHeader :: Text -> WaspProfileV0Plan -> Text
generatedHeader commentLead plan =
  commentLead
    <> " Generated by mithril wasp generate from Mithril Core v0 model "
    <> named (planModelName (profileShared plan))
    <> ".  DO NOT EDIT."

-- | The provenance sentence every commented managed file carries: the
-- bytes attest lowering of a supported shape only.
provenanceLines :: Text -> [Text]
provenanceLines commentLead =
  [ commentLead <> " Lowering attests support of the shape only; the generating command's report,"
  , commentLead <> " not these bytes, states whether the document passed the proof gate."
  ]

gitignoreLines :: [Text]
gitignoreLines =
  [ "# Generated by mithril wasp generate.  DO NOT EDIT."
  , "# Wasp Confinement Profile v0: installation, build, migration, and"
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

specLines :: WaspProfileV0Plan -> [Text]
specLines plan =
  [ generatedHeader "//" plan
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
       , "  title: " <> jsStringLiteral (sourcedValue (planModelName (profileShared plan))) <> ","
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
    operation = targetOperation targetNames

schemaLines :: WaspProfileV0Plan -> [Text]
schemaLines plan =
  [ generatedHeader "//" plan
  , "//"
  , "// Wasp Confinement Profile v0: the PostgreSQL datasource, the subject and scope"
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
  , "// " <> subjectModel <> ": the subject entity " <> named (planSubjectEntityName (profileShared plan))
      <> " (entity " <> countText (entityIndex (planSubjectEntityId (profileShared plan))) <> ") — the"
  , "// authenticated principal and Wasp's auth user entity."
  , "model " <> subjectModel <> " {"
  , "  id          Int @id @default(autoincrement())"
  , "  authorities " <> authorityModel <> "[]"
  , "}"
  , ""
  , "// " <> scopeModel <> ": the scope entity " <> named (planScopeEntityName (profileShared plan))
      <> " (entity " <> countText (entityIndex (planScopeEntityId (profileShared plan))) <> ")."
  , "model " <> scopeModel <> " {"
  , "  id          Int @id @default(autoincrement())"
  , "  authorities " <> authorityModel <> "[]"
  , "}"
  , ""
  , "// " <> payloadEnum <> ": the authority payload enum " <> named (planEnumName (profileShared plan))
      <> " (enum " <> countText (enumIndex (planEnumId (profileShared plan))) <> "); value i"
  , "// of the enum is the value Value<i>, in declaration order:"
  , "//   " <> memberMapping <> "."
  , "// (The ranking is materialized in the generated Action, not here.)"
  , "enum " <> payloadEnum <> " {"
  ]
    <> ["  " <> memberTargetName (planMemberId member) | member <- planEnumMembers (profileShared plan)]
    <> [ "}"
       , ""
       , "// " <> authorityModel <> ": the authority relation " <> named (planRelationName (profileShared plan))
           <> " (relation " <> countText (relationIndex (planRelationId (profileShared plan))) <> "), identified"
       , "// by its endpoints — subjectId for the subject endpoint " <> named (planSubjectEndpointName (profileShared plan))
           <> " (endpoint " <> countText (endpointIndex (planSubjectEndpointId (profileShared plan))) <> ")"
       , "// and scopeId for the scope endpoint " <> named (planScopeEndpointName (profileShared plan))
           <> " (endpoint " <> countText (endpointIndex (planScopeEndpointId (profileShared plan))) <> ") — with"
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
        | member <- planEnumMembers (profileShared plan)
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

viteConfigLines :: WaspProfileV0Plan -> [Text]
viteConfigLines plan =
  [ generatedHeader "//" plan
  , "import { defineConfig } from \"vite\";"
  , "import { wasp } from \"wasp/client/vite\";"
  , ""
  , "export default defineConfig({"
  , "  plugins: [wasp()],"
  , "});"
  ]

clientPageLines :: WaspProfileV0Plan -> [Text]
clientPageLines plan =
  [ generatedHeader "//" plan
  , "// The minimal static client shell Wasp requires; the generated Action is"
  , "// exercised over Wasp's real HTTP and authentication path, not from here."
  , "export function MainPage() {"
  , "  return ("
  , "    <main>"
  , "      <h1>{" <> jsStringLiteral ("Mithril Core v0 model " <> named (planModelName (profileShared plan))) <> "}</h1>"
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

operationLines :: WaspProfileV0Plan -> [Text]
operationLines plan =
  [ generatedHeader "//" plan
  , "//"
  , "// Wasp Confinement Profile v0: the one generated security-sensitive operation of"
  , "// this application — the NoSelfPrivilegeEscalation case action"
  , "// " <> named (caseActionName (profileCase plan)) <> " (action " <> countText (actionIndex (caseActionId (profileCase plan)))
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
    <> ["//   " <> line | line <- evidenceLines plan]
    <> [ "//"
       , "// Target-name mapping: entity references are the Int identities of the Prisma"
       , "// models " <> subjectModel <> " (" <> named (planSubjectEntityName (profileShared plan)) <> ") and "
           <> scopeModel <> " (" <> named (planScopeEntityName (profileShared plan)) <> "); the"
       , "// authority relation " <> named (planRelationName (profileShared plan)) <> " is the Prisma model " <> authorityModel
       , "// identified by (" <> subjectIdField <> ", " <> scopeIdField <> "):"
       , "//   " <> subjectIdField <> " for the endpoint " <> named (planSubjectEndpointName (profileShared plan)) <> ","
       , "//   " <> scopeIdField <> " for the endpoint " <> named (planScopeEndpointName (profileShared plan)) <> ","
       , "// with the payload column " <> payloadField <> " of the enum " <> payloadEnum <> " ("
           <> named (planEnumName (profileShared plan)) <> ").  The arguments"
       , "//   " <> subjectArgument <> " carries the parameter " <> named (changeOtherSubjectParameterName (profileFacts plan)) <> ","
       , "//   " <> scopeArgument <> " carries the parameter " <> named (caseScopeParameterName (profileCase plan)) <> ","
       , "//   " <> payloadArgument <> " carries the parameter " <> named (casePayloadParameterName (profileCase plan)) <> ";"
       , "// absence of a tuple takes the absent rank below every member."
       , "import { HttpError, prisma } from \"wasp/server\";"
       , "import type { " <> operationType <> " } from \"wasp/server/operations\";"
       , ""
       , "// The authority payload enum " <> payloadEnum <> " (" <> named (planEnumName (profileShared plan)) <> "): the values in"
       , "// declaration order,"
       , "//   " <> memberMapping <> "."
       , "type Payload = " <> Text.intercalate " | " (map jsStringLiteral memberValues) <> ";"
       , "const payloadMembers: readonly string[] = [" <> Text.intercalate ", " (map jsStringLiteral memberValues) <> "];"
       , ""
       , "// The materialized ranking (rank 0 is the bottom ranked value):"
       , "//   " <> rankingMapping <> ";"
       , "// the privilege floor is the rank of " <> rankedTarget (planRankTop (profileShared plan)) <> " ("
           <> quotedName (planRankedName (planRankTop (profileShared plan))) <> "), and an absent authority"
       , "// tuple takes the absent rank below every member (absence level "
           <> absenceText (planAbsenceLevel (profileShared plan)) <> ")."
       , "const payloadRank: Readonly<Record<Payload, number>> = { "
           <> Text.intercalate
             ", "
             [ jsStringLiteral (rankedTarget ranked) <> ": " <> countText (planRankedRank ranked)
             | ranked <- planRanking (profileShared plan)
             ]
           <> " };"
       , "const floorRank = " <> countText (planRankedRank (planRankTop (profileShared plan))) <> ";"
       , "const absentRank = " <> countText (planAbsentRank (profileShared plan)) <> ";"
       , ""
       , "// Bounded deterministic retry of Serializable write conflicts (Prisma P2034)."
       , "const serializationAttempts = 3;"
       , ""
       , "// The action's arguments: " <> subjectArgument <> " carries " <> named (changeOtherSubjectParameterName (profileFacts plan))
           <> " : EntityRef " <> named (planSubjectEntityName (profileShared plan)) <> ","
       , "// " <> scopeArgument <> " carries " <> named (caseScopeParameterName (profileCase plan)) <> " : EntityRef "
           <> named (planScopeEntityName (profileShared plan)) <> ", and " <> payloadArgument <> " carries"
       , "// " <> named (casePayloadParameterName (profileCase plan)) <> " : Enum " <> named (planEnumName (profileShared plan)) <> "."
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
           <> named (planSubjectEntityName (profileShared plan)) <> ")."
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
       , "          // Lookup[" <> named (planRelationName (profileShared plan)) <> "](" <> named (planSubjectEndpointName (profileShared plan))
           <> " = Actor, " <> named (planScopeEndpointName (profileShared plan)) <> " = Argument[" <> named (caseScopeParameterName (profileCase plan)) <> "]):"
       , "          // all mutable authorization state is read inside this Serializable transaction."
       , "          const actorTuple = await tx." <> accessor <> ".findUnique({"
       , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": actor, " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
       , "          });"
       , "          // Lookup[" <> named (planRelationName (profileShared plan)) <> "](" <> named (planSubjectEndpointName (profileShared plan))
           <> " = Argument[" <> named (changeOtherSubjectParameterName (profileFacts plan)) <> "], " <> named (planScopeEndpointName (profileShared plan))
           <> " = Argument[" <> named (caseScopeParameterName (profileCase plan)) <> "])."
       , "          const targetTuple = await tx." <> accessor <> ".findUnique({"
       , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": args." <> subjectArgument <> ", " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
       , "          });"
       , "          const actorRank = actorTuple === null ? absentRank : payloadRank[actorTuple." <> payloadField <> "];"
       , "          // And(LessOrEqual(Some(" <> quotedName (planRankedName (planRankTop (profileShared plan))) <> "), actor authority), And(Not(Equal(Actor, "
           <> named (changeOtherSubjectParameterName (profileFacts plan)) <> ")), IsSome(target authority)))."
       , "          const allowed = floorRank <= actorRank && (!(actor === args." <> subjectArgument <> ") && targetTuple !== null);"
       , "          if (!allowed) {"
       , "            throw new HttpError(403, \"forbidden\");"
       , "          }"
       , "          // SetRelation[" <> named (planRelationName (profileShared plan)) <> "](" <> named (planSubjectEndpointName (profileShared plan))
           <> " = Argument[" <> named (changeOtherSubjectParameterName (profileFacts plan)) <> "], " <> named (planScopeEndpointName (profileShared plan))
           <> " = Argument[" <> named (caseScopeParameterName (profileCase plan)) <> "]) payload Argument["
           <> named (casePayloadParameterName (profileCase plan)) <> "]."
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
    scopeModel = targetScopeModel targetNames
    authorityModel = targetAuthorityModel targetNames
    accessor = targetAuthorityAccessor targetNames
    payloadEnum = targetPayloadEnum targetNames
    subjectIdField = targetSubjectIdField targetNames
    scopeIdField = targetScopeIdField targetNames
    payloadField = targetPayloadField targetNames
    compoundKey = targetCompoundKey targetNames
    subjectArgument = targetSubjectArgument targetNames
    scopeArgument = targetScopeArgument targetNames
    payloadArgument = targetPayloadArgument targetNames
    memberValues = [memberTargetName (planMemberId member) | member <- planEnumMembers (profileShared plan)]
    memberMapping =
      Text.intercalate
        ", "
        [ memberTargetName (planMemberId member) <> " = " <> named (planMemberName member)
        | member <- planEnumMembers (profileShared plan)
        ]
    rankedTarget ranked = memberTargetName (planRankedId ranked)
    rankingMapping =
      Text.intercalate
        ", "
        [ "rank " <> countText (planRankedRank ranked) <> " = " <> rankedTarget ranked
            <> " (" <> quotedName (planRankedName ranked) <> ")"
        | ranked <- planRanking (profileShared plan)
        ]

--------------------------------------------------------------------
-- The manifest: the explicit authored-to-target mapping
--------------------------------------------------------------------

manifestLines :: WaspProfileV0Plan -> [Text]
manifestLines plan =
  [ "{"
  , field "format" (jsStringLiteral "mithril-wasp-bundle")
  , field "formatVersion" (jsStringLiteral "0")
  , field "profile" (jsStringLiteral profileName)
  , field "generator" (jsStringLiteral "mithril wasp generate")
  , field
      "provenance"
      ( jsStringLiteral
          "lowered from the supported NoSelfPrivilegeEscalation shape; the generating command's report, not this file, states whether the document passed the proof gate"
      )
  , field "wasp" (jsStringLiteral waspVersion)
  , field "database" (jsStringLiteral databaseProvider)
  , field "prisma" (jsStringLiteral prismaVersion)
  , field "model" (jsStringLiteral (sourcedValue (planModelName (profileShared plan))))
  , field "guarantee" (jsStringLiteral "NoSelfPrivilegeEscalation")
  , field "ownershipMarker" (jsStringLiteral (Text.pack ownershipMarkerPath))
  , field
      "caseAction"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (caseActionName (profileCase plan))))
          , ("position", countText (actionIndex (caseActionId (profileCase plan))))
          , ("operation", jsStringLiteral (targetOperation targetNames))
          , ("operationType", jsStringLiteral (targetOperationType targetNames))
          , ("route", jsStringLiteral (targetRoute targetNames))
          , ("file", jsStringLiteral (Text.pack operationPath))
          ]
      )
  , field
      "subjectEntity"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planSubjectEntityName (profileShared plan))))
          , ("position", countText (entityIndex (planSubjectEntityId (profileShared plan))))
          , ("model", jsStringLiteral (targetSubjectModel targetNames))
          ]
      )
  , field
      "scopeEntity"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planScopeEntityName (profileShared plan))))
          , ("position", countText (entityIndex (planScopeEntityId (profileShared plan))))
          , ("model", jsStringLiteral (targetScopeModel targetNames))
          ]
      )
  , field
      "authorityRelation"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planRelationName (profileShared plan))))
          , ("position", countText (relationIndex (planRelationId (profileShared plan))))
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
          [ ("authored", jsStringLiteral (sourcedValue (planSubjectEndpointName (profileShared plan))))
          , ("position", countText (endpointIndex (planSubjectEndpointId (profileShared plan))))
          , ("field", jsStringLiteral (targetSubjectField targetNames))
          , ("idField", jsStringLiteral (targetSubjectIdField targetNames))
          ]
      )
  , field
      "scopeEndpoint"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planScopeEndpointName (profileShared plan))))
          , ("position", countText (endpointIndex (planScopeEndpointId (profileShared plan))))
          , ("field", jsStringLiteral (targetScopeField targetNames))
          , ("idField", jsStringLiteral (targetScopeIdField targetNames))
          ]
      )
  , field
      "payloadEnum"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planEnumName (profileShared plan))))
          , ("position", countText (enumIndex (planEnumId (profileShared plan))))
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
          | member <- planEnumMembers (profileShared plan)
          ]
      )
  , field "ranking" (array (map rankedObject (planRanking (profileShared plan))))
  , field "bottom" (rankedObject (planRankBottom (profileShared plan)))
  , field "floor" (rankedObject (planRankTop (profileShared plan)))
  , field
      "absence"
      ( object
          [ ("level", jsStringLiteral (absenceText (planAbsenceLevel (profileShared plan))))
          , ("rank", countText (planAbsentRank (profileShared plan)))
          ]
      )
  , field
      "parameters"
      ( array
          [ parameterObject "subject" (changeOtherSubjectParameterName (profileFacts plan)) (changeOtherSubjectParameterId (profileFacts plan)) (targetSubjectArgument targetNames)
          , parameterObject "scope" (caseScopeParameterName (profileCase plan)) (caseScopeParameterId (profileCase plan)) (targetScopeArgument targetNames)
          , parameterObject "payload" (casePayloadParameterName (profileCase plan)) (casePayloadParameterId (profileCase plan)) (targetPayloadArgument targetNames)
          ]
      )
  , field "effectBindings" (array (map bindingObject (changeOtherEffectBindings (profileFacts plan))))
  , field "caseScopeBinding" (bindingObject (caseScopeBinding (profileCase plan)))
  , "  \"managedFiles\": ["
  ]
    <> [ "    " <> jsStringLiteral (Text.pack path) <> separator
       | (path, separator) <- zip inventory (replicate (length inventory - 1) "," <> [""])
       ]
    <> [ "  ]"
       , "}"
       ]
  where
    inventory = filter (/= manifestPath) managedPaths
    field name value = "  " <> jsStringLiteral name <> ": " <> value <> ","
    object members =
      "{ "
        <> Text.intercalate ", " [jsStringLiteral name <> ": " <> value | (name, value) <- members]
        <> " }"
    array items = "[" <> Text.intercalate ", " items <> "]"
    rankedObject ranked =
      object
        [ ("rank", countText (planRankedRank ranked))
        , ("authored", jsStringLiteral (planRankedName ranked))
        , ("position", countText (valueIndex (planRankedId ranked)))
        , ("value", jsStringLiteral (memberTargetName (planRankedId ranked)))
        ]
    parameterObject role name identity argument =
      object
        [ ("role", jsStringLiteral role)
        , ("authored", jsStringLiteral (sourcedValue name))
        , ("position", countText (parameterIndex identity))
        , ("argument", jsStringLiteral argument)
        ]
    bindingObject binding =
      object
        [ ("endpoint", jsStringLiteral (planBindingEndpointName binding))
        , ("endpointPosition", countText (endpointIndex (planBindingEndpointId binding)))
        , ("parameter", jsStringLiteral (planBindingParameterName binding))
        , ("parameterPosition", countText (parameterIndex (planBindingParameterId binding)))
        ]
