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
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Numeric (showHex)

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.NspeSupportPlan
  ( NspeSupportPlan (..)
  , PlanBinding (..)
  , PlanEnumMember (..)
  , PlanRankedMember (..)
  , PlanRefusal (..)
  , UnsupportedReason
  , VerifierInvariantViolation
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
import Mithril.Core.Internal.SourcePath (Sourced (..))
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
-- support rule (authored shapes, sorted and deduplicated), or the
-- normalized model is internally inconsistent (forged or drifted — a
-- tool error, decided by the shared gate before anything is lowered).
-- The lowering itself refuses nothing: every supported plan renders.
data WaspRenderingRefusal
  = RenderUnsupported (NonEmpty UnsupportedReason)
  | RenderInvariant (NonEmpty VerifierInvariantViolation)
  deriving (Eq, Show)

-- | Render the bundle of a normalized model: the shared support gate,
-- then the files.
renderBundleFromModel
  :: Normalized.Model -> Either WaspRenderingRefusal WaspBundle
renderBundleFromModel model =
  case supportPlan model of
    Left (PlanInvariant violations) -> Left (RenderInvariant violations)
    Left (PlanUnsupported reasons) -> Left (RenderUnsupported reasons)
    Right plan -> Right (renderBundleFromPlan plan)

-- | Render the bundle of a plan: total, because every target name is
-- fixed and every authored name is rendered as escaped metadata only.
renderBundleFromPlan :: NspeSupportPlan -> WaspBundle
renderBundleFromPlan plan =
  WaspBundle
    { bundleSummary =
        WaspBundleSummary
          { summaryModelName = sourcedValue (planModelName plan)
          , summaryGuarantee = "NoSelfPrivilegeEscalation"
          , summaryCaseAction = sourcedValue (planActionName plan)
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
evidenceLines :: NspeSupportPlan -> [Text]
evidenceLines plan =
  [ "model: " <> named (planModelName plan)
  , "guarantee: NoSelfPrivilegeEscalation"
  , "authority relation: "
      <> named (planRelationName plan)
      <> " (relation "
      <> countText (relationIndex (planRelationId plan))
      <> ")"
  , "authority subject endpoint: "
      <> endpointEvidence
        (planSubjectEndpointName plan)
        (planSubjectEndpointId plan)
        (planSubjectEntityName plan)
        (planSubjectEntityId plan)
  , "authority scope endpoint: "
      <> endpointEvidence
        (planScopeEndpointName plan)
        (planScopeEndpointId plan)
        (planScopeEntityName plan)
        (planScopeEntityId plan)
  , "authority absence level: " <> absenceText (planAbsenceLevel plan)
  , "authority payload order: enum "
      <> named (planEnumName plan)
      <> " (enum "
      <> countText (enumIndex (planEnumId plan))
      <> ")"
  , "declared enum members: "
      <> Text.intercalate
        ", "
        [ valueEvidence (sourcedValue (planMemberName member)) (planMemberId member)
        | member <- planEnumMembers plan
        ]
  , "materialized authority ranking: "
      <> Text.intercalate
        ", "
        [ "rank " <> countText (planRankedRank ranked) <> " = "
            <> valueEvidence (planRankedName ranked) (planRankedId ranked)
        | ranked <- planRanking plan
        ]
  , "materialized bottom: " <> rankedEvidence (planRankBottom plan)
  , "privilege floor: " <> rankedEvidence (planRankTop plan)
  , "absent rank: " <> countText (planAbsentRank plan)
  , "case action: "
      <> named (planActionName plan)
      <> " (action "
      <> countText (actionIndex (planActionId plan))
      <> ")"
  , "case scope binding: " <> bindingEvidence (planCaseScopeBinding plan)
  , "principal mode: AuthenticatedOnly"
  , "parameter "
      <> countText (parameterIndex (planSubjectParameterId plan))
      <> ": "
      <> named (planSubjectParameterName plan)
      <> " : EntityRef "
      <> named (planSubjectEntityName plan)
  , "parameter "
      <> countText (parameterIndex (planScopeParameterId plan))
      <> ": "
      <> named (planScopeParameterName plan)
      <> " : EntityRef "
      <> named (planScopeEntityName plan)
  , "parameter "
      <> countText (parameterIndex (planPayloadParameterId plan))
      <> ": "
      <> named (planPayloadParameterName plan)
      <> " : Enum "
      <> named (planEnumName plan)
  , "allow policy: And(LessOrEqual[order optional "
      <> named (planEnumName plan)
      <> ", absence as bottom](Some(Enum["
      <> named (planEnumName plan)
      <> "."
      <> quotedName (planRankedName (planRankTop plan))
      <> "]), Lookup["
      <> named (planRelationName plan)
      <> "]("
      <> named (planSubjectEndpointName plan)
      <> " = Actor, "
      <> named (planScopeEndpointName plan)
      <> " = Argument["
      <> named (planScopeParameterName plan)
      <> "])), And(Not(Equal(Actor, Argument["
      <> named (planSubjectParameterName plan)
      <> "])), IsSome(Lookup["
      <> named (planRelationName plan)
      <> "]("
      <> named (planSubjectEndpointName plan)
      <> " = Argument["
      <> named (planSubjectParameterName plan)
      <> "], "
      <> named (planScopeEndpointName plan)
      <> " = Argument["
      <> named (planScopeParameterName plan)
      <> "]))))"
  , "effect: SetRelation["
      <> named (planRelationName plan)
      <> "]("
      <> Text.intercalate ", " (map bindingEvidence (planEffectBindings plan))
      <> ") payload Argument["
      <> named (planPayloadParameterName plan)
      <> "]"
  , "result: Done"
  ]
  where
    endpointEvidence endpointName endpointId entityName entityId =
      named endpointName
        <> " (endpoint "
        <> countText (endpointIndex endpointId)
        <> " of relation "
        <> countText (relationIndex (planRelationId plan))
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
        <> countText (enumIndex (planEnumId plan))
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
renderFiles :: NspeSupportPlan -> [WaspManagedFile]
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

generatedHeader :: Text -> NspeSupportPlan -> Text
generatedHeader commentLead plan =
  commentLead
    <> " Generated by mithril wasp generate from Mithril Core v0 model "
    <> named (planModelName plan)
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

specLines :: NspeSupportPlan -> [Text]
specLines plan =
  [ generatedHeader "//" plan
  , "//"
  , "// Wasp Confinement Profile v0: this specification is a managed input of the"
  , "// closed generated profile; mithril wasp check rejects any byte that differs"
  , "// from the regenerated bundle.  It declares exactly one route and page (the"
  , "// minimal client shell) and exactly one authenticated Action, " <> operation <> ","
  , "// lowered from the supported NoSelfPrivilegeEscalation case action shape of the"
  , "// authored action " <> named (planActionName plan) <> "."
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
       , "  title: " <> jsStringLiteral (sourcedValue (planModelName plan)) <> ","
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

schemaLines :: NspeSupportPlan -> [Text]
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
  , "// " <> subjectModel <> ": the subject entity " <> named (planSubjectEntityName plan)
      <> " (entity " <> countText (entityIndex (planSubjectEntityId plan)) <> ") — the"
  , "// authenticated principal and Wasp's auth user entity."
  , "model " <> subjectModel <> " {"
  , "  id          Int @id @default(autoincrement())"
  , "  authorities " <> authorityModel <> "[]"
  , "}"
  , ""
  , "// " <> scopeModel <> ": the scope entity " <> named (planScopeEntityName plan)
      <> " (entity " <> countText (entityIndex (planScopeEntityId plan)) <> ")."
  , "model " <> scopeModel <> " {"
  , "  id          Int @id @default(autoincrement())"
  , "  authorities " <> authorityModel <> "[]"
  , "}"
  , ""
  , "// " <> payloadEnum <> ": the authority payload enum " <> named (planEnumName plan)
      <> " (enum " <> countText (enumIndex (planEnumId plan)) <> "); value i"
  , "// of the enum is the value Value<i>, in declaration order:"
  , "//   " <> memberMapping <> "."
  , "// (The ranking is materialized in the generated Action, not here.)"
  , "enum " <> payloadEnum <> " {"
  ]
    <> ["  " <> memberTargetName (planMemberId member) | member <- planEnumMembers plan]
    <> [ "}"
       , ""
       , "// " <> authorityModel <> ": the authority relation " <> named (planRelationName plan)
           <> " (relation " <> countText (relationIndex (planRelationId plan)) <> "), identified"
       , "// by its endpoints — subjectId for the subject endpoint " <> named (planSubjectEndpointName plan)
           <> " (endpoint " <> countText (endpointIndex (planSubjectEndpointId plan)) <> ")"
       , "// and scopeId for the scope endpoint " <> named (planScopeEndpointName plan)
           <> " (endpoint " <> countText (endpointIndex (planScopeEndpointId plan)) <> ") — with"
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
        | member <- planEnumMembers plan
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
viteConfigLines plan =
  [ generatedHeader "//" plan
  , "import { defineConfig } from \"vite\";"
  , "import { wasp } from \"wasp/client/vite\";"
  , ""
  , "export default defineConfig({"
  , "  plugins: [wasp()],"
  , "});"
  ]

clientPageLines :: NspeSupportPlan -> [Text]
clientPageLines plan =
  [ generatedHeader "//" plan
  , "// The minimal static client shell Wasp requires; the generated Action is"
  , "// exercised over Wasp's real HTTP and authentication path, not from here."
  , "export function MainPage() {"
  , "  return ("
  , "    <main>"
  , "      <h1>{" <> jsStringLiteral ("Mithril Core v0 model " <> named (planModelName plan)) <> "}</h1>"
  , "      <p>{"
      <> jsStringLiteral
        ( "Wasp Confinement Profile v0 demonstrator: one authenticated Wasp Action, "
            <> targetOperation targetNames
            <> " (POST "
            <> targetRoute targetNames
            <> "), lowered from the supported NoSelfPrivilegeEscalation case action shape of "
            <> named (planActionName plan)
            <> "."
        )
      <> "}</p>"
  , "    </main>"
  , "  );"
  , "}"
  ]

operationLines :: NspeSupportPlan -> [Text]
operationLines plan =
  [ generatedHeader "//" plan
  , "//"
  , "// Wasp Confinement Profile v0: the one generated security-sensitive operation of"
  , "// this application — the NoSelfPrivilegeEscalation case action"
  , "// " <> named (planActionName plan) <> " (action " <> countText (actionIndex (planActionId plan))
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
       , "// models " <> subjectModel <> " (" <> named (planSubjectEntityName plan) <> ") and "
           <> scopeModel <> " (" <> named (planScopeEntityName plan) <> "); the"
       , "// authority relation " <> named (planRelationName plan) <> " is the Prisma model " <> authorityModel
       , "// identified by (" <> subjectIdField <> ", " <> scopeIdField <> "):"
       , "//   " <> subjectIdField <> " for the endpoint " <> named (planSubjectEndpointName plan) <> ","
       , "//   " <> scopeIdField <> " for the endpoint " <> named (planScopeEndpointName plan) <> ","
       , "// with the payload column " <> payloadField <> " of the enum " <> payloadEnum <> " ("
           <> named (planEnumName plan) <> ").  The arguments"
       , "//   " <> subjectArgument <> " carries the parameter " <> named (planSubjectParameterName plan) <> ","
       , "//   " <> scopeArgument <> " carries the parameter " <> named (planScopeParameterName plan) <> ","
       , "//   " <> payloadArgument <> " carries the parameter " <> named (planPayloadParameterName plan) <> ";"
       , "// absence of a tuple takes the absent rank below every member."
       , "import { HttpError, prisma } from \"wasp/server\";"
       , "import type { " <> operationType <> " } from \"wasp/server/operations\";"
       , ""
       , "// The authority payload enum " <> payloadEnum <> " (" <> named (planEnumName plan) <> "): the values in"
       , "// declaration order,"
       , "//   " <> memberMapping <> "."
       , "type Payload = " <> Text.intercalate " | " (map jsStringLiteral memberValues) <> ";"
       , "const payloadMembers: readonly string[] = [" <> Text.intercalate ", " (map jsStringLiteral memberValues) <> "];"
       , ""
       , "// The materialized ranking (rank 0 is the bottom ranked value):"
       , "//   " <> rankingMapping <> ";"
       , "// the privilege floor is the rank of " <> rankedTarget (planRankTop plan) <> " ("
           <> quotedName (planRankedName (planRankTop plan)) <> "), and an absent authority"
       , "// tuple takes the absent rank below every member (absence level "
           <> absenceText (planAbsenceLevel plan) <> ")."
       , "const payloadRank: Readonly<Record<Payload, number>> = { "
           <> Text.intercalate
             ", "
             [ jsStringLiteral (rankedTarget ranked) <> ": " <> countText (planRankedRank ranked)
             | ranked <- planRanking plan
             ]
           <> " };"
       , "const floorRank = " <> countText (planRankedRank (planRankTop plan)) <> ";"
       , "const absentRank = " <> countText (planAbsentRank plan) <> ";"
       , ""
       , "// Bounded deterministic retry of Serializable write conflicts (Prisma P2034)."
       , "const serializationAttempts = 3;"
       , ""
       , "// The action's arguments: " <> subjectArgument <> " carries " <> named (planSubjectParameterName plan)
           <> " : EntityRef " <> named (planSubjectEntityName plan) <> ","
       , "// " <> scopeArgument <> " carries " <> named (planScopeParameterName plan) <> " : EntityRef "
           <> named (planScopeEntityName plan) <> ", and " <> payloadArgument <> " carries"
       , "// " <> named (planPayloadParameterName plan) <> " : Enum " <> named (planEnumName plan) <> "."
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
           <> named (planSubjectEntityName plan) <> ")."
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
       , "          // Lookup[" <> named (planRelationName plan) <> "](" <> named (planSubjectEndpointName plan)
           <> " = Actor, " <> named (planScopeEndpointName plan) <> " = Argument[" <> named (planScopeParameterName plan) <> "]):"
       , "          // all mutable authorization state is read inside this Serializable transaction."
       , "          const actorTuple = await tx." <> accessor <> ".findUnique({"
       , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": actor, " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
       , "          });"
       , "          // Lookup[" <> named (planRelationName plan) <> "](" <> named (planSubjectEndpointName plan)
           <> " = Argument[" <> named (planSubjectParameterName plan) <> "], " <> named (planScopeEndpointName plan)
           <> " = Argument[" <> named (planScopeParameterName plan) <> "])."
       , "          const targetTuple = await tx." <> accessor <> ".findUnique({"
       , "            where: { " <> compoundKey <> ": { " <> subjectIdField <> ": args." <> subjectArgument <> ", " <> scopeIdField <> ": args." <> scopeArgument <> " } },"
       , "          });"
       , "          const actorRank = actorTuple === null ? absentRank : payloadRank[actorTuple." <> payloadField <> "];"
       , "          // And(LessOrEqual(Some(" <> quotedName (planRankedName (planRankTop plan)) <> "), actor authority), And(Not(Equal(Actor, "
           <> named (planSubjectParameterName plan) <> ")), IsSome(target authority)))."
       , "          const allowed = floorRank <= actorRank && (!(actor === args." <> subjectArgument <> ") && targetTuple !== null);"
       , "          if (!allowed) {"
       , "            throw new HttpError(403, \"forbidden\");"
       , "          }"
       , "          // SetRelation[" <> named (planRelationName plan) <> "](" <> named (planSubjectEndpointName plan)
           <> " = Argument[" <> named (planSubjectParameterName plan) <> "], " <> named (planScopeEndpointName plan)
           <> " = Argument[" <> named (planScopeParameterName plan) <> "]) payload Argument["
           <> named (planPayloadParameterName plan) <> "]."
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
    memberValues = [memberTargetName (planMemberId member) | member <- planEnumMembers plan]
    memberMapping =
      Text.intercalate
        ", "
        [ memberTargetName (planMemberId member) <> " = " <> named (planMemberName member)
        | member <- planEnumMembers plan
        ]
    rankedTarget ranked = memberTargetName (planRankedId ranked)
    rankingMapping =
      Text.intercalate
        ", "
        [ "rank " <> countText (planRankedRank ranked) <> " = " <> rankedTarget ranked
            <> " (" <> quotedName (planRankedName ranked) <> ")"
        | ranked <- planRanking plan
        ]

--------------------------------------------------------------------
-- The manifest: the explicit authored-to-target mapping
--------------------------------------------------------------------

manifestLines :: NspeSupportPlan -> [Text]
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
  , field "model" (jsStringLiteral (sourcedValue (planModelName plan)))
  , field "guarantee" (jsStringLiteral "NoSelfPrivilegeEscalation")
  , field "ownershipMarker" (jsStringLiteral (Text.pack ownershipMarkerPath))
  , field
      "caseAction"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planActionName plan)))
          , ("position", countText (actionIndex (planActionId plan)))
          , ("operation", jsStringLiteral (targetOperation targetNames))
          , ("operationType", jsStringLiteral (targetOperationType targetNames))
          , ("route", jsStringLiteral (targetRoute targetNames))
          , ("file", jsStringLiteral (Text.pack operationPath))
          ]
      )
  , field
      "subjectEntity"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planSubjectEntityName plan)))
          , ("position", countText (entityIndex (planSubjectEntityId plan)))
          , ("model", jsStringLiteral (targetSubjectModel targetNames))
          ]
      )
  , field
      "scopeEntity"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planScopeEntityName plan)))
          , ("position", countText (entityIndex (planScopeEntityId plan)))
          , ("model", jsStringLiteral (targetScopeModel targetNames))
          ]
      )
  , field
      "authorityRelation"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planRelationName plan)))
          , ("position", countText (relationIndex (planRelationId plan)))
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
          [ ("authored", jsStringLiteral (sourcedValue (planSubjectEndpointName plan)))
          , ("position", countText (endpointIndex (planSubjectEndpointId plan)))
          , ("field", jsStringLiteral (targetSubjectField targetNames))
          , ("idField", jsStringLiteral (targetSubjectIdField targetNames))
          ]
      )
  , field
      "scopeEndpoint"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planScopeEndpointName plan)))
          , ("position", countText (endpointIndex (planScopeEndpointId plan)))
          , ("field", jsStringLiteral (targetScopeField targetNames))
          , ("idField", jsStringLiteral (targetScopeIdField targetNames))
          ]
      )
  , field
      "payloadEnum"
      ( object
          [ ("authored", jsStringLiteral (sourcedValue (planEnumName plan)))
          , ("position", countText (enumIndex (planEnumId plan)))
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
          | member <- planEnumMembers plan
          ]
      )
  , field "ranking" (array (map rankedObject (planRanking plan)))
  , field "bottom" (rankedObject (planRankBottom plan))
  , field "floor" (rankedObject (planRankTop plan))
  , field
      "absence"
      ( object
          [ ("level", jsStringLiteral (absenceText (planAbsenceLevel plan)))
          , ("rank", countText (planAbsentRank plan))
          ]
      )
  , field
      "parameters"
      ( array
          [ parameterObject "subject" (planSubjectParameterName plan) (planSubjectParameterId plan) (targetSubjectArgument targetNames)
          , parameterObject "scope" (planScopeParameterName plan) (planScopeParameterId plan) (targetScopeArgument targetNames)
          , parameterObject "payload" (planPayloadParameterName plan) (planPayloadParameterId plan) (targetPayloadArgument targetNames)
          ]
      )
  , field "effectBindings" (array (map bindingObject (planEffectBindings plan)))
  , field "caseScopeBinding" (bindingObject (planCaseScopeBinding plan))
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
