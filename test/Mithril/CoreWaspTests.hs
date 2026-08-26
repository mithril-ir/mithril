{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Checks over the Wasp target boundary: "Mithril.Core.Wasp" (the
-- pure bundle renderer and the pure confinement checker),
-- "Mithril.Core.Internal.WaspFilesystem" (the root validation and the
-- whole-directory installation with its fault-injection seam), and
-- "Mithril.Command.Wasp" (the effectful generate\/check boundary).
--
-- The groups:
--
-- 1. /Golden and determinism./  The supported fixture renders to the
--    same bundle twice, from a relocated copy of the Core file, and —
--    through the real generate command — into two different roots
--    with byte-identical files; the committed fixture
--    @test\/fixtures\/wasp-acme@ is exactly the fresh bundle; the
--    closed path inventory is pinned literally and is the profile's
--    fixed inventory; every file is UTF-8 with Unix line endings, no
--    tabs, and one final newline; the manifest parses with its
--    pinned authored-to-target mapping; the generated Action carries
--    the pinned semantics literally; no rendered byte claims
--    verification; and the fixed target names are pinned against
--    closed lists of Prisma scalar and reserved names, Wasp's
--    injected auth models, and JavaScript\/TypeScript reserved words.
--
-- 2. /One shared plan./  The emitter is the composition of the shared
--    support gate and the (total) plan renderer; the unsafe variant
--    and the canonical Acme document are refused with exactly the
--    verifier's reasons; and an independent oracle — the declarations
--    read straight out of the authored JSON — agrees with both the
--    generated Agda module and the Wasp manifest, so the verifier and
--    the emitter provably selected the same declarations.
--
-- 3. /Plan-consumption inventory./  Every field of the shared plan is
--    classified (consumed by both consumers, Wasp-only, verifier-only,
--    or derived evidence), and every Wasp-relevant field has
--    field-specific mutations whose expected output fragments are
--    absent from the base bundle and present in the mutated one.
--
-- 4. /Renamed models./  Each committed rename variant (a scope entity
--    named @String@, Wasp's auth model names, reserved words, acronyms
--    and digits, boundary leading characters, authored names spelled
--    like the target names, and a declaration order differing from
--    the ranking) renders with the fixed inventory and fixed
--    identifiers, its authored names confined to comments, string
--    metadata, and the manifest; hostile plan names cannot inject
--    syntax.
--
-- 5. /Pure confinement./  The exact snapshot is confined; missing,
--    altered, hard-linked, linked, and unexpected entries are
--    rejected with pinned labels; the ownership rule accepts empty
--    and owned roots (altered or missing managed files included) and
--    refuses unmarked roots, unmanaged paths, links, and hard links;
--    duplicate, aliased, absolute, and dot-relative snapshot entries
--    are rejected with pinned diagnostics independent of input order.
--
-- 6. /Confinement attack matrix./  Through the real filesystem
--    boundary, a fresh copy of the fixture is mutated one bypass at a
--    time and each attack fails @check@ with exactly its sorted,
--    deduplicated diagnostics — including hard-linked root and nested
--    files.
--
-- 7. /Installation./  Through the installation seam with injected
--    faults and through the command: absent, empty, valid, altered,
--    partial, unmanaged, unmarked, read-only, regular-file, symlink,
--    stale-staging, failed-swap (with and without a successful
--    rollback), symlink-before-revalidation, and root- and
--    parent-replacement destinations each leave the complete old or
--    the complete new bundle; an occupied backup sibling path — an
--    empty or nonempty directory, a regular file, a symbolic link
--    (dangling or not), whether present before staging or appearing
--    between staging and the pre-rename revalidation — refuses the
--    installation with the old root and the occupying entry untouched
--    byte-for-byte and type-for-type; the staging directory and the
--    installed root carry the private permission bits 0700 even under
--    umask 000 (and a regeneration over a wide-mode owned root
--    installs a private root); lexical dot, dot-dot, empty,
--    trailing-separator, and ancestor-link paths are refused;
--    regeneration after a supported rename and after a meaningful
--    byte change succeeds without any manual step.
--
-- 8. /Command outcomes./  Reports, exit classifications, and the
--    unsupported\/invalid paths through the command.
module Mithril.CoreWaspTests
  ( tests
  ) where

import Control.Exception (SomeException, finally, try)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import System.Directory
  ( canonicalizePath
  , copyFile
  , createDirectory
  , createDirectoryIfMissing
  , createDirectoryLink
  , createFileLink
  , doesDirectoryExist
  , doesPathExist
  , getPermissions
  , getSymbolicLinkTarget
  , getTemporaryDirectory
  , listDirectory
  , pathIsSymbolicLink
  , removeDirectoryRecursive
  , removeFile
  , renameDirectory
  , setPermissions
  , writable
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Posix.Files (createLink, setFileCreationMask, setFileMode)
import System.Posix.User (getEffectiveUserID)

import Mithril.Command.Validate (ValidateFileError (..), validateCoreFile)
import Mithril.Command.Wasp
  ( WaspFileError (..)
  , WaspFileSuccess (..)
  , WaspReport (..)
  , checkWaspApp
  , generateWaspApp
  , renderWaspFailure
  , renderWaspSuccess
  , waspFailureExitCode
  , waspSuccessExitCode
  )
import Mithril.Core.Internal.Document (CoreDocument (..))
import qualified Mithril.Core.Internal.Normalized as N
import Mithril.Core.Internal.NspeSupportPlan
  ( NspeSupportPlan (..)
  , PlanBinding (..)
  , PlanEnumMember (..)
  , PlanRankedMember (..)
  , PlanRefusal (..)
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
import Mithril.Core.Internal.Verify (renderObligationModule)
import Mithril.Core.Internal.Wasp
  ( WaspRenderingRefusal (..)
  , WaspTargetNames (..)
  , camelToKebabCase
  , jsStringLiteral
  , managedPaths
  , memberTargetName
  , operationPath
  , ownershipMarkerBytes
  , ownershipMarkerPath
  , renderBundleFromModel
  , renderBundleFromPlan
  , targetNames
  )
import Mithril.Core.Internal.WaspFilesystem
  ( InstallFailure (..)
  , InstallHooks (..)
  , backupPathOf
  , directoryPermissionBits
  , installBundle
  , lexicalRootPath
  , noInstallHooks
  , privateDirectoryMode
  , stagingPathOf
  )
import Mithril.Core.Normalization (Normalized, normalizeCoreDocument)
import Mithril.Core.Resolution (resolveCoreDocument)
import Mithril.Core.Typing (typecheckCoreDocument)
import Mithril.Core.Validation
  ( bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Core.Wasp
  ( ConfinementMode (..)
  , ConfinementViolation (..)
  , EntryKind (..)
  , RootEntry (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation (..)
  , WaspBundle
  , WaspBundleSummary (..)
  , WaspManagedFile (..)
  , WaspRenderingFailure (..)
  , checkWaspConfinement
  , renderWaspBundle
  , waspBundleFiles
  , waspBundleSummary
  )
import Mithril.Test (Check, check)

nspePath :: FilePath
nspePath = "test/fixtures/acme-nspe.mir.json"

unsafePath :: FilePath
unsafePath = "test/fixtures/acme-nspe-unsafe.mir.json"

acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

fixtureRoot :: FilePath
fixtureRoot = "test/fixtures/wasp-acme"

renameDirectoryPath :: FilePath
renameDirectoryPath = "test/fixtures/wasp-renames"

operationFile :: FilePath
operationFile = "src/mithrilCaseAction.ts"

manifestFile :: FilePath
manifestFile = "mithril.manifest.json"

specFile :: FilePath
specFile = "main.wasp.ts"

schemaFile :: FilePath
schemaFile = "schema.prisma"

markerFile :: FilePath
markerFile = ".mithril-wasp-profile"

-- | The pinned closed path inventory of every bundle.
expectedInventory :: [FilePath]
expectedInventory =
  [ ".gitignore"
  , ".mithril-wasp-profile"
  , ".npmrc"
  , ".wasproot"
  , "main.wasp.ts"
  , "mithril.manifest.json"
  , "package.json"
  , "schema.prisma"
  , "src/MainPage.tsx"
  , "src/mithrilCaseAction.ts"
  , "tsconfig.json"
  , "tsconfig.src.json"
  , "tsconfig.wasp.json"
  , "vite.config.ts"
  ]

-- | All Wasp checks.
tests :: IO [Check]
tests = do
  nspeBytes <- ByteString.readFile nspePath
  unsafeBytes <- ByteString.readFile unsafePath
  acmeBytes <- ByteString.readFile acmePath
  case (pipelineDocument nspeBytes, pipelineModel nspeBytes) of
    (Just baseDocument, Just baseModel) ->
      case renderWaspBundle baseDocument of
        Left _ ->
          pure [check "the supported fixture renders a Wasp bundle (prerequisite)" False]
        Right baseBundle -> do
          goldenChecks <- goldenAndDeterminismChecks baseDocument baseBundle
          renamedChecks <- renamedModelChecks baseModel baseBundle
          attackChecks <- confinementAttackChecks
          installChecks <- installationChecks baseBundle
          commandChecks <- commandOutcomeChecks baseBundle
          pure $
            goldenChecks
              <> sharedPlanChecks nspeBytes unsafeBytes acmeBytes baseModel baseBundle
              <> planConsumptionChecks baseModel baseBundle
              <> renamedChecks
              <> pureConfinementChecks baseBundle
              <> attackChecks
              <> installChecks
              <> commandChecks
              <> renderingChecks baseBundle
    _ ->
      pure
        [ check
            "the supported fixture normalizes through the public pipeline (prerequisite)"
            False
        ]

--------------------------------------------------------------------
-- Pipeline helpers
--------------------------------------------------------------------

pipelineDocument :: ByteString -> Maybe (CoreDocument Normalized)
pipelineDocument bytes = do
  schema <- rightMaybe bundledCoreSchema
  parsed <- rightMaybe (parseCoreDocument bytes)
  valid <- rightMaybe (validateCoreDocument schema parsed)
  resolved <- rightMaybe (resolveCoreDocument valid)
  typed <- rightMaybe (typecheckCoreDocument resolved)
  rightMaybe (normalizeCoreDocument typed)

pipelineModel :: ByteString -> Maybe N.Model
pipelineModel bytes = do
  document <- pipelineDocument bytes
  case document of
    CoreDocument model -> Just model

rightMaybe :: Either e a -> Maybe a
rightMaybe = either (const Nothing) Just

bundleBytes :: WaspBundle -> [(FilePath, ByteString)]
bundleBytes bundle = [(managedPath file, managedBytes file) | file <- waspBundleFiles bundle]

fileOf :: WaspBundle -> FilePath -> ByteString
fileOf bundle path =
  case [managedBytes file | file <- waspBundleFiles bundle, managedPath file == path] of
    bytes : _ -> bytes
    [] -> ""

textOf :: WaspBundle -> FilePath -> Text
textOf bundle path = Encoding.decodeUtf8 (fileOf bundle path)

dedupe :: Ord a => [a] -> [a]
dedupe = map NonEmpty.head . NonEmpty.group . sort

--------------------------------------------------------------------
-- Group 1: golden and determinism
--------------------------------------------------------------------

goldenAndDeterminismChecks
  :: CoreDocument Normalized -> WaspBundle -> IO [Check]
goldenAndDeterminismChecks baseDocument baseBundle = do
  relocated <- withScratchDirectory $ \scratch -> do
    let copyTarget = scratch </> "relocated.mir.json"
    copyFile nspePath copyTarget
    copiedBytes <- ByteString.readFile copyTarget
    pure (fmap renderWaspBundle (pipelineDocument copiedBytes))
  onDisk <- snapshotDirectory fixtureRoot
  generatedTwice <- withScratchDirectory $ \scratch -> do
    first <- generateWaspApp nspePath (scratch </> "first")
    createDirectory (scratch </> "nested")
    second <- generateWaspApp nspePath (scratch </> "nested" </> "second")
    firstFiles <- snapshotDirectory (scratch </> "first")
    secondFiles <- snapshotDirectory (scratch </> "nested" </> "second")
    pure (isGenerated first, isGenerated second, firstFiles, secondFiles)
  let (firstOk, secondOk, firstFiles, secondFiles) = generatedTwice
      manifest = Aeson.decodeStrict (fileOf baseBundle manifestFile) :: Maybe Value
      operation = textOf baseBundle operationFile
      spec = textOf baseBundle specFile
      schema = textOf baseBundle schemaFile
      packageJson = textOf baseBundle "package.json"
  pure
    [ check
        "rendering the same normalized document twice is byte-identical"
        (fmap bundleBytes (renderWaspBundle baseDocument) == Right (bundleBytes baseBundle))
    , check
        "a relocated copy of the Core file renders the identical bundle"
        (fmap (fmap bundleBytes) relocated == Just (Right (bundleBytes baseBundle)))
    , check
        "the committed fixture is exactly the fresh bundle (inventory and bytes)"
        (onDisk == bundleBytes baseBundle)
    , check
        "the closed path inventory is pinned and is the profile's fixed inventory"
        ( map managedPath (waspBundleFiles baseBundle) == expectedInventory
            && managedPaths == expectedInventory
            && operationPath == operationFile
            && ownershipMarkerPath == markerFile
        )
    , check
        "the inventory is sorted and pairwise distinct"
        ( let paths = map managedPath (waspBundleFiles baseBundle)
           in paths == sort paths && length paths == length (dedupe paths)
        )
    , check
        "two generations into different roots produce byte-identical files"
        (firstOk && secondOk && firstFiles == secondFiles && firstFiles == bundleBytes baseBundle)
    , check
        "every managed file is UTF-8 with Unix line endings, no tabs, and one final newline"
        ( all
            ( \(_, bytes) ->
                case Encoding.decodeUtf8' bytes of
                  Left _ -> False
                  Right text ->
                    "\n" `Text.isSuffixOf` text
                      && not ("\n\n" `Text.isSuffixOf` text)
                      && not ("\r" `Text.isInfixOf` text)
                      && not ("\t" `Text.isInfixOf` text)
            )
            (bundleBytes baseBundle)
        )
    , check
        "no managed file carries a temporary path or build path"
        ( all
            (\(_, bytes) -> not (any (`ByteString.isInfixOf` bytes) ["/tmp", "dist-newstyle"]))
            (bundleBytes baseBundle)
        )
    , check
        "no rendered byte claims verification (the pure renderer attests supported-shape lowering only)"
        ( all
            (\(_, bytes) -> not ("verif" `Text.isInfixOf` Text.toLower (Encoding.decodeUtf8Lenient bytes)))
            (bundleBytes baseBundle)
        )
    , check
        "the ownership marker is a managed file with fixed bytes"
        ( fileOf baseBundle markerFile == ownershipMarkerBytes
            && "mithril-wasp-bundle wasp-confinement-profile-v0\n" `ByteString.isSuffixOf` ownershipMarkerBytes
        )
    , check
        "the manifest parses as JSON with the pinned scalar fields"
        ( case manifest of
            Just (Object members) ->
              lookupText "format" members == Just "mithril-wasp-bundle"
                && lookupText "formatVersion" members == Just "0"
                && lookupText "profile" members == Just "wasp-confinement-profile-v0"
                && lookupText "wasp" members == Just "0.25.0"
                && lookupText "database" members == Just "postgresql"
                && lookupText "prisma" members == Just "5.19.1"
                && lookupText "model" members == Just "Acme"
                && lookupText "guarantee" members == Just "NoSelfPrivilegeEscalation"
                && lookupText "ownershipMarker" members == Just ".mithril-wasp-profile"
                && KeyMap.lookup "managedFiles" members
                  == Just (toJSONStrings (filter (/= manifestFile) expectedInventory))
            _ -> False
        )
    , check
        "the manifest states every authored-to-target mapping explicitly"
        ( all
            (`Text.isInfixOf` textOf baseBundle manifestFile)
            [ "\"caseAction\": { \"authored\": \"Membership.changeRole\", \"position\": 4, \"operation\": \"mithrilCaseAction\", \"operationType\": \"MithrilCaseAction\", \"route\": \"/operations/mithril-case-action\", \"file\": \"src/mithrilCaseAction.ts\" }"
            , "\"subjectEntity\": { \"authored\": \"User\", \"position\": 0, \"model\": \"MithrilSubject\" }"
            , "\"scopeEntity\": { \"authored\": \"Organization\", \"position\": 1, \"model\": \"MithrilScope\" }"
            , "\"authorityRelation\": { \"authored\": \"Membership\", \"position\": 0, \"model\": \"MithrilAuthority\", \"accessor\": \"mithrilAuthority\", \"identity\": [\"subjectId\", \"scopeId\"], \"payloadColumn\": \"payload\" }"
            , "\"subjectEndpoint\": { \"authored\": \"user\", \"position\": 0, \"field\": \"subject\", \"idField\": \"subjectId\" }"
            , "\"scopeEndpoint\": { \"authored\": \"organization\", \"position\": 1, \"field\": \"scope\", \"idField\": \"scopeId\" }"
            , "\"payloadEnum\": { \"authored\": \"MembershipRole\", \"position\": 0, \"enum\": \"MithrilPayload\" }"
            , "\"members\": [{ \"authored\": \"Member\", \"position\": 0, \"value\": \"Value0\" }, { \"authored\": \"Admin\", \"position\": 1, \"value\": \"Value1\" }]"
            , "\"ranking\": [{ \"rank\": 0, \"authored\": \"Member\", \"position\": 0, \"value\": \"Value0\" }, { \"rank\": 1, \"authored\": \"Admin\", \"position\": 1, \"value\": \"Value1\" }]"
            , "\"bottom\": { \"rank\": 0, \"authored\": \"Member\", \"position\": 0, \"value\": \"Value0\" }"
            , "\"floor\": { \"rank\": 1, \"authored\": \"Admin\", \"position\": 1, \"value\": \"Value1\" }"
            , "\"absence\": { \"level\": \"Bottom\", \"rank\": -1 }"
            , "\"parameters\": [{ \"role\": \"subject\", \"authored\": \"target\", \"position\": 0, \"argument\": \"subject\" }, { \"role\": \"scope\", \"authored\": \"organization\", \"position\": 1, \"argument\": \"scope\" }, { \"role\": \"payload\", \"authored\": \"newRole\", \"position\": 2, \"argument\": \"payload\" }]"
            , "\"effectBindings\": [{ \"endpoint\": \"user\", \"endpointPosition\": 0, \"parameter\": \"target\", \"parameterPosition\": 0 }, { \"endpoint\": \"organization\", \"endpointPosition\": 1, \"parameter\": \"organization\", \"parameterPosition\": 1 }]"
            , "\"caseScopeBinding\": { \"endpoint\": \"organization\", \"endpointPosition\": 1, \"parameter\": \"organization\", \"parameterPosition\": 1 }"
            ]
        )
    , check
        "the generated Action pins Wasp authentication, the Serializable transaction, the bounded retry, and the stable responses"
        ( all
            (`Text.isInfixOf` operation)
            [ "import { HttpError, prisma } from \"wasp/server\";"
            , "import type { MithrilCaseAction } from \"wasp/server/operations\";"
            , "if (!context.user) {"
            , "throw new HttpError(401, \"authentication required\");"
            , "const actor: number = context.user.id;"
            , "throw new HttpError(400, \"invalid arguments\");"
            , "await prisma.$transaction("
            , "{ isolationLevel: \"Serializable\" },"
            , "const serializationAttempts = 3;"
            , ".code === \"P2034\""
            , "throw new HttpError(409, \"conflict\");"
            , "throw new HttpError(500, \"internal error\");"
            , "throw new HttpError(403, \"forbidden\");"
            , "type Payload = \"Value0\" | \"Value1\";"
            , "const payloadRank: Readonly<Record<Payload, number>> = { \"Value0\": 0, \"Value1\": 1 };"
            , "const floorRank = 1;"
            , "const absentRank = -1;"
            , "type Args = { subject: number; scope: number; payload: Payload };"
            , "const allowed = floorRank <= actorRank && (!(actor === args.subject) && targetTuple !== null);"
            , "tx.mithrilAuthority.findUnique({"
            , "subjectId_scopeId: { subjectId: actor, scopeId: args.scope }"
            , "tx.mithrilAuthority.update({"
            , "data: { payload: args.payload },"
            , "export const mithrilCaseAction: MithrilCaseAction<Args, void> ="
            ]
        )
    , check
        "the generated Action uses no raw SQL, no Prisma client import, and no dynamic code"
        ( not
            ( any
                (`Text.isInfixOf` operation)
                ["$queryRaw", "$executeRaw", "@prisma/client", "eval(", "Function(", "import(", "require(", "child_process"]
            )
        )
    , check
        "only the generated Action imports prisma from wasp/server"
        ( [ path
          | (path, bytes) <- bundleBytes baseBundle
          , "wasp/server" `ByteString.isInfixOf` bytes
          ]
            == [operationFile]
        )
    , check
        "the specification declares exactly one Action, one route, auth, and Wasp 0.25.0"
        ( Text.count "action(" spec == 1
            && Text.count "route(" spec == 1
            && "wasp: { version: \"0.25.0\" }" `Text.isInfixOf` spec
            && "usernameAndPassword: {}" `Text.isInfixOf` spec
            && "userEntity: \"MithrilSubject\"" `Text.isInfixOf` spec
            && "action(mithrilCaseAction, { entities: [\"MithrilAuthority\"], auth: true })" `Text.isInfixOf` spec
            && not (any (`Text.isInfixOf` spec) ["query(", "api(", "crud(", "job(", "apiNamespace(", "setupFn", "middlewareConfigFn", "seeds"])
        )
    , check
        "the Prisma schema pins PostgreSQL, the three fixed models, the composite identity, and the enum in declaration order"
        ( all
            (`Text.isInfixOf` schema)
            [ "provider = \"postgresql\""
            , "model MithrilSubject {"
            , "model MithrilScope {"
            , "model MithrilAuthority {"
            , "enum MithrilPayload {\n  Value0\n  Value1\n}"
            , "@@id([subjectId, scopeId])"
            , "payload   MithrilPayload"
            ]
        )
    , check
        "the dependency configuration adds no database client and pins Wasp's Prisma and TypeScript"
        ( all
            (`Text.isInfixOf` packageJson)
            ["\"prisma\": \"5.19.1\"", "\"typescript\": \"6.0.3\"", "\"@wasp.sh/spec\": \"file:.wasp/spec/\""]
            && not (any (`Text.isInfixOf` packageJson) ["@prisma/client", "\"pg\"", "knex", "typeorm"])
        )
    , check
        "the summary reports the authored names, the fixed operation and route, and the inventory"
        ( waspBundleSummary baseBundle
            == WaspBundleSummary
              { summaryModelName = "Acme"
              , summaryGuarantee = "NoSelfPrivilegeEscalation"
              , summaryCaseAction = "Membership.changeRole"
              , summaryOperation = "mithrilCaseAction"
              , summaryRoute = "/operations/mithril-case-action"
              , summaryManagedPaths = expectedInventory
              }
        )
    , check
        "the fixed target names are pinned"
        ( targetNames
            == WaspTargetNames
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
              , targetOperation = "mithrilCaseAction"
              , targetOperationType = "MithrilCaseAction"
              , targetRoute = "/operations/mithril-case-action"
              , targetSubjectArgument = "subject"
              , targetScopeArgument = "scope"
              , targetPayloadArgument = "payload"
              , targetAppName = "mithrilWaspApp"
              }
            && memberTargetName (EnumValueId (EnumId 0) 0) == "Value0"
            && memberTargetName (EnumValueId (EnumId 3) 7) == "Value7"
        )
    , check
        "the fixed target names avoid Prisma scalar and reserved names, Wasp's auth models, and JavaScript/TypeScript reserved words, and are distinct per namespace"
        ( all (`notElem` forbiddenTargetNames) targetIdentifiers
            && all (`notElem` forbiddenTargetNames) [memberTargetName (EnumValueId (EnumId 0) n) | n <- [0 .. 9]]
            && distinct prismaTypeNames
            && distinct authorityFieldNames
            && distinct argumentNames
            && distinct
              [ targetOperation targetNames, targetOperationType targetNames, "Payload", "Args"
              , "HttpError", "prisma", "payloadMembers", "payloadRank", "floorRank", "absentRank"
              , "serializationAttempts", "isEntityReference", "isPayload", "parseArgs"
              , "isSerializationConflict", "MainPage"
              ]
        )
    , check
        "the lowering helpers are pinned"
        ( camelToKebabCase "mithrilCaseAction" == "mithril-case-action"
            && camelToKebabCase "changeHTTPRole" == "change-httprole"
            && camelToKebabCase "x" == "x"
            && jsStringLiteral "a\"b\\c\nd\x2028" == "\"a\\\"b\\\\c\\nd\\u2028\""
            && jsStringLiteral "\ESC" == "\"\\u001b\""
        )
    ]
  where
    lookupText name members =
      case KeyMap.lookup (Key.fromText name) members of
        Just (String text) -> Just text
        _ -> Nothing
    toJSONStrings = Aeson.toJSON . map Text.pack
    isGenerated outcome =
      case outcome of
        Right (WaspGenerated _) -> True
        _ -> False
    distinct names = length names == length (dedupe names)
    prismaTypeNames =
      [ targetSubjectModel targetNames, targetScopeModel targetNames
      , targetAuthorityModel targetNames, targetPayloadEnum targetNames
      ]
    authorityFieldNames =
      [ targetSubjectIdField targetNames, targetScopeIdField targetNames
      , targetPayloadField targetNames, targetSubjectField targetNames
      , targetScopeField targetNames
      ]
    argumentNames =
      [ targetSubjectArgument targetNames, targetScopeArgument targetNames
      , targetPayloadArgument targetNames
      ]
    targetIdentifiers =
      prismaTypeNames
        <> authorityFieldNames
        <> argumentNames
        <> [ targetAuthorityAccessor targetNames, targetBackField targetNames
           , targetCompoundKey targetNames, targetOperation targetNames
           , targetOperationType targetNames, targetAppName targetNames
           ]

-- | The closed lists no fixed target name may fall into: Prisma's
-- scalar type names, Prisma's reserved names, Wasp's injected auth
-- models, and JavaScript/TypeScript reserved and contextual words.
forbiddenTargetNames :: [Text]
forbiddenTargetNames =
  [ "String", "Boolean", "Int", "BigInt", "Float", "Decimal", "DateTime", "Json", "Bytes", "Unsupported"
  , "Prisma", "PrismaClient", "PrismaPromise", "Enumerable", "Model"
  , "Auth", "AuthIdentity", "Session"
  , "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do"
  , "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import"
  , "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true"
  , "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "implements"
  , "interface", "package", "private", "protected", "public", "await", "arguments", "eval"
  , "undefined", "NaN", "Infinity", "async", "of", "as", "from", "type", "get", "set"
  , "constructor", "prototype", "Object", "Function", "Symbol", "Array", "Number"
  ]

--------------------------------------------------------------------
-- Group 2: one shared plan, with an independent oracle
--------------------------------------------------------------------

sharedPlanChecks
  :: ByteString -> ByteString -> ByteString -> N.Model -> WaspBundle -> [Check]
sharedPlanChecks nspeBytes unsafeBytes acmeBytes baseModel baseBundle =
  [ check
      "the emitter is the composition of the shared gate and the total plan renderer"
      ( fmap bundleBytes (renderBundleFromModel baseModel)
          == Right (bundleBytes baseBundle)
          && case supportPlan baseModel of
            Right plan -> bundleBytes (renderBundleFromPlan plan) == bundleBytes baseBundle
            Left _ -> False
      )
  , check
      "the unsafe variant is refused by the emitter with exactly the verifier's reasons"
      ( case (pipelineModel unsafeBytes, pipelineDocument unsafeBytes) of
          (Just model, Just document) ->
            case supportPlan model of
              Left (PlanUnsupported reasons) ->
                renderWaspBundle document == Left (WaspRenderingUnsupported reasons)
                  && NonEmpty.toList reasons
                    == [ UnsupportedReason
                           ["actions", "4", "allow", "right"]
                           "the second operand of the allow policy must itself be the conjunction And(actor/subject guard, subject membership)"
                       ]
              _ -> False
          _ -> False
      )
  , check
      "the canonical Acme document is refused by the emitter with exactly the verifier's reasons"
      ( case (pipelineModel acmeBytes, pipelineDocument acmeBytes) of
          (Just model, Just document) ->
            case supportPlan model of
              Left (PlanUnsupported reasons) ->
                renderWaspBundle document == Left (WaspRenderingUnsupported reasons)
                  && length reasons == 3
              _ -> False
          _ -> False
      )
  , check
      "a model with no guarantees is refused, never rendered vacuously"
      ( case renderBundleFromModel baseModel {N.modelGuarantees = []} of
          Left (RenderUnsupported reasons) ->
            NonEmpty.toList reasons
              == [ UnsupportedReason
                     ["guarantees"]
                     "the document selects no guarantee obligation, and an empty selection is never vacuously verified"
                 ]
          _ -> False
      )
  , check
      "a forged model refuses the emitter with the gate's exact invariant, before any lowering"
      ( case renderBundleFromModel (forgeEnumIdentity baseModel) of
          Left (RenderInvariant violations) ->
            NonEmpty.toList violations
              == [ VerifierInvariantViolation
                     ["guarantees", "0", "authority", "payloadOrder"]
                     "this referenced enum's stored identity is not the canonical identity of its declaration position"
                 ]
          _ -> False
      )
  , check
      "the authored JSON, the generated Agda module, and the Wasp manifest name the same declarations (independent oracle)"
      ( case (Aeson.decodeStrict nspeBytes, supportPlan baseModel) of
          (Just (Object document), Right plan) ->
            let oracle = jsonOracle document
                agda = renderObligationModule plan
                manifest = textOf baseBundle manifestFile
             in case oracle of
                  Just facts ->
                    all
                      (`Text.isInfixOf` agda)
                      [ "-- model: " <> quoted (oracleModel facts)
                      , "-- authority relation: " <> quoted (oracleRelation facts) <> " (relation " <> shown (oracleRelationIndex facts) <> ")"
                      , "-- authority subject endpoint: " <> quoted (oracleSubjectEndpoint facts)
                          <> " (endpoint 0 of relation " <> shown (oracleRelationIndex facts) <> "), entity "
                          <> quoted (oracleSubjectEntity facts) <> " (entity " <> shown (oracleSubjectEntityIndex facts) <> ")"
                      , "-- authority scope endpoint: " <> quoted (oracleScopeEndpoint facts)
                          <> " (endpoint 1 of relation " <> shown (oracleRelationIndex facts) <> "), entity "
                          <> quoted (oracleScopeEntity facts) <> " (entity " <> shown (oracleScopeEntityIndex facts) <> ")"
                      , "-- authority payload order: enum " <> quoted (oracleEnum facts) <> " (enum " <> shown (oracleEnumIndex facts) <> ")"
                      , "-- case action: " <> quoted (oracleAction facts) <> " (action " <> shown (oracleActionIndex facts) <> ")"
                      , "-- parameter 0: " <> quoted (oracleParameters facts !! 0) <> " : EntityRef " <> quoted (oracleSubjectEntity facts)
                      , "-- parameter 1: " <> quoted (oracleParameters facts !! 1) <> " : EntityRef " <> quoted (oracleScopeEntity facts)
                      , "-- parameter 2: " <> quoted (oracleParameters facts !! 2) <> " : Enum " <> quoted (oracleEnum facts)
                      , "rank 0 = " <> quoted (oracleOrder facts !! 0)
                      , "rank 1 = " <> quoted (oracleOrder facts !! 1)
                      ]
                      && all
                        (`Text.isInfixOf` manifest)
                        [ "\"model\": " <> jsStringLiteral (oracleModel facts) <> ","
                        , "\"caseAction\": { \"authored\": " <> jsStringLiteral (oracleAction facts) <> ", \"position\": " <> shown (oracleActionIndex facts)
                        , "\"subjectEntity\": { \"authored\": " <> jsStringLiteral (oracleSubjectEntity facts) <> ", \"position\": " <> shown (oracleSubjectEntityIndex facts)
                        , "\"scopeEntity\": { \"authored\": " <> jsStringLiteral (oracleScopeEntity facts) <> ", \"position\": " <> shown (oracleScopeEntityIndex facts)
                        , "\"authorityRelation\": { \"authored\": " <> jsStringLiteral (oracleRelation facts) <> ", \"position\": " <> shown (oracleRelationIndex facts)
                        , "\"subjectEndpoint\": { \"authored\": " <> jsStringLiteral (oracleSubjectEndpoint facts) <> ", \"position\": 0"
                        , "\"scopeEndpoint\": { \"authored\": " <> jsStringLiteral (oracleScopeEndpoint facts) <> ", \"position\": 1"
                        , "\"payloadEnum\": { \"authored\": " <> jsStringLiteral (oracleEnum facts) <> ", \"position\": " <> shown (oracleEnumIndex facts)
                        , "\"members\": [" <> Text.intercalate ", " [ "{ \"authored\": " <> jsStringLiteral name <> ", \"position\": " <> shown position <> ", \"value\": \"Value" <> shown position <> "\" }" | (position, name) <- zip [0 :: Int ..] (oracleValues facts)] <> "]"
                        , "\"bottom\": { \"rank\": 0, \"authored\": " <> jsStringLiteral (oracleOrder facts !! 0)
                        , "\"floor\": { \"rank\": 1, \"authored\": " <> jsStringLiteral (oracleOrder facts !! 1)
                        , "\"parameters\": [" <> Text.intercalate ", " [ "{ \"role\": " <> jsStringLiteral role <> ", \"authored\": " <> jsStringLiteral name <> ", \"position\": " <> shown position <> ", \"argument\": " <> jsStringLiteral role <> " }" | (position, role, name) <- zip3 [0 :: Int ..] ["subject", "scope", "payload"] (oracleParameters facts)] <> "]"
                        ]
                  Nothing -> False
          _ -> False
      )
  ]
  where
    forgeEnumIdentity model =
      model
        { N.modelEnums =
            [ if index == (0 :: Int) then definition {N.enumDefinitionId = EnumId 3} else definition
            | (index, definition) <- zip [0 ..] (N.modelEnums model)
            ]
        }
    quoted = Text.pack . show
    shown :: Int -> Text
    shown = Text.pack . show

-- | The declarations of the fixture as the authored JSON states them,
-- read without any Mithril code: the independent oracle.
data Oracle = Oracle
  { oracleModel :: Text
  , oracleSubjectEntity :: Text
  , oracleSubjectEntityIndex :: Int
  , oracleScopeEntity :: Text
  , oracleScopeEntityIndex :: Int
  , oracleRelation :: Text
  , oracleRelationIndex :: Int
  , oracleSubjectEndpoint :: Text
  , oracleScopeEndpoint :: Text
  , oracleEnum :: Text
  , oracleEnumIndex :: Int
  , oracleValues :: [Text]
  , oracleOrder :: [Text]
  , oracleAction :: Text
  , oracleActionIndex :: Int
  , oracleParameters :: [Text]
  }

jsonOracle :: KeyMap.KeyMap Value -> Maybe Oracle
jsonOracle document = do
  modelName <- text =<< KeyMap.lookup "name" document
  Object schema <- KeyMap.lookup "schema" document
  entities <- objects =<< KeyMap.lookup "entities" schema
  relations <- objects =<< KeyMap.lookup "relations" schema
  enums <- objects =<< KeyMap.lookup "enums" schema
  actions <- objects =<< KeyMap.lookup "actions" document
  guarantees <- objects =<< KeyMap.lookup "guarantees" document
  guarantee <- headMaybe guarantees
  Object authority <- KeyMap.lookup "authority" guarantee
  relationName <- text =<< KeyMap.lookup "relation" authority
  subjectEndpoint <- text =<< KeyMap.lookup "subjectEndpoint" authority
  scopeEndpoints <- strings =<< KeyMap.lookup "scopeEndpoints" authority
  scopeEndpoint <- headMaybe scopeEndpoints
  enumName <- text =<< KeyMap.lookup "payloadOrder" authority
  cases <- objects =<< KeyMap.lookup "cases" guarantee
  onlyCase <- headMaybe cases
  actionName <- text =<< KeyMap.lookup "action" onlyCase
  (relationIndex, relation) <- findNamed relationName relations
  endpoints <- objects =<< KeyMap.lookup "endpoints" relation
  subjectEntity <- endpointEntity subjectEndpoint endpoints
  scopeEntity <- endpointEntity scopeEndpoint endpoints
  (subjectEntityIndex, _) <- findNamed subjectEntity entities
  (scopeEntityIndex, _) <- findNamed scopeEntity entities
  (enumIndex, enumDefinition) <- findNamed enumName enums
  values <- strings =<< KeyMap.lookup "values" enumDefinition
  order <- strings =<< KeyMap.lookup "order" enumDefinition
  (actionIndex, action) <- findNamed actionName actions
  parameters <- objects =<< KeyMap.lookup "parameters" action
  parameterNames <- mapM (\parameter -> text =<< KeyMap.lookup "name" parameter) parameters
  pure
    Oracle
      { oracleModel = modelName
      , oracleSubjectEntity = subjectEntity
      , oracleSubjectEntityIndex = subjectEntityIndex
      , oracleScopeEntity = scopeEntity
      , oracleScopeEntityIndex = scopeEntityIndex
      , oracleRelation = relationName
      , oracleRelationIndex = relationIndex
      , oracleSubjectEndpoint = subjectEndpoint
      , oracleScopeEndpoint = scopeEndpoint
      , oracleEnum = enumName
      , oracleEnumIndex = enumIndex
      , oracleValues = values
      , oracleOrder = order
      , oracleAction = actionName
      , oracleActionIndex = actionIndex
      , oracleParameters = parameterNames
      }
  where
    text value = case value of
      String t -> Just t
      _ -> Nothing
    objects value = case value of
      Array items -> mapM (\item -> case item of Object o -> Just o; _ -> Nothing) (foldr (:) [] items)
      _ -> Nothing
    strings value = case value of
      Array items -> mapM text (foldr (:) [] items)
      _ -> Nothing
    headMaybe list = case list of
      first : _ -> Just first
      [] -> Nothing
    findNamed name items =
      headMaybe
        [ (index, item)
        | (index, item) <- zip [0 ..] items
        , (text =<< KeyMap.lookup "name" item) == Just name
        ]
    endpointEntity endpointName endpoints =
      headMaybe
        [ entity
        | endpoint <- endpoints
        , (text =<< KeyMap.lookup "name" endpoint) == Just endpointName
        , Just entity <- [text =<< KeyMap.lookup "entity" endpoint]
        ]

--------------------------------------------------------------------
-- Group 3: the plan-consumption inventory
--------------------------------------------------------------------

-- | Who consumes a plan field.
data Consumer
  = ConsumedByBoth
  | WaspOnly
  | VerifierOnly
  | DerivedEvidence
  deriving (Eq, Show)

-- | The classification of every field of 'NspeSupportPlan'.
planFieldInventory :: [(String, Consumer)]
planFieldInventory =
  [ ("planModelName", ConsumedByBoth)
  , ("planRelationId", ConsumedByBoth)
  , ("planRelationName", ConsumedByBoth)
  , ("planSubjectEndpointId", ConsumedByBoth)
  , ("planSubjectEndpointName", ConsumedByBoth)
  , ("planSubjectEntityId", ConsumedByBoth)
  , ("planSubjectEntityName", ConsumedByBoth)
  , ("planScopeEndpointId", ConsumedByBoth)
  , ("planScopeEndpointName", ConsumedByBoth)
  , ("planScopeEntityId", ConsumedByBoth)
  , ("planScopeEntityName", ConsumedByBoth)
  , ("planAbsenceLevel", ConsumedByBoth)
  , ("planEnumId", ConsumedByBoth)
  , ("planEnumName", ConsumedByBoth)
  , ("planEnumMembers", WaspOnly)
  , ("planRanking", WaspOnly)
  , ("planRankBottom", ConsumedByBoth)
  , ("planRankTop", ConsumedByBoth)
  , ("planAbsentRank", WaspOnly)
  , ("planActionId", ConsumedByBoth)
  , ("planActionName", ConsumedByBoth)
  , ("planSubjectParameterId", ConsumedByBoth)
  , ("planSubjectParameterName", ConsumedByBoth)
  , ("planScopeParameterId", ConsumedByBoth)
  , ("planScopeParameterName", ConsumedByBoth)
  , ("planPayloadParameterId", ConsumedByBoth)
  , ("planPayloadParameterName", ConsumedByBoth)
  , ("planEffectBindings", WaspOnly)
  , ("planCaseScopeBinding", WaspOnly)
  ]

-- | One field-specific mutation: the field, the mutation, and the
-- output fragments (file, text) the mutated bundle must contain and
-- the base bundle must not.
type FieldMutation = (String, NspeSupportPlan -> NspeSupportPlan, [(FilePath, Text)])

planConsumptionChecks :: N.Model -> WaspBundle -> [Check]
planConsumptionChecks baseModel baseBundle =
  case supportPlan baseModel of
    Left _ -> [check "the supported fixture yields a plan (prerequisite)" False]
    Right basePlan ->
      [ check
          ("the plan-consumption inventory classifies every plan field (" <> show expectedFieldCount <> ")")
          (length planFieldInventory == expectedFieldCount && length (dedupe (map fst planFieldInventory)) == expectedFieldCount)
      , check
          "no plan field is verifier-only or unconsumed derived evidence, so every field is Wasp-relevant"
          (all (\(_, consumer) -> consumer `elem` [ConsumedByBoth, WaspOnly]) planFieldInventory)
      , check
          "every Wasp-relevant field has a field-specific mutation and every mutation names an inventoried field"
          ( let inventoried = map fst planFieldInventory
                mutated = dedupe [name | (name, _, _) <- fieldMutations]
             in filter (/= "planAbsenceLevel") inventoried `allElem` mutated
                  && mutated `allElem` inventoried
          )
      , check
          "the single-constructor absence level is rendered as evidence in the base bundle"
          ( "authority absence level: Bottom" `Text.isInfixOf` textOf baseBundle operationFile
              && "\"absence\": { \"level\": \"Bottom\"" `Text.isInfixOf` textOf baseBundle manifestFile
          )
      ]
        <> map (runMutation basePlan) fieldMutations
  where
    expectedFieldCount = 29
    allElem xs ys = all (`elem` ys) xs

    runMutation basePlan (name, mutate, fragments) =
      check ("plan consumption: " <> name <> " → " <> concatMap (\(path, fragment) -> path <> ":" <> Text.unpack (Text.take 40 fragment) <> "; ") fragments) $
        let mutated = renderBundleFromPlan (mutate basePlan)
         in not (null fragments)
              && all
                ( \(path, fragment) ->
                    fragment `Text.isInfixOf` textOf mutated path
                      && not (fragment `Text.isInfixOf` textOf baseBundle path)
                )
                fragments
              && bundleBytes mutated /= bundleBytes baseBundle
              && map managedPath (waspBundleFiles mutated) == expectedInventory

    rename located = located {sourcedValue = "Mutated"}

    fieldMutations :: [FieldMutation]
    fieldMutations =
      [ ( "planModelName"
        , \p -> p {planModelName = rename (planModelName p)}
        , [ (manifestFile, "\"model\": \"Mutated\",")
          , (specFile, "title: \"Mutated\",")
          , (operationFile, "//   model: \"Mutated\"")
          ]
        )
      , ( "planRelationId"
        , \p -> p {planRelationId = RelationId 7}
        , [ (operationFile, "authority relation: \"Membership\" (relation 7)")
          , (manifestFile, "\"authorityRelation\": { \"authored\": \"Membership\", \"position\": 7,")
          ]
        )
      , ( "planRelationName"
        , \p -> p {planRelationName = rename (planRelationName p)}
        , [ (operationFile, "authority relation: \"Mutated\" (relation 0)")
          , (manifestFile, "\"authorityRelation\": { \"authored\": \"Mutated\", \"position\": 0, \"model\": \"MithrilAuthority\"")
          ]
        )
      , ( "planSubjectEndpointId"
        , \p -> p {planSubjectEndpointId = EndpointId (RelationId 0) 5}
        , [ (operationFile, "authority subject endpoint: \"user\" (endpoint 5 of relation 0)")
          , (manifestFile, "\"subjectEndpoint\": { \"authored\": \"user\", \"position\": 5, \"field\": \"subject\"")
          ]
        )
      , ( "planSubjectEndpointName"
        , \p -> p {planSubjectEndpointName = rename (planSubjectEndpointName p)}
        , [ (operationFile, "authority subject endpoint: \"Mutated\" (endpoint 0 of relation 0)")
          , (manifestFile, "\"subjectEndpoint\": { \"authored\": \"Mutated\", \"position\": 0, \"field\": \"subject\"")
          , (schemaFile, "subjectId for the subject endpoint \"Mutated\" (endpoint 0)")
          ]
        )
      , ( "planSubjectEntityId"
        , \p -> p {planSubjectEntityId = EntityId 5}
        , [ (operationFile, "entity \"User\" (entity 5)")
          , (manifestFile, "\"subjectEntity\": { \"authored\": \"User\", \"position\": 5, \"model\": \"MithrilSubject\" }")
          , (schemaFile, "the subject entity \"User\" (entity 5)")
          ]
        )
      , ( "planSubjectEntityName"
        , \p -> p {planSubjectEntityName = rename (planSubjectEntityName p)}
        , [ (operationFile, "entity \"Mutated\" (entity 0)")
          , (manifestFile, "\"subjectEntity\": { \"authored\": \"Mutated\", \"position\": 0, \"model\": \"MithrilSubject\" }")
          , (operationFile, "parameter 0: \"target\" : EntityRef \"Mutated\"")
          ]
        )
      , ( "planScopeEndpointId"
        , \p -> p {planScopeEndpointId = EndpointId (RelationId 0) 6}
        , [ (operationFile, "authority scope endpoint: \"organization\" (endpoint 6 of relation 0)")
          , (manifestFile, "\"scopeEndpoint\": { \"authored\": \"organization\", \"position\": 6, \"field\": \"scope\"")
          ]
        )
      , ( "planScopeEndpointName"
        , \p -> p {planScopeEndpointName = rename (planScopeEndpointName p)}
        , [ (operationFile, "authority scope endpoint: \"Mutated\" (endpoint 1 of relation 0)")
          , (manifestFile, "\"scopeEndpoint\": { \"authored\": \"Mutated\", \"position\": 1, \"field\": \"scope\"")
          ]
        )
      , ( "planScopeEntityId"
        , \p -> p {planScopeEntityId = EntityId 6}
        , [ (operationFile, "entity \"Organization\" (entity 6)")
          , (manifestFile, "\"scopeEntity\": { \"authored\": \"Organization\", \"position\": 6, \"model\": \"MithrilScope\" }")
          ]
        )
      , ( "planScopeEntityName"
        , \p -> p {planScopeEntityName = rename (planScopeEntityName p)}
        , [ (operationFile, "entity \"Mutated\" (entity 1)")
          , (manifestFile, "\"scopeEntity\": { \"authored\": \"Mutated\", \"position\": 1, \"model\": \"MithrilScope\" }")
          , (operationFile, "parameter 1: \"organization\" : EntityRef \"Mutated\"")
          ]
        )
      , ( "planEnumId"
        , \p -> p {planEnumId = EnumId 3}
        , [ (operationFile, "authority payload order: enum \"MembershipRole\" (enum 3)")
          , (operationFile, "\"Member\" (value 0 of enum 3)")
          , (manifestFile, "\"payloadEnum\": { \"authored\": \"MembershipRole\", \"position\": 3, \"enum\": \"MithrilPayload\" }")
          ]
        )
      , ( "planEnumName"
        , \p -> p {planEnumName = rename (planEnumName p)}
        , [ (operationFile, "authority payload order: enum \"Mutated\" (enum 0)")
          , (manifestFile, "\"payloadEnum\": { \"authored\": \"Mutated\", \"position\": 0, \"enum\": \"MithrilPayload\" }")
          , (operationFile, "parameter 2: \"newRole\" : Enum \"Mutated\"")
          ]
        )
      , ( "planEnumMembers"
        , \p -> p {planEnumMembers = onIndex 0 (\m -> m {planMemberId = EnumValueId (EnumId 0) 9}) (planEnumMembers p)}
        , [ (operationFile, "type Payload = \"Value9\" | \"Value1\";")
          , (schemaFile, "enum MithrilPayload {\n  Value9\n  Value1\n}")
          , (manifestFile, "\"members\": [{ \"authored\": \"Member\", \"position\": 9, \"value\": \"Value9\" }")
          ]
        )
      , ( "planEnumMembers"
        , \p -> p {planEnumMembers = onIndex 1 (\m -> m {planMemberName = rename (planMemberName m)}) (planEnumMembers p)}
        , [ (schemaFile, "Value1 = \"Mutated\"")
          , (manifestFile, "{ \"authored\": \"Mutated\", \"position\": 1, \"value\": \"Value1\" }]")
          ]
        )
      , ( "planEnumMembers"
        , \p -> p {planEnumMembers = reverse (planEnumMembers p)}
        , [ (operationFile, "type Payload = \"Value1\" | \"Value0\";")
          , (schemaFile, "enum MithrilPayload {\n  Value1\n  Value0\n}")
          ]
        )
      , ( "planRanking"
        , \p -> p {planRanking = [r {planRankedRank = planRankedRank r + 5} | r <- planRanking p]}
        , [ (operationFile, "const payloadRank: Readonly<Record<Payload, number>> = { \"Value0\": 5, \"Value1\": 6 };")
          , (manifestFile, "\"ranking\": [{ \"rank\": 5, \"authored\": \"Member\", \"position\": 0, \"value\": \"Value0\" }, { \"rank\": 6,")
          ]
        )
      , ( "planRanking"
        , \p -> p {planRanking = onIndex 0 (\r -> r {planRankedId = EnumValueId (EnumId 0) 9}) (planRanking p)}
        , [ (operationFile, "const payloadRank: Readonly<Record<Payload, number>> = { \"Value9\": 0, \"Value1\": 1 };")
          , (manifestFile, "\"ranking\": [{ \"rank\": 0, \"authored\": \"Member\", \"position\": 9, \"value\": \"Value9\" }")
          ]
        )
      , ( "planRanking"
        , \p -> p {planRanking = onIndex 0 (\r -> r {planRankedName = "Mutated"}) (planRanking p)}
        , [ (operationFile, "materialized authority ranking: rank 0 = \"Mutated\" (value 0 of enum 0)")
          , (manifestFile, "\"ranking\": [{ \"rank\": 0, \"authored\": \"Mutated\",")
          ]
        )
      , ( "planRanking"
        , \p -> p {planRanking = reverse (planRanking p)}
        , [ (operationFile, "const payloadRank: Readonly<Record<Payload, number>> = { \"Value1\": 1, \"Value0\": 0 };")
          , (manifestFile, "\"ranking\": [{ \"rank\": 1, \"authored\": \"Admin\", \"position\": 1, \"value\": \"Value1\" }, { \"rank\": 0,")
          ]
        )
      , ( "planRankBottom"
        , \p -> p {planRankBottom = (planRankBottom p) {planRankedRank = 4}}
        , [ (operationFile, "materialized bottom: rank 4 = \"Member\" (value 0 of enum 0)")
          , (manifestFile, "\"bottom\": { \"rank\": 4, \"authored\": \"Member\"")
          ]
        )
      , ( "planRankBottom"
        , \p -> p {planRankBottom = (planRankBottom p) {planRankedName = "Mutated"}}
        , [ (operationFile, "materialized bottom: rank 0 = \"Mutated\" (value 0 of enum 0)")
          , (manifestFile, "\"bottom\": { \"rank\": 0, \"authored\": \"Mutated\"")
          ]
        )
      , ( "planRankBottom"
        , \p -> p {planRankBottom = (planRankBottom p) {planRankedId = EnumValueId (EnumId 0) 9}}
        , [ (operationFile, "materialized bottom: rank 0 = \"Member\" (value 9 of enum 0)")
          , (manifestFile, "\"bottom\": { \"rank\": 0, \"authored\": \"Member\", \"position\": 9, \"value\": \"Value9\" }")
          ]
        )
      , ( "planRankTop"
        , \p -> p {planRankTop = (planRankTop p) {planRankedRank = 7}}
        , [ (operationFile, "const floorRank = 7;")
          , (operationFile, "privilege floor: rank 7 = \"Admin\" (value 1 of enum 0)")
          , (manifestFile, "\"floor\": { \"rank\": 7, \"authored\": \"Admin\"")
          ]
        )
      , ( "planRankTop"
        , \p -> p {planRankTop = (planRankTop p) {planRankedName = "Mutated"}}
        , [ (operationFile, "privilege floor: rank 1 = \"Mutated\" (value 1 of enum 0)")
          , (operationFile, "Some(Enum[\"MembershipRole\".\"Mutated\"])")
          , (operationFile, "the privilege floor is the rank of Value1 (\"Mutated\")")
          , (manifestFile, "\"floor\": { \"rank\": 1, \"authored\": \"Mutated\"")
          ]
        )
      , ( "planRankTop"
        , \p -> p {planRankTop = (planRankTop p) {planRankedId = EnumValueId (EnumId 0) 9}}
        , [ (operationFile, "the privilege floor is the rank of Value9 (\"Admin\")")
          , (manifestFile, "\"floor\": { \"rank\": 1, \"authored\": \"Admin\", \"position\": 9, \"value\": \"Value9\" }")
          ]
        )
      , ( "planAbsentRank"
        , \p -> p {planAbsentRank = -3}
        , [ (operationFile, "const absentRank = -3;")
          , (operationFile, "absent rank: -3")
          , (manifestFile, "\"absence\": { \"level\": \"Bottom\", \"rank\": -3 }")
          ]
        )
      , ( "planActionId"
        , \p -> p {planActionId = ActionId 9}
        , [ (operationFile, "case action: \"Membership.changeRole\" (action 9)")
          , (manifestFile, "\"caseAction\": { \"authored\": \"Membership.changeRole\", \"position\": 9,")
          ]
        )
      , ( "planActionName"
        , \p -> p {planActionName = rename (planActionName p)}
        , [ (operationFile, "case action: \"Mutated\" (action 4)")
          , (manifestFile, "\"caseAction\": { \"authored\": \"Mutated\", \"position\": 4, \"operation\": \"mithrilCaseAction\"")
          , (specFile, "authored action \"Mutated\".")
          , ("src/MainPage.tsx", "case action shape of \\\"Mutated\\\".")
          ]
        )
      , ( "planSubjectParameterId"
        , \p -> p {planSubjectParameterId = ParameterId (ActionId 4) 7}
        , [ (operationFile, "parameter 7: \"target\" : EntityRef \"User\"")
          , (manifestFile, "{ \"role\": \"subject\", \"authored\": \"target\", \"position\": 7, \"argument\": \"subject\" }")
          ]
        )
      , ( "planSubjectParameterName"
        , \p -> p {planSubjectParameterName = rename (planSubjectParameterName p)}
        , [ (operationFile, "parameter 0: \"Mutated\" : EntityRef \"User\"")
          , (operationFile, "subject carries the parameter \"Mutated\",")
          , (manifestFile, "{ \"role\": \"subject\", \"authored\": \"Mutated\", \"position\": 0, \"argument\": \"subject\" }")
          ]
        )
      , ( "planScopeParameterId"
        , \p -> p {planScopeParameterId = ParameterId (ActionId 4) 8}
        , [ (operationFile, "parameter 8: \"organization\" : EntityRef \"Organization\"")
          , (manifestFile, "{ \"role\": \"scope\", \"authored\": \"organization\", \"position\": 8, \"argument\": \"scope\" }")
          ]
        )
      , ( "planScopeParameterName"
        , \p -> p {planScopeParameterName = rename (planScopeParameterName p)}
        , [ (operationFile, "parameter 1: \"Mutated\" : EntityRef \"Organization\"")
          , (operationFile, "scope carries the parameter \"Mutated\",")
          , (manifestFile, "{ \"role\": \"scope\", \"authored\": \"Mutated\", \"position\": 1, \"argument\": \"scope\" }")
          ]
        )
      , ( "planPayloadParameterId"
        , \p -> p {planPayloadParameterId = ParameterId (ActionId 4) 9}
        , [ (operationFile, "parameter 9: \"newRole\" : Enum \"MembershipRole\"")
          , (manifestFile, "{ \"role\": \"payload\", \"authored\": \"newRole\", \"position\": 9, \"argument\": \"payload\" }")
          ]
        )
      , ( "planPayloadParameterName"
        , \p -> p {planPayloadParameterName = rename (planPayloadParameterName p)}
        , [ (operationFile, "parameter 2: \"Mutated\" : Enum \"MembershipRole\"")
          , (operationFile, "payload carries the parameter \"Mutated\";")
          , (manifestFile, "{ \"role\": \"payload\", \"authored\": \"Mutated\", \"position\": 2, \"argument\": \"payload\" }")
          ]
        )
      , ( "planEffectBindings"
        , \p -> p {planEffectBindings = onIndex 0 (\b -> b {planBindingEndpointId = EndpointId (RelationId 0) 7}) (planEffectBindings p)}
        , [ (operationFile, "effect: SetRelation[\"Membership\"](endpoint \"user\" (endpoint 7) = Argument \"target\" (parameter 0)")
          , (manifestFile, "\"effectBindings\": [{ \"endpoint\": \"user\", \"endpointPosition\": 7, \"parameter\": \"target\", \"parameterPosition\": 0 }")
          ]
        )
      , ( "planEffectBindings"
        , \p -> p {planEffectBindings = onIndex 0 (\b -> b {planBindingParameterId = ParameterId (ActionId 4) 8}) (planEffectBindings p)}
        , [ (operationFile, "effect: SetRelation[\"Membership\"](endpoint \"user\" (endpoint 0) = Argument \"target\" (parameter 8)")
          , (manifestFile, "\"effectBindings\": [{ \"endpoint\": \"user\", \"endpointPosition\": 0, \"parameter\": \"target\", \"parameterPosition\": 8 }")
          ]
        )
      , ( "planEffectBindings"
        , \p -> p {planEffectBindings = onIndex 1 (\b -> b {planBindingEndpointName = "Mutated", planBindingParameterName = "Mutated2"}) (planEffectBindings p)}
        , [ (operationFile, "endpoint \"Mutated\" (endpoint 1) = Argument \"Mutated2\" (parameter 1)) payload Argument[\"newRole\"]")
          , (manifestFile, "{ \"endpoint\": \"Mutated\", \"endpointPosition\": 1, \"parameter\": \"Mutated2\", \"parameterPosition\": 1 }]")
          ]
        )
      , ( "planEffectBindings"
        , \p -> p {planEffectBindings = reverse (planEffectBindings p)}
        , [ (operationFile, "effect: SetRelation[\"Membership\"](endpoint \"organization\" (endpoint 1) = Argument \"organization\" (parameter 1), endpoint \"user\" (endpoint 0)")
          , (manifestFile, "\"effectBindings\": [{ \"endpoint\": \"organization\", \"endpointPosition\": 1,")
          ]
        )
      , ( "planCaseScopeBinding"
        , \p -> p {planCaseScopeBinding = (planCaseScopeBinding p) {planBindingEndpointId = EndpointId (RelationId 0) 7}}
        , [ (operationFile, "case scope binding: endpoint \"organization\" (endpoint 7) = Argument \"organization\" (parameter 1)")
          , (manifestFile, "\"caseScopeBinding\": { \"endpoint\": \"organization\", \"endpointPosition\": 7, \"parameter\": \"organization\", \"parameterPosition\": 1 }")
          ]
        )
      , ( "planCaseScopeBinding"
        , \p -> p {planCaseScopeBinding = (planCaseScopeBinding p) {planBindingParameterId = ParameterId (ActionId 4) 8}}
        , [ (operationFile, "case scope binding: endpoint \"organization\" (endpoint 1) = Argument \"organization\" (parameter 8)")
          , (manifestFile, "\"caseScopeBinding\": { \"endpoint\": \"organization\", \"endpointPosition\": 1, \"parameter\": \"organization\", \"parameterPosition\": 8 }")
          ]
        )
      , ( "planCaseScopeBinding"
        , \p -> p {planCaseScopeBinding = (planCaseScopeBinding p) {planBindingEndpointName = "Mutated", planBindingParameterName = "Mutated2"}}
        , [ (operationFile, "case scope binding: endpoint \"Mutated\" (endpoint 1) = Argument \"Mutated2\" (parameter 1)")
          , (manifestFile, "\"caseScopeBinding\": { \"endpoint\": \"Mutated\", \"endpointPosition\": 1, \"parameter\": \"Mutated2\", \"parameterPosition\": 1 }")
          ]
        )
      ]

onIndex :: Int -> (a -> a) -> [a] -> [a]
onIndex index mutate values =
  [ if position == index then mutate value else value
  | (position, value) <- zip [0 ..] values
  ]

--------------------------------------------------------------------
-- Group 4: renamed models
--------------------------------------------------------------------

-- | One committed rename variant and the authored names its manifest
-- must state.
data RenameVariant = RenameVariant
  { variantName :: String
  , variantModel :: Text
  , variantScopeEntity :: Text
  , variantRelation :: Text
  , variantEnum :: Text
  , variantMembers :: [Text]
    -- ^ Declaration order.
  , variantRankingNames :: [Text]
    -- ^ Ascending rank order.
  , variantSubjectEndpoint :: Text
  , variantScopeEndpoint :: Text
  , variantParameters :: [Text]
  , variantAction :: Text
  , variantCodeDiffers :: Bool
    -- ^ Whether the generated Action's code (comments aside) may
    -- differ from the base bundle's: only the declaration-order
    -- variant materializes a different ranking literal.
  }

renameVariants :: [RenameVariant]
renameVariants =
  [ RenameVariant "string-scope" "Acme" "String" "Membership" "MembershipRole" ["Member", "Admin"] ["Member", "Admin"] "user" "organization" ["target", "organization", "newRole"] "Membership.changeRole" False
  , RenameVariant "wasp-auth-names" "Acme" "Session" "Auth" "AuthIdentity" ["Member", "Admin"] ["Member", "Admin"] "user" "organization" ["target", "organization", "newRole"] "Membership.changeRole" False
  , RenameVariant "reserved-words" "Class" "Function" "Constructor" "Object" ["Delete", "Export"] ["Delete", "Export"] "delete" "export" ["function", "class", "new"] "Constructor.prototype" False
  , RenameVariant "acronyms-digits" "ACME2" "HTTPServer2" "X509Membership" "ACLRole" ["IOS7", "V2Admin"] ["IOS7", "V2Admin"] "httpNode" "x509" ["id2", "httpTarget", "newACL"] "X509Membership.changeACL2" False
  , RenameVariant "leading-characters" "Z" "A" "Zz" "Za0" ["A0", "Z9"] ["A0", "Z9"] "a" "z9" ["a0", "zz", "z"] "Zz.a" False
  , RenameVariant "same-target-spelling" "MithrilSubject" "MithrilScope" "MithrilAuthority" "MithrilPayload" ["Value1", "Value0"] ["Value1", "Value0"] "user" "userId" ["subject", "scope", "payload"] "MithrilAuthority.mithrilCaseAction" False
  , RenameVariant "declaration-order" "Acme" "Organization" "Membership" "MembershipRole" ["Admin", "Member"] ["Member", "Admin"] "user" "organization" ["target", "organization", "newRole"] "Membership.changeRole" True
  ]

renamedModelChecks :: N.Model -> WaspBundle -> IO [Check]
renamedModelChecks baseModel baseBundle = do
  orderBytes <- ByteString.readFile (renameDirectoryPath </> "declaration-order.mir.json")
  variantChecks <- forM renameVariants $ \variant -> do
    bytes <- ByteString.readFile (renameDirectoryPath </> variantName variant <> ".mir.json")
    pure $ case fmap renderWaspBundle (pipelineDocument bytes) of
      Just (Right bundle) ->
        let manifest = textOf bundle manifestFile
            positions = [0 :: Int ..]
            memberObjects =
              "\"members\": ["
                <> Text.intercalate
                  ", "
                  [ "{ \"authored\": " <> jsStringLiteral name <> ", \"position\": " <> shown position <> ", \"value\": \"Value" <> shown position <> "\" }"
                  | (position, name) <- zip positions (variantMembers variant)
                  ]
                <> "]"
            rankingObjects =
              "\"ranking\": ["
                <> Text.intercalate
                  ", "
                  [ "{ \"rank\": " <> shown rank <> ", \"authored\": " <> jsStringLiteral name <> ", \"position\": " <> shown position <> ", \"value\": \"Value" <> shown position <> "\" }"
                  | (rank, name) <- zip positions (variantRankingNames variant)
                  , Just position <- [lookup name (zip (variantMembers variant) positions)]
                  ]
                <> "]"
            parameterObjects =
              "\"parameters\": ["
                <> Text.intercalate
                  ", "
                  [ "{ \"role\": " <> jsStringLiteral role <> ", \"authored\": " <> jsStringLiteral name <> ", \"position\": " <> shown position <> ", \"argument\": " <> jsStringLiteral role <> " }"
                  | (position, role, name) <- zip3 positions ["subject", "scope", "payload"] (variantParameters variant)
                  ]
                <> "]"
         in [ check
                ("renamed model " <> variantName variant <> ": renders with the fixed inventory and fixed target names")
                ( map managedPath (waspBundleFiles bundle) == expectedInventory
                    && summaryOperation (waspBundleSummary bundle) == "mithrilCaseAction"
                    && summaryRoute (waspBundleSummary bundle) == "/operations/mithril-case-action"
                    && summaryModelName (waspBundleSummary bundle) == variantModel variant
                    && summaryCaseAction (waspBundleSummary bundle) == variantAction variant
                )
            , check
                ("renamed model " <> variantName variant <> ": the manifest states the authored names and the target mapping")
                ( all
                    (`Text.isInfixOf` manifest)
                    [ "\"model\": " <> jsStringLiteral (variantModel variant) <> ","
                    , "\"caseAction\": { \"authored\": " <> jsStringLiteral (variantAction variant) <> ", \"position\": 4, \"operation\": \"mithrilCaseAction\""
                    , "\"subjectEntity\": { \"authored\": \"User\", \"position\": 0, \"model\": \"MithrilSubject\" }"
                    , "\"scopeEntity\": { \"authored\": " <> jsStringLiteral (variantScopeEntity variant) <> ", \"position\": 1, \"model\": \"MithrilScope\" }"
                    , "\"authorityRelation\": { \"authored\": " <> jsStringLiteral (variantRelation variant) <> ", \"position\": 0, \"model\": \"MithrilAuthority\""
                    , "\"subjectEndpoint\": { \"authored\": " <> jsStringLiteral (variantSubjectEndpoint variant) <> ", \"position\": 0, \"field\": \"subject\", \"idField\": \"subjectId\" }"
                    , "\"scopeEndpoint\": { \"authored\": " <> jsStringLiteral (variantScopeEndpoint variant) <> ", \"position\": 1, \"field\": \"scope\", \"idField\": \"scopeId\" }"
                    , "\"payloadEnum\": { \"authored\": " <> jsStringLiteral (variantEnum variant) <> ", \"position\": 0, \"enum\": \"MithrilPayload\" }"
                    , memberObjects
                    , rankingObjects
                    , parameterObjects
                    ]
                )
            , check
                ("renamed model " <> variantName variant <> ": authored names never reach code (comment-stripped files equal the base bundle's)")
                ( codeLines bundle schemaFile == codeLines baseBundle schemaFile
                    && codeLines bundle specFile == codeLines baseBundle specFile
                    && ( if variantCodeDiffers variant
                           then
                             filter (not . ("const payloadRank" `Text.isPrefixOf`)) (codeLines bundle operationFile)
                               == filter (not . ("const payloadRank" `Text.isPrefixOf`)) (codeLines baseBundle operationFile)
                               && codeLines bundle operationFile /= codeLines baseBundle operationFile
                           else codeLines bundle operationFile == codeLines baseBundle operationFile
                       )
                )
            ]
      _ -> [check ("renamed model " <> variantName variant <> ": renders through the public pipeline") False]
  pure $
    concat variantChecks
      <> [ check
             "the declaration-order variant materializes a different ranking literal from the same fixed values"
             ( case fmap renderWaspBundle (pipelineDocument orderBytes) of
                 Just (Right bundle) ->
                   "const payloadRank: Readonly<Record<Payload, number>> = { \"Value1\": 0, \"Value0\": 1 };" `Text.isInfixOf` textOf bundle operationFile
                     && "const floorRank = 1;" `Text.isInfixOf` textOf bundle operationFile
                     && "enum MithrilPayload {\n  Value0\n  Value1\n}" `Text.isInfixOf` textOf bundle schemaFile
                     && "\"members\": [{ \"authored\": \"Admin\", \"position\": 0, \"value\": \"Value0\" }, { \"authored\": \"Member\", \"position\": 1, \"value\": \"Value1\" }]" `Text.isInfixOf` textOf bundle manifestFile
                     && "\"floor\": { \"rank\": 1, \"authored\": \"Admin\", \"position\": 0, \"value\": \"Value0\" }" `Text.isInfixOf` textOf bundle manifestFile
                 _ -> False
             )
         , check
             "hostile plan names cannot inject syntax: line counts, code lines, and manifest validity are unchanged"
             ( case supportPlan baseModel of
                 Right plan ->
                   let hostile = \located -> located {sourcedValue = "Evil\n*/ } eval(1); // \"\\ \x2028 \ESC"}
                       hostilePlan =
                         plan
                           { planModelName = hostile (planModelName plan)
                           , planRelationName = hostile (planRelationName plan)
                           , planSubjectEndpointName = hostile (planSubjectEndpointName plan)
                           , planScopeEndpointName = hostile (planScopeEndpointName plan)
                           , planSubjectEntityName = hostile (planSubjectEntityName plan)
                           , planScopeEntityName = hostile (planScopeEntityName plan)
                           , planEnumName = hostile (planEnumName plan)
                           , planEnumMembers = [m {planMemberName = hostile (planMemberName m)} | m <- planEnumMembers plan]
                           , planRanking = [r {planRankedName = "Ev\nil"} | r <- planRanking plan]
                           , planRankBottom = (planRankBottom plan) {planRankedName = "Ev\nil"}
                           , planRankTop = (planRankTop plan) {planRankedName = "Ev\nil"}
                           , planActionName = hostile (planActionName plan)
                           , planSubjectParameterName = hostile (planSubjectParameterName plan)
                           , planScopeParameterName = hostile (planScopeParameterName plan)
                           , planPayloadParameterName = hostile (planPayloadParameterName plan)
                           , planEffectBindings = [b {planBindingEndpointName = "Ev\nil", planBindingParameterName = "Ev\nil"} | b <- planEffectBindings plan]
                           , planCaseScopeBinding = (planCaseScopeBinding plan) {planBindingEndpointName = "Ev\nil", planBindingParameterName = "Ev\nil"}
                           }
                       hostileBundle = renderBundleFromPlan hostilePlan
                       sameLineCount path = length (Text.lines (textOf hostileBundle path)) == length (Text.lines (textOf baseBundle path))
                    in all sameLineCount expectedInventory
                         && codeLines hostileBundle schemaFile == codeLines baseBundle schemaFile
                         && codeLines hostileBundle specFile == codeLines baseBundle specFile
                         && codeLines hostileBundle operationFile == codeLines baseBundle operationFile
                         && (Aeson.decodeStrict (fileOf hostileBundle manifestFile) :: Maybe Value) /= Nothing
                         && map managedPath (waspBundleFiles hostileBundle) == expectedInventory
                 Left _ -> False
             )
         ]
  where
    shown :: Int -> Text
    shown = Text.pack . show

-- | The lines of a rendered file that are not line comments, with
-- the specification's title line (the one string literal of authored
-- text in code) removed.
codeLines :: WaspBundle -> FilePath -> [Text]
codeLines bundle path =
  [ line
  | line <- Text.lines (textOf bundle path)
  , not ("//" `Text.isPrefixOf` Text.stripStart line)
  , not ("title: " `Text.isPrefixOf` Text.stripStart line)
  ]

--------------------------------------------------------------------
-- Group 5: the pure confinement checker
--------------------------------------------------------------------

snapshotOf :: WaspBundle -> [RootEntry]
snapshotOf bundle =
  RootEntry "src" Directory
    : [RootEntry path (RegularFile bytes) | (path, bytes) <- bundleBytes bundle]

markerViolation :: ConfinementViolation
markerViolation =
  ConfinementViolation
    (Text.pack markerFile)
    "the root carries no byte-exact Mithril ownership marker, so it is not an owned Wasp Confinement Profile v0 root (an unmarked nonempty root is never replaced)"

nonCanonicalMessage :: Text
nonCanonicalMessage = "the snapshot path is not a canonical root-relative path (no leading separator, no empty, dot, or dot-dot component)"

duplicateMessage :: Text
duplicateMessage = "the snapshot lists this path more than once (duplicate or aliased entries)"

managedHardLinkMessage :: Text
managedHardLinkMessage = "the managed path is occupied by a hard-linked regular file (link count above one), not a private managed regular file"

unmanagedHardLinkMessage :: Text
unmanagedHardLinkMessage = "a hard-linked regular file (link count above one) is not allowed inside the confined source root (its bytes can be changed through another path)"

pureConfinementChecks :: WaspBundle -> [Check]
pureConfinementChecks bundle =
  [ check
      "the exact bundle snapshot is confined"
      (checkWaspConfinement FullCheck bundle (snapshotOf bundle) == [])
  , check
      "an empty root reports every managed file missing"
      ( checkWaspConfinement FullCheck bundle []
          == [ConfinementViolation (Text.pack path) "the managed file is missing" | path <- expectedInventory]
      )
  , check
      "the ownership rule initializes an empty root and replaces an exact, an altered, and a partial owned root"
      ( checkWaspConfinement OwnershipCheck bundle [] == []
          && checkWaspConfinement OwnershipCheck bundle (snapshotOf bundle) == []
          && checkWaspConfinement OwnershipCheck bundle (replaceEntry operationFile (RegularFile "tampered") (snapshotOf bundle)) == []
          && checkWaspConfinement OwnershipCheck bundle [RootEntry markerFile (RegularFile ownershipMarkerBytes)] == []
          && checkWaspConfinement OwnershipCheck bundle [RootEntry markerFile (RegularFile ownershipMarkerBytes), RootEntry "src" Directory] == []
      )
  , check
      "the ownership rule refuses an unmarked nonempty root and an altered marker"
      ( checkWaspConfinement OwnershipCheck bundle [RootEntry ".gitignore" (RegularFile (fileOf bundle ".gitignore"))] == [markerViolation]
          && checkWaspConfinement OwnershipCheck bundle (replaceEntry markerFile (RegularFile "mithril-wasp-bundle wasp-confinement-profile-v1\n") (snapshotOf bundle)) == [markerViolation]
          && checkWaspConfinement OwnershipCheck bundle [RootEntry markerFile (RegularFile ownershipMarkerBytes), RootEntry "notes.txt" (RegularFile "x")]
            == [ConfinementViolation "notes.txt" "an unexpected file is not part of the closed path inventory"]
          && checkWaspConfinement OwnershipCheck bundle (snapshotOf bundle <> [RootEntry "src/link" SymbolicLink])
            == [ConfinementViolation "src/link" "a symbolic link is not allowed inside the confined source root (path escape)"]
          && checkWaspConfinement OwnershipCheck bundle (snapshotOf bundle <> [RootEntry "node_modules" Directory])
            == [ConfinementViolation "node_modules" "installation and build outputs (node_modules, .wasp) are not part of the clean source profile"]
      )
  , check
      "hard-linked managed and unmanaged files are rejected in both modes"
      ( let managedLinked = replaceEntry ".npmrc" HardLinkedFile (snapshotOf bundle)
            unmanagedLinked = snapshotOf bundle <> [RootEntry "src/extra.ts" HardLinkedFile]
            managedExpected = [ConfinementViolation ".npmrc" managedHardLinkMessage]
            unmanagedExpected =
              [ ConfinementViolation "src/extra.ts" unmanagedHardLinkMessage
              , ConfinementViolation "src/extra.ts" "an additional server-capable source file is not part of the closed path inventory"
              ]
         in checkWaspConfinement FullCheck bundle managedLinked == managedExpected
              && checkWaspConfinement OwnershipCheck bundle managedLinked == managedExpected
              && checkWaspConfinement FullCheck bundle unmanagedLinked == unmanagedExpected
              && checkWaspConfinement OwnershipCheck bundle unmanagedLinked == unmanagedExpected
      )
  , check
      "duplicate regular entries are rejected before any lookup"
      ( checkWaspConfinement FullCheck bundle (snapshotOf bundle <> [RootEntry ".npmrc" (RegularFile (fileOf bundle ".npmrc"))])
          == [ConfinementViolation ".npmrc" duplicateMessage]
      )
  , check
      "a symbolic link followed by a regular duplicate, and a regular entry followed by a symbolic-link duplicate, are rejected identically"
      ( let linkFirst = RootEntry ".npmrc" SymbolicLink : snapshotOf bundle
            regularFirst = snapshotOf bundle <> [RootEntry ".npmrc" SymbolicLink]
            expected = [ConfinementViolation ".npmrc" duplicateMessage]
         in checkWaspConfinement FullCheck bundle linkFirst == expected
              && checkWaspConfinement FullCheck bundle regularFirst == expected
              && checkWaspConfinement OwnershipCheck bundle linkFirst == expected
      )
  , check
      "differently spelled aliases of one path are rejected as non-canonical and as duplicates, independently of input order"
      ( let aliased = [RootEntry "./src/x.ts" (RegularFile "a"), RootEntry "src//x.ts" (RegularFile "b"), RootEntry "src/x.ts" (RegularFile "c")]
            expected =
              [ ConfinementViolation "./src/x.ts" nonCanonicalMessage
              , ConfinementViolation "src//x.ts" nonCanonicalMessage
              , ConfinementViolation "src/x.ts" duplicateMessage
              ]
         in checkWaspConfinement FullCheck bundle (snapshotOf bundle <> aliased) == expected
              && checkWaspConfinement FullCheck bundle (reverse aliased <> snapshotOf bundle) == expected
      )
  , check
      "absolute, dot, dot-dot, trailing-separator, and empty snapshot paths are rejected as non-canonical"
      ( checkWaspConfinement
          FullCheck
          bundle
          ( snapshotOf bundle
              <> [ RootEntry "/etc/passwd" (RegularFile "x")
                 , RootEntry "src/../main.wasp.ts" (RegularFile "x")
                 , RootEntry "src/." Directory
                 , RootEntry "src/" Directory
                 , RootEntry "" (RegularFile "x")
                 ]
          )
          == [ ConfinementViolation "" nonCanonicalMessage
             , ConfinementViolation "/etc/passwd" nonCanonicalMessage
             , ConfinementViolation "src" duplicateMessage
             , ConfinementViolation "src/" nonCanonicalMessage
             , ConfinementViolation "src/." nonCanonicalMessage
             , ConfinementViolation "src/../main.wasp.ts" nonCanonicalMessage
             ]
      )
  , check
      "a three-way duplicate is reported once"
      ( checkWaspConfinement
          FullCheck
          bundle
          (snapshotOf bundle <> [RootEntry "tsconfig.json" SymbolicLink, RootEntry "tsconfig.json" Directory])
          == [ConfinementViolation "tsconfig.json" duplicateMessage]
      )
  , check
      "duplicates of unmanaged paths are rejected as duplicates, not as unexpected files"
      ( checkWaspConfinement
          FullCheck
          bundle
          (snapshotOf bundle <> [RootEntry "notes.txt" (RegularFile "a"), RootEntry "notes.txt" (RegularFile "b")])
          == [ConfinementViolation "notes.txt" duplicateMessage]
      )
  , check
      "an edited generated Action is labelled and its bypasses named"
      ( checkWaspConfinement
          FullCheck
          bundle
          (replaceEntry operationFile (RegularFile (fileOf bundle operationFile <> "\nconst x = await prisma.$queryRaw`select 1`; eval(\"1\"); new Function(\"x\"); import(\"fs\"); require(\"child_process\");\n")) (snapshotOf bundle))
          == [ ConfinementViolation (Text.pack operationFile) "the file constructs code with eval"
             , ConfinementViolation (Text.pack operationFile) "the file constructs code with the Function constructor"
             , ConfinementViolation (Text.pack operationFile) "the file reaches child_process"
             , ConfinementViolation (Text.pack operationFile) "the file uses CommonJS require"
             , ConfinementViolation (Text.pack operationFile) "the file uses a Prisma raw-query API ($queryRaw or $queryRawUnsafe)"
             , ConfinementViolation (Text.pack operationFile) "the file uses a dynamic import"
             , ConfinementViolation (Text.pack operationFile) "the generated Action differs from the regenerated bundle (edited generated authorization)"
             ]
      )
  , check
      "a second source file importing prisma is unexpected and labelled"
      ( checkWaspConfinement
          FullCheck
          bundle
          (snapshotOf bundle <> [RootEntry "src/direct.ts" (RegularFile "import { prisma } from \"wasp/server\";\nexport const x = prisma;\n")])
          == [ ConfinementViolation "src/direct.ts" "an additional server-capable source file is not part of the closed path inventory"
             , ConfinementViolation "src/direct.ts" "the file imports prisma from wasp/server outside the generated Action"
             ]
      )
  , check
      "an additional spec file declaring an API, a CRUD, a Query, a job, and a server setup is labelled"
      ( checkWaspConfinement
          FullCheck
          bundle
          (snapshotOf bundle <> [RootEntry "extra.wasp.ts" (RegularFile "api(\"GET\", \"/x\", f); crud(\"tasks\", \"Task\", {}); query(g); job(h, { executor: \"PgBoss\" }); apiNamespace(\"/x\", {}); server: { setupFn: s }; db: { seeds: [d] };\n")])
          == [ ConfinementViolation "extra.wasp.ts" "an additional Wasp specification file is not part of the closed path inventory"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification declares a CRUD, which the profile does not permit"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification declares a Query, which the profile does not permit"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification declares a custom HTTP API, which the profile does not permit"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification declares a job, which the profile does not permit"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification declares a server setup or middleware path, which the profile does not permit"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification declares an API namespace, which the profile does not permit"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification declares database seeds or a Prisma setup function, which the profile does not permit"
             , ConfinementViolation "extra.wasp.ts" "the Wasp specification no longer declares the generated Action"
             ]
      )
  , check
      "dependency and database-provider drift are labelled"
      ( checkWaspConfinement
          FullCheck
          bundle
          ( replaceEntry "package.json" (RegularFile "{ \"dependencies\": { \"pg\": \"8.0.0\", \"@prisma/client\": \"5.19.1\" } }\n")
              (replaceEntry "schema.prisma" (RegularFile "datasource db { provider = \"sqlite\" }\n") (snapshotOf bundle))
          )
          == [ ConfinementViolation "package.json" "the dependency configuration declares @prisma/client (no second ORM or database client is permitted)"
             , ConfinementViolation "package.json" "the dependency configuration declares pg (no second ORM or database client is permitted)"
             , ConfinementViolation "package.json" "the managed dependency configuration differs from the regenerated bundle (dependency drift)"
             , ConfinementViolation "schema.prisma" "the Prisma schema declares the database provider sqlite (database-provider drift)"
             , ConfinementViolation "schema.prisma" "the Prisma schema does not declare the PostgreSQL datasource provider (database-provider drift)"
             , ConfinementViolation "schema.prisma" "the managed Prisma schema differs from the regenerated bundle (schema or database-provider drift)"
             ]
      )
  , check
      "build outputs, migrations, lockfiles, environment files, and foreign directories are rejected by name"
      ( checkWaspConfinement
          FullCheck
          bundle
          ( snapshotOf bundle
              <> [ RootEntry "node_modules" Directory
                 , RootEntry ".wasp" Directory
                 , RootEntry "migrations" Directory
                 , RootEntry "migrations/init.sql" (RegularFile "create table x;")
                 , RootEntry "dist" Directory
                 , RootEntry "package-lock.json" (RegularFile "{}")
                 , RootEntry ".env.server" (RegularFile "JWT_SECRET=x")
                 , RootEntry "docs" Directory
                 , RootEntry "src/device" OtherEntry
                 ]
          )
          == [ ConfinementViolation ".env.server" "environment files are not part of the clean source profile"
             , ConfinementViolation ".wasp" "installation and build outputs (node_modules, .wasp) are not part of the clean source profile"
             , ConfinementViolation "dist" "build outputs and version-control directories are not part of the clean source profile"
             , ConfinementViolation "docs" "an unexpected directory is not part of the closed path inventory"
             , ConfinementViolation "migrations" "deployable migrations are not part of the clean source profile (migrate only in a temporary copy)"
             , ConfinementViolation "migrations/init.sql" "an unexpected file is not part of the closed path inventory"
             , ConfinementViolation "node_modules" "installation and build outputs (node_modules, .wasp) are not part of the clean source profile"
             , ConfinementViolation "package-lock.json" "a dependency lockfile is not part of the clean source profile (dependency drift)"
             , ConfinementViolation "src/device" "an unsupported filesystem entry (neither a regular file nor a directory) is not allowed inside the confined source root"
             ]
      )
  , check
      "a managed path occupied by a directory or a link is rejected in both modes"
      ( let entries = replaceEntry "schema.prisma" Directory (replaceEntry ".npmrc" SymbolicLink (snapshotOf bundle))
            expected =
              [ ConfinementViolation ".npmrc" "the managed path is occupied by a symbolic link, not the managed regular file"
              , ConfinementViolation "schema.prisma" "the managed path is occupied by a directory, not the managed regular file"
              ]
         in checkWaspConfinement FullCheck bundle entries == expected
              && checkWaspConfinement OwnershipCheck bundle entries == expected
      )
  , check
      "violations are sorted and deduplicated"
      ( checkWaspConfinement
          FullCheck
          bundle
          (snapshotOf bundle <> [RootEntry "zzz.txt" (RegularFile "x"), RootEntry "aaa.txt" (RegularFile "x")])
          == [ ConfinementViolation "aaa.txt" "an unexpected file is not part of the closed path inventory"
             , ConfinementViolation "zzz.txt" "an unexpected file is not part of the closed path inventory"
             ]
      )
  ]

replaceEntry :: FilePath -> EntryKind -> [RootEntry] -> [RootEntry]
replaceEntry path kind entries =
  [ if entryPath entry == path then RootEntry path kind else entry
  | entry <- entries
  ]

--------------------------------------------------------------------
-- Group 6: the confinement attack matrix through the filesystem
--------------------------------------------------------------------

-- | One attack: a name, a mutation of a fresh fixture copy (given the
-- root and the scratch directory beside it), and the exact
-- violations @check@ must report.
data Attack = Attack
  { attackName :: String
  , attackMutation :: FilePath -> FilePath -> IO ()
  , attackExpected :: [ConfinementViolation]
  }

confinementAttackChecks :: IO [Check]
confinementAttackChecks = do
  results <- forM attacks $ \attack ->
    withFixtureCopy $ \scratch root -> do
      attackMutation attack root scratch
      outcome <- checkWaspApp nspePath root
      pure
        ( attackName attack
        , outcome == Right (WaspNotConfined root (NonEmpty.fromList (attackExpected attack)))
        )
  fixtureRootAbsolute <- canonicalizePath fixtureRoot
  linkedRoot <- withScratchDirectory $ \scratch -> do
    createDirectoryLink fixtureRootAbsolute (scratch </> "linked")
    outcome <- checkWaspApp nspePath (scratch </> "linked")
    pure (outcome == Left (WaspRootError (scratch </> "linked") "is a symbolic link"))
  fileRoot <- withScratchDirectory $ \scratch -> do
    writeFile (scratch </> "file") "x"
    outcome <- checkWaspApp nspePath (scratch </> "file")
    pure (outcome == Left (WaspRootError (scratch </> "file") "is not a directory"))
  pure $
    [check ("confinement attack: " <> name) passed | (name, passed) <- results]
      <> [ check
             ("the attack matrix covers its pinned " <> show expectedAttackCount <> " attacks")
             (length attacks == expectedAttackCount)
         , check "a root that is itself a symbolic link is refused as unusable" linkedRoot
         , check "a root that is a regular file is refused as unusable" fileRoot
         ]
  where
    expectedAttackCount = 26
    op = Text.pack operationFile
    v path message = ConfinementViolation path message
    append path extra root = ByteString.appendFile (root </> path) extra
    replaceIn path from to root = do
      bytes <- ByteString.readFile (root </> path)
      ByteString.writeFile (root </> path) (Encoding.encodeUtf8 (Text.replace from to (Encoding.decodeUtf8 bytes)))
    actionDiffers = v op "the generated Action differs from the regenerated bundle (edited generated authorization)"
    specDiffers = v "main.wasp.ts" "the managed file differs from the regenerated bundle"
    rootOnly mutate root _ = mutate root
    attacks =
      [ Attack
          "edited generated authorization (privilege floor lowered)"
          (rootOnly (replaceIn operationFile "const floorRank = 1;" "const floorRank = 0;"))
          [actionDiffers]
      , Attack
          "edited generated authorization (actor/target guard removed)"
          (rootOnly (replaceIn operationFile "(!(actor === args.subject) && targetTuple !== null)" "(targetTuple !== null)"))
          [actionDiffers]
      , Attack
          "removed Action binding in the specification"
          (rootOnly (replaceIn "main.wasp.ts" "    action(mithrilCaseAction, { entities: [\"MithrilAuthority\"], auth: true }),\n" ""))
          [v "main.wasp.ts" "the Wasp specification no longer declares the generated Action", specDiffers]
      , Attack
          "Action declared without authentication"
          (rootOnly (replaceIn "main.wasp.ts" "auth: true" "auth: false"))
          [specDiffers]
      , Attack
          "alternative custom HTTP API in the specification"
          (rootOnly (replaceIn "main.wasp.ts" "  spec: [\n" "  spec: [\n    api(\"POST\", \"/bypass\", bypass, { auth: false }),\n"))
          [v "main.wasp.ts" "the Wasp specification declares a custom HTTP API, which the profile does not permit", specDiffers]
      , Attack
          "alternative CRUD in the specification"
          (rootOnly (replaceIn "main.wasp.ts" "  spec: [\n" "  spec: [\n    crud(\"authorities\", \"MithrilAuthority\", { update: {} }),\n"))
          [v "main.wasp.ts" "the Wasp specification declares a CRUD, which the profile does not permit", specDiffers]
      , Attack
          "second Action, Query, job, and API namespace in the specification"
          (rootOnly (replaceIn "main.wasp.ts" "  spec: [\n" "  spec: [\n    action(other), query(other), job(other, { executor: \"PgBoss\" }), apiNamespace(\"/x\", { middlewareConfigFn: m }),\n"))
          [ v "main.wasp.ts" "the Wasp specification declares a Query, which the profile does not permit"
          , v "main.wasp.ts" "the Wasp specification declares a job, which the profile does not permit"
          , v "main.wasp.ts" "the Wasp specification declares a server setup or middleware path, which the profile does not permit"
          , v "main.wasp.ts" "the Wasp specification declares an API namespace, which the profile does not permit"
          , v "main.wasp.ts" "the Wasp specification declares an additional Action, which the profile does not permit"
          , specDiffers
          ]
      , Attack
          "server setup, middleware, seeds, and WebSocket paths in the specification"
          (rootOnly (replaceIn "main.wasp.ts" "  spec: [\n" "  server: { setupFn: s, middlewareConfigFn: m },\n  db: { seeds: [seed] },\n  webSocket: { fn: ws },\n  spec: [\n"))
          [ v "main.wasp.ts" "the Wasp specification declares a WebSocket or email-sender path, which the profile does not permit"
          , v "main.wasp.ts" "the Wasp specification declares a server setup or middleware path, which the profile does not permit"
          , v "main.wasp.ts" "the Wasp specification declares database seeds or a Prisma setup function, which the profile does not permit"
          , specDiffers
          ]
      , Attack
          "direct Prisma access from another server file"
          (rootOnly (\root -> writeFile (root </> "src" </> "direct.ts") "import { prisma } from \"wasp/server\";\nexport const all = () => prisma.mithrilAuthority.findMany();\n"))
          [ v "src/direct.ts" "an additional server-capable source file is not part of the closed path inventory"
          , v "src/direct.ts" "the file imports prisma from wasp/server outside the generated Action"
          ]
      , Attack
          "alternate database library in the dependency configuration and a source file"
          ( rootOnly $ \root -> do
              replaceIn "package.json" "\"react\": \"^19.2.1\"," "\"pg\": \"8.13.0\",\n    \"react\": \"^19.2.1\"," root
              writeFile (root </> "src" </> "raw.ts") "import pg from \"pg\";\nexport const pool = new pg.Pool();\n"
          )
          [ v "package.json" "the dependency configuration declares pg (no second ORM or database client is permitted)"
          , v "package.json" "the managed dependency configuration differs from the regenerated bundle (dependency drift)"
          , v "src/raw.ts" "an additional server-capable source file is not part of the closed path inventory"
          , v "src/raw.ts" "the file imports the database library pg (no second ORM or database client is permitted)"
          ]
      , Attack
          "Prisma client package imported directly"
          (rootOnly (append operationFile "import { PrismaClient } from \"@prisma/client\";\n"))
          [ v op "the file imports the Prisma client package directly (only the Prisma runtime supplied by Wasp is permitted)"
          , v op "the file imports the database library @prisma/client (no second ORM or database client is permitted)"
          , actionDiffers
          ]
      , Attack
          "raw SQL in the generated Action"
          (rootOnly (append operationFile "export const leak = () => prisma.$executeRawUnsafe(\"update \\\"MithrilAuthority\\\" set payload = 'Value1'\");\n"))
          [v op "the file uses a Prisma raw-query API ($executeRaw or $executeRawUnsafe)", actionDiffers]
      , Attack
          "dynamic code in the generated Action"
          (rootOnly (append operationFile "export const dyn = () => eval(\"1\") + new Function(\"return 1\")() + import(\"node:fs\") + require(\"child_process\");\n"))
          [ v op "the file constructs code with eval"
          , v op "the file constructs code with the Function constructor"
          , v op "the file reaches child_process"
          , v op "the file uses CommonJS require"
          , v op "the file uses a dynamic import"
          , actionDiffers
          ]
      , Attack
          "extra Wasp specification file"
          (rootOnly (\root -> writeFile (root </> "extra.wasp.ts") "import { api } from \"@wasp.sh/spec\";\nexport default [api(\"GET\", \"/x\", f)];\n"))
          [ v "extra.wasp.ts" "an additional Wasp specification file is not part of the closed path inventory"
          , v "extra.wasp.ts" "the Wasp specification declares a custom HTTP API, which the profile does not permit"
          , v "extra.wasp.ts" "the Wasp specification no longer declares the generated Action"
          ]
      , Attack
          "extra server source file"
          (rootOnly (\root -> writeFile (root </> "src" </> "helper.ts") "export const helper = 1;\n"))
          [v "src/helper.ts" "an additional server-capable source file is not part of the closed path inventory"]
      , Attack
          "dependency drift"
          (rootOnly (replaceIn "package.json" "\"prisma\": \"5.19.1\"" "\"prisma\": \"6.0.0\""))
          [v "package.json" "the managed dependency configuration differs from the regenerated bundle (dependency drift)"]
      , Attack
          "database-provider drift"
          (rootOnly (replaceIn "schema.prisma" "provider = \"postgresql\"" "provider = \"sqlite\""))
          [ v "schema.prisma" "the Prisma schema declares the database provider sqlite (database-provider drift)"
          , v "schema.prisma" "the Prisma schema does not declare the PostgreSQL datasource provider (database-provider drift)"
          , v "schema.prisma" "the managed Prisma schema differs from the regenerated bundle (schema or database-provider drift)"
          ]
      , Attack
          "symbolic link inside the root (path escape)"
          (rootOnly (\root -> createFileLink "/etc/hostname" (root </> "src" </> "escape.ts")))
          [v "src/escape.ts" "a symbolic link is not allowed inside the confined source root (path escape)"]
      , Attack
          "symbolic link replacing a managed file"
          (rootOnly (\root -> removeFile (root </> ".npmrc") >> createFileLink "/etc/hostname" (root </> ".npmrc")))
          [v ".npmrc" "the managed path is occupied by a symbolic link, not the managed regular file"]
      , Attack
          "hard link replacing a managed root file (identical bytes through another path)"
          ( \root scratch -> do
              copyFile (root </> ".npmrc") (scratch </> "outside-npmrc")
              removeFile (root </> ".npmrc")
              createLink (scratch </> "outside-npmrc") (root </> ".npmrc")
          )
          [v ".npmrc" managedHardLinkMessage]
      , Attack
          "hard link replacing the nested generated Action (identical bytes through another path)"
          ( \root scratch -> do
              copyFile (root </> operationFile) (scratch </> "outside-action.ts")
              removeFile (root </> operationFile)
              createLink (scratch </> "outside-action.ts") (root </> operationFile)
          )
          [v op managedHardLinkMessage]
      , Attack
          "deployable migrations inside the root"
          (rootOnly (\root -> createDirectory (root </> "migrations") >> writeFile (root </> "migrations" </> "migration.sql") "alter table x;\n"))
          [ v "migrations" "deployable migrations are not part of the clean source profile (migrate only in a temporary copy)"
          , v "migrations/migration.sql" "an unexpected file is not part of the closed path inventory"
          ]
      , Attack
          "installation and build outputs inside the root"
          ( rootOnly $ \root -> do
              createDirectory (root </> "node_modules")
              createDirectory (root </> ".wasp")
              writeFile (root </> "package-lock.json") "{}\n"
              writeFile (root </> ".env.server") "DATABASE_URL=x\n"
          )
          [ v ".env.server" "environment files are not part of the clean source profile"
          , v ".wasp" "installation and build outputs (node_modules, .wasp) are not part of the clean source profile"
          , v "node_modules" "installation and build outputs (node_modules, .wasp) are not part of the clean source profile"
          , v "package-lock.json" "a dependency lockfile is not part of the clean source profile (dependency drift)"
          ]
      , Attack
          "tampered manifest"
          (rootOnly (replaceIn "mithril.manifest.json" "\"floor\": { \"rank\": 1" "\"floor\": { \"rank\": 0"))
          [v "mithril.manifest.json" "the managed file differs from the regenerated bundle"]
      , Attack
          "missing managed files"
          (rootOnly (\root -> removeFile (root </> "vite.config.ts") >> removeFile (root </> "src" </> "MainPage.tsx")))
          [ v "src/MainPage.tsx" "the managed file is missing"
          , v "vite.config.ts" "the managed file is missing"
          ]
      , Attack
          "tampered ignore and TypeScript configuration"
          (rootOnly (\root -> append ".gitignore" "!.env\n" root >> replaceIn "tsconfig.wasp.json" "\"strict\": true" "\"strict\": false" root))
          [ v ".gitignore" "the managed file differs from the regenerated bundle"
          , v "tsconfig.wasp.json" "the managed file differs from the regenerated bundle"
          ]
      ]

--------------------------------------------------------------------
-- Group 7: installation
--------------------------------------------------------------------

installationChecks :: WaspBundle -> IO [Check]
installationChecks bundle = do
  variantBundle <- variantBundleOf "string-scope"
  orderBundle <- variantBundleOf "declaration-order"
  let expectedFiles = bundleBytes bundle

  absent <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    outcome <- installBundle noInstallHooks bundle root
    files <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure (outcome == Right () && files == expectedFiles && leftovers == ["app"])

  empty <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    createDirectory root
    outcome <- installBundle noInstallHooks bundle root
    files <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure (outcome == Right () && files == expectedFiles && leftovers == ["app"])

  valid <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    outcome <- installBundle noInstallHooks bundle root
    files <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure (outcome == Right () && files == expectedFiles && leftovers == ["app"])

  altered <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    ByteString.writeFile (root </> operationFile) "tampered\n"
    ByteString.appendFile (root </> ".gitignore") "!.env\n"
    outcome <- installBundle noInstallHooks bundle root
    files <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure (outcome == Right () && files == expectedFiles && leftovers == ["app"])

  partial <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    removeDirectoryRecursive (root </> "src")
    removeFile (root </> "main.wasp.ts")
    outcome <- installBundle noInstallHooks bundle root
    files <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure (outcome == Right () && files == expectedFiles && leftovers == ["app"])

  unmanaged <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    writeFile (root </> "notes.txt") "keep me\n"
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallNotOwned (ConfinementViolation "notes.txt" "an unexpected file is not part of the closed path inventory" :| []))
          && before == after
          && leftovers == ["app"]
      )

  unmarked <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    createDirectory root
    ByteString.writeFile (root </> ".gitignore") (fileOf bundle ".gitignore")
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure (outcome == Left (InstallNotOwned (markerViolation :| [])) && before == after && leftovers == ["app"])

  effectiveUser <- getEffectiveUserID
  readOnly <-
    if effectiveUser == 0
      then pure True
      else withScratchDirectory $ \scratch -> do
        let parent = scratch </> "locked"
            root = parent </> "app"
        createDirectory parent
        _ <- installBundle noInstallHooks bundle root
        before <- snapshotDirectory root
        permissions <- getPermissions parent
        setPermissions parent permissions {writable = False}
        outcome <- installBundle noInstallHooks bundle root
        setPermissions parent permissions
        after <- snapshotDirectory root
        leftovers <- listDirectory parent
        pure
          ( outcome == Left (InstallWorkspaceFailure "creating the staging directory failed: permission denied")
              && before == after
              && leftovers == ["app"]
          )

  regularFile <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    writeFile root "x"
    outcome <- installBundle noInstallHooks bundle root
    content <- readFile root
    leftovers <- listDirectory scratch
    pure (outcome == Left (InstallUnusableRoot "is not a directory") && content == "x" && leftovers == ["app"])

  rootLink <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    createDirectory (scratch </> "real")
    createDirectoryLink (scratch </> "real") root
    outcome <- installBundle noInstallHooks bundle root
    realEntries <- listDirectory (scratch </> "real")
    leftovers <- listDirectory scratch
    pure (outcome == Left (InstallUnusableRoot "is a symbolic link") && null realEntries && sort leftovers == ["app", "real"])

  danglingLink <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    createDirectoryLink (scratch </> "nowhere") root
    outcome <- installBundle noInstallHooks bundle root
    leftovers <- listDirectory scratch
    pure (outcome == Left (InstallUnusableRoot "is a symbolic link") && leftovers == ["app"])

  staleStaging <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    createDirectory (stagingPathOf root)
    writeFile (stagingPathOf root </> "leftover") "x"
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    stagingStill <- doesDirectoryExist (stagingPathOf root)
    pure
      ( outcome == Left (InstallWorkspaceFailure "creating the staging directory failed: already exists")
          && before == after
          && stagingStill
      )

  staleBackup <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    createDirectory (backupPathOf root)
    writeFile (backupPathOf root </> "leftover") "x"
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    backupFiles <- snapshotDirectory (backupPathOf root)
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a directory"))
          && before == after
          && backupFiles == [("leftover", "x")]
          && sort leftovers == ["app", "app.mithril-wasp-backup"]
      )

  emptyBackup <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    createDirectory (backupPathOf root)
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    backupIsDirectory <- doesDirectoryExist (backupPathOf root)
    backupIsLink <- pathIsSymbolicLink (backupPathOf root)
    backupEntries <- listDirectory (backupPathOf root)
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a directory"))
          && before == after
          && backupIsDirectory
          && not backupIsLink
          && null backupEntries
          && sort leftovers == ["app", "app.mithril-wasp-backup"]
      )

  fileBackup <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    writeFile (backupPathOf root) "keep\n"
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    content <- readFile (backupPathOf root)
    backupIsLink <- pathIsSymbolicLink (backupPathOf root)
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a regular file"))
          && before == after
          && content == "keep\n"
          && not backupIsLink
          && sort leftovers == ["app", "app.mithril-wasp-backup"]
      )

  symlinkBackup <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    createDirectory (scratch </> "elsewhere")
    writeFile (scratch </> "elsewhere" </> "keep") "keep\n"
    createDirectoryLink (scratch </> "elsewhere") (backupPathOf root)
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    stillLink <- pathIsSymbolicLink (backupPathOf root)
    target <- getSymbolicLinkTarget (backupPathOf root)
    elsewhereFiles <- snapshotDirectory (scratch </> "elsewhere")
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a symbolic link"))
          && before == after
          && stillLink
          && target == scratch </> "elsewhere"
          && elsewhereFiles == [("keep", "keep\n")]
          && sort leftovers == ["app", "app.mithril-wasp-backup", "elsewhere"]
      )

  danglingBackup <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    createFileLink (scratch </> "nowhere") (backupPathOf root)
    before <- snapshotDirectory root
    outcome <- installBundle noInstallHooks bundle root
    after <- snapshotDirectory root
    stillLink <- pathIsSymbolicLink (backupPathOf root)
    target <- getSymbolicLinkTarget (backupPathOf root)
    nowhereExists <- doesPathExist (scratch </> "nowhere")
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a symbolic link"))
          && before == after
          && stillLink
          && target == scratch </> "nowhere"
          && not nowhereExists
          && sort leftovers == ["app", "app.mithril-wasp-backup"]
      )

  absentWithBackup <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    createDirectory (backupPathOf root)
    outcome <- installBundle noInstallHooks bundle root
    rootExists <- doesPathExist root
    backupEntries <- listDirectory (backupPathOf root)
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a directory"))
          && not rootExists
          && null backupEntries
          && leftovers == ["app.mithril-wasp-backup"]
      )

  backupBeforeRename <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    ByteString.writeFile (root </> operationFile) "tampered\n"
    before <- snapshotDirectory root
    let hooks = noInstallHooks {hookAfterStaging = \_ -> createDirectory (backupPathOf root)}
    outcome <- installBundle hooks bundle root
    after <- snapshotDirectory root
    backupIsDirectory <- doesDirectoryExist (backupPathOf root)
    backupEntries <- listDirectory (backupPathOf root)
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a directory"))
          && before == after
          && backupIsDirectory
          && null backupEntries
          && sort leftovers == ["app", "app.mithril-wasp-backup"]
      )

  backupLinkBeforeRename <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    ByteString.writeFile (root </> operationFile) "tampered\n"
    before <- snapshotDirectory root
    let hooks = noInstallHooks {hookAfterStaging = \_ -> createFileLink (scratch </> "nowhere") (backupPathOf root)}
    outcome <- installBundle hooks bundle root
    after <- snapshotDirectory root
    stillLink <- pathIsSymbolicLink (backupPathOf root)
    target <- getSymbolicLinkTarget (backupPathOf root)
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot (backupOccupiedReason root "a symbolic link"))
          && before == after
          && stillLink
          && target == scratch </> "nowhere"
          && sort leftovers == ["app", "app.mithril-wasp-backup"]
      )

  privateUnderUmask <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    stagingBits <- newIORef []
    let hooks =
          noInstallHooks
            { hookAfterStaging = \staging -> do
                bits <- directoryPermissionBits staging
                modifyStaging <- readIORef stagingBits
                writeIORef stagingBits (bits : modifyStaging)
            }
    previous <- setFileCreationMask 0
    (first, second) <-
      ( do
          first <- installBundle hooks bundle root
          ByteString.writeFile (root </> operationFile) "tampered\n"
          second <- installBundle hooks bundle root
          pure (first, second)
        )
        `finally` setFileCreationMask previous
    staged <- readIORef stagingBits
    rootBits <- directoryPermissionBits root
    files <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure
      ( first == Right ()
          && second == Right ()
          && staged == [Right privateDirectoryMode, Right privateDirectoryMode]
          && rootBits == Right privateDirectoryMode
          && files == expectedFiles
          && leftovers == ["app"]
      )

  privateUnderAmbientUmask <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    outcome <- installBundle noInstallHooks bundle root
    rootBits <- directoryPermissionBits root
    pure (outcome == Right () && rootBits == Right privateDirectoryMode)

  privateAfterWideRoot <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    setFileMode root 0o755
    wideBits <- directoryPermissionBits root
    outcome <- installBundle noInstallHooks bundle root
    rootBits <- directoryPermissionBits root
    files <- snapshotDirectory root
    pure
      ( wideBits == Right 0o755
          && outcome == Right ()
          && rootBits == Right privateDirectoryMode
          && files == expectedFiles
      )

  failedSwapRestored <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    ByteString.writeFile (root </> operationFile) "tampered\n"
    before <- snapshotDirectory root
    let hooks = noInstallHooks {hookAfterBackup = \_ -> removeDirectoryRecursive (stagingPathOf root)}
    outcome <- installBundle hooks bundle root
    after <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallWorkspaceFailure "installing the staged bundle failed: does not exist; the previous root was restored")
          && before == after
          && leftovers == ["app"]
      )

  failedSwapUnrestored <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    ByteString.writeFile (root </> operationFile) "tampered\n"
    before <- snapshotDirectory root
    let hooks = noInstallHooks {hookAfterBackup = \_ -> writeFile root "intruder"}
    outcome <- installBundle hooks bundle root
    backupFiles <- snapshotDirectory (backupPathOf root)
    intruder <- readFile root
    leftovers <- listDirectory scratch
    pure
      ( outcome
          == Left
            ( InstallWorkspaceFailure
                ( Text.pack
                    ( "installing the staged bundle failed: inappropriate type; restoring the previous root failed: inappropriate type; the previous root remains at "
                        <> backupPathOf root
                    )
                )
            )
          && backupFiles == before
          && intruder == "intruder"
          && sort leftovers == ["app", "app.mithril-wasp-backup"]
      )

  linkBeforeRevalidation <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    before <- snapshotDirectory root
    let hooks =
          noInstallHooks
            { hookAfterStaging = \_ -> do
                renameDirectory root (scratch </> "moved")
                createDirectoryLink (scratch </> "moved") root
            }
    outcome <- installBundle hooks bundle root
    stillLink <- pathIsSymbolicLink root
    movedFiles <- snapshotDirectory (scratch </> "moved")
    leftovers <- listDirectory scratch
    pure
      ( outcome == Left (InstallUnusableRoot "is a symbolic link")
          && stillLink
          && movedFiles == before
          && sort leftovers == ["app", "moved"]
      )

  fileBeforeRevalidation <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- installBundle noInstallHooks bundle root
    let hooks =
          noInstallHooks
            { hookAfterStaging = \_ -> do
                renameDirectory root (scratch </> "moved")
                writeFile root "intruder"
            }
    outcome <- installBundle hooks bundle root
    intruder <- readFile root
    leftovers <- listDirectory scratch
    pure (outcome == Left (InstallUnusableRoot "is not a directory") && intruder == "intruder" && sort leftovers == ["app", "moved"])

  parentLinkBeforeRevalidation <- withScratchDirectory $ \scratch -> do
    let parent = scratch </> "parent"
        root = parent </> "app"
    createDirectory parent
    _ <- installBundle noInstallHooks bundle root
    before <- snapshotDirectory root
    let hooks =
          noInstallHooks
            { hookAfterStaging = \_ -> do
                renameDirectory parent (scratch </> "parent.real")
                createDirectoryLink (scratch </> "parent.real") parent
            }
    outcome <- installBundle hooks bundle root
    after <- snapshotDirectory (scratch </> "parent.real" </> "app")
    realEntries <- listDirectory (scratch </> "parent.real")
    pure
      ( outcome == Left (InstallUnusableRoot (Text.pack ("its ancestor " <> parent <> " is a symbolic link")))
          && after == before
          && realEntries == ["app"]
      )

  parentFileBeforeRevalidation <- withScratchDirectory $ \scratch -> do
    let parent = scratch </> "parent"
        root = parent </> "app"
    createDirectory parent
    _ <- installBundle noInstallHooks bundle root
    before <- snapshotDirectory root
    let hooks =
          noInstallHooks
            { hookAfterStaging = \_ -> do
                renameDirectory parent (scratch </> "parent.real")
                writeFile parent "intruder"
            }
    outcome <- installBundle hooks bundle root
    after <- snapshotDirectory (scratch </> "parent.real" </> "app")
    realEntries <- listDirectory (scratch </> "parent.real")
    pure
      ( outcome
          == Left
            ( InstallWorkspaceFailure
                ( Text.pack
                    ( "the destination became unusable before the swap: its ancestor " <> parent
                        <> " is not a directory; removing the staging directory failed: inappropriate type; it remains at "
                        <> stagingPathOf root
                    )
                )
            )
          && after == before
          && sort realEntries == ["app", "app.mithril-wasp-staging"]
      )

  ancestorLinks <- withScratchDirectory $ \scratch -> do
    createDirectory (scratch </> "real1")
    createDirectory (scratch </> "real1" </> "real2")
    createDirectoryLink (scratch </> "real1") (scratch </> "link1")
    createDirectoryLink (scratch </> "real1" </> "real2") (scratch </> "real1" </> "link2")
    single <- generateWaspApp nspePath (scratch </> "link1" </> "app")
    nested <- generateWaspApp nspePath (scratch </> "link1" </> "link2" </> "app")
    deep <- generateWaspApp nspePath (scratch </> "real1" </> "link2" </> "app")
    real2Entries <- listDirectory (scratch </> "real1" </> "real2")
    real1Entries <- listDirectory (scratch </> "real1")
    pure
      ( single == Left (WaspRootError (scratch </> "link1" </> "app") (Text.pack ("its ancestor " <> scratch </> "link1" <> " is a symbolic link")))
          && nested == Left (WaspRootError (scratch </> "link1" </> "link2" </> "app") (Text.pack ("its ancestor " <> scratch </> "link1" <> " is a symbolic link")))
          && deep == Left (WaspRootError (scratch </> "real1" </> "link2" </> "app") (Text.pack ("its ancestor " <> scratch </> "real1" </> "link2" <> " is a symbolic link")))
          && null real2Entries
          && sort real1Entries == ["link2", "real2"]
      )

  lexical <- withScratchDirectory $ \scratch -> do
    createDirectory (scratch </> "sub")
    dot <- generateWaspApp nspePath (scratch </> "." </> "app")
    dotDot <- generateWaspApp nspePath (scratch </> "sub" </> ".." </> "escaped-app")
    empty' <- generateWaspApp nspePath (scratch ++ "/sub//app")
    trailing <- generateWaspApp nspePath (scratch ++ "/app/")
    trailingCheck <- checkWaspApp nspePath (scratch ++ "/sub/")
    checkDot <- checkWaspApp nspePath (scratch </> "." </> "app")
    entries <- listDirectory scratch
    pure
      ( dot == Left (WaspRootError (scratch </> "." </> "app") dotComponentReason)
          && dotDot == Left (WaspRootError (scratch </> "sub" </> ".." </> "escaped-app") dotComponentReason)
          && empty' == Left (WaspRootError (scratch ++ "/sub//app") emptyComponentReason)
          && trailing == Left (WaspRootError (scratch ++ "/app/") emptyComponentReason)
          && trailingCheck == Left (WaspRootError (scratch ++ "/sub/") emptyComponentReason)
          && checkDot == Left (WaspRootError (scratch </> "." </> "app") dotComponentReason)
          && entries == ["sub"]
      )

  regeneration <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    first <- generateWaspApp nspePath root
    renamed <- generateWaspApp (renameDirectoryPath </> "string-scope.mir.json") root
    renamedFiles <- snapshotDirectory root
    reordered <- generateWaspApp (renameDirectoryPath </> "declaration-order.mir.json") root
    reorderedFiles <- snapshotDirectory root
    back <- generateWaspApp nspePath root
    backFiles <- snapshotDirectory root
    leftovers <- listDirectory scratch
    pure
      ( isGenerated first
          && isGenerated renamed
          && fmap bundleBytes variantBundle == Just renamedFiles
          && isGenerated reordered
          && fmap bundleBytes orderBundle == Just reorderedFiles
          && isGenerated back
          && backFiles == expectedFiles
          && leftovers == ["app"]
      )

  pure
    [ check "install into an absent destination initializes the complete bundle" absent
    , check "install into an empty destination initializes the complete bundle" empty
    , check "install over a valid owned root replaces it with the complete bundle and leaves nothing behind" valid
    , check "install over an owned root with altered managed files recovers the complete bundle" altered
    , check "install over a partial owned root recovers the complete bundle" partial
    , check "install over an owned root holding an unmanaged path is refused without mutation" unmanaged
    , check "install over an unmarked nonempty root is refused without mutation" unmarked
    , check "install under a read-only parent fails at staging and leaves the old root complete (skipped as root)" readOnly
    , check "install onto a regular file is refused without mutation" regularFile
    , check "install onto a root that is a symbolic link is refused without mutation" rootLink
    , check "install onto a dangling symbolic link is refused" danglingLink
    , check "a stale staging directory refuses the install before any mutation" staleStaging
    , check "a stale nonempty backup directory refuses the install before any mutation and is never touched" staleBackup
    , check "an empty backup directory refuses the install before any mutation and is never replaced" emptyBackup
    , check "a regular file at the backup path refuses the install and keeps its bytes" fileBackup
    , check "a symbolic link at the backup path refuses the install, is never followed, and keeps its target" symlinkBackup
    , check "a dangling symbolic link at the backup path refuses the install and keeps its target" danglingBackup
    , check "an occupied backup path refuses even an install into an absent destination" absentWithBackup
    , check "a backup directory appearing between staging and the pre-rename revalidation refuses the swap and stays untouched" backupBeforeRename
    , check "a backup symbolic link appearing between staging and the pre-rename revalidation refuses the swap and stays untouched" backupLinkBeforeRename
    , check "under umask 000 the staging directory and the installed root carry the private mode 0700, initialized and replaced" privateUnderUmask
    , check "under the ambient umask the installed root carries the private mode 0700" privateUnderAmbientUmask
    , check "regenerating over an owned root with wide permission bits installs a private root" privateAfterWideRoot
    , check "a failed swap with a successful rollback leaves the complete old root" failedSwapRestored
    , check "a failed swap whose rollback also fails leaves the complete old root at the named backup" failedSwapUnrestored
    , check "a root replaced by a symbolic link before the final revalidation is refused and the staging removed" linkBeforeRevalidation
    , check "a root replaced by a regular file before the final revalidation is refused" fileBeforeRevalidation
    , check "a parent replaced by a symbolic link before the final revalidation is refused" parentLinkBeforeRevalidation
    , check "a parent replaced by a regular file before the final revalidation is refused and the stranded staging named" parentFileBeforeRevalidation
    , check "single and nested ancestor symbolic links are refused before any write" ancestorLinks
    , check "lexical dot, dot-dot, empty, and trailing-separator path components are refused, never normalized" lexical
    , check "regeneration after a supported rename and after a meaningful generated-byte change needs no manual step" regeneration
    , check
        "the lexical root rule is pinned"
        ( lexicalRootPath "/work" "app" == Right "/work/app"
            && lexicalRootPath "/work" "app/" == Left emptyComponentReason
            && lexicalRootPath "/work" "/tmp/app/" == Left emptyComponentReason
            && lexicalRootPath "/work" "app//" == Left emptyComponentReason
            && lexicalRootPath "/work" "//" == Left emptyComponentReason
            && lexicalRootPath "/work" "/abs/app" == Right "/abs/app"
            && lexicalRootPath "/work" "/app" == Right "/app"
            && lexicalRootPath "/" "app" == Right "/app"
            && lexicalRootPath "/work" "" == Left "is empty"
            && lexicalRootPath "/work" "./app" == Left dotComponentReason
            && lexicalRootPath "/work" "sub/../app" == Left dotComponentReason
            && lexicalRootPath "/work" "." == Left dotComponentReason
            && lexicalRootPath "/work" ".." == Left dotComponentReason
            && lexicalRootPath "/work" "a//b" == Left emptyComponentReason
            && lexicalRootPath "/work" "/" == Left "is the filesystem root"
        )
    ]
  where
    backupOccupiedReason root kind =
      Text.pack
        ( "its backup path "
            <> backupPathOf root
            <> " already exists ("
            <> kind
            <> ") and is never replaced; move it away first"
        )
    emptyComponentReason =
      "contains an empty path component (a doubled or trailing separator); pass a path without empty components"
    dotComponentReason =
      "contains a dot path component (. or ..); pass a path without dot components"
    isGenerated outcome =
      case outcome of
        Right (WaspGenerated _) -> True
        _ -> False
    variantBundleOf name = do
      bytes <- ByteString.readFile (renameDirectoryPath </> name <> ".mir.json")
      pure (rightMaybe =<< fmap renderWaspBundle (pipelineDocument bytes))

--------------------------------------------------------------------
-- Group 8: command outcomes
--------------------------------------------------------------------

commandOutcomeChecks :: WaspBundle -> IO [Check]
commandOutcomeChecks bundle = do
  fresh <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    first <- generateWaspApp nspePath root
    files <- snapshotDirectory root
    second <- generateWaspApp nspePath root
    filesAgain <- snapshotDirectory root
    checked <- checkWaspApp nspePath root
    leftovers <- listDirectory scratch
    pure (first, files, second, filesAgain, checked, leftovers)
  collision <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    createDirectory root
    writeFile (root </> "notes.txt") "keep me\n"
    outcome <- generateWaspApp nspePath root
    entries <- listDirectory root
    pure (outcome, entries)
  unsafeRoots <- withScratchDirectory $ \scratch -> do
    writeFile (scratch </> "file") "x"
    createDirectoryLink scratch (scratch </> "link")
    fileOutcome <- generateWaspApp nspePath (scratch </> "file")
    linkOutcome <- generateWaspApp nspePath (scratch </> "link")
    missingParent <- generateWaspApp nspePath (scratch </> "missing" </> "deeper" </> "app")
    pure (fileOutcome, linkOutcome, missingParent)
  missingRoot <- withScratchDirectory $ \scratch -> checkWaspApp nspePath (scratch </> "absent")
  unsupported <- checkWaspApp acmePath fixtureRoot
  invalid <- checkWaspApp "test/fixtures/malformed.mir.json" fixtureRoot
  validateOutcome <- validateCoreFile "test/fixtures/malformed.mir.json"
  generatedUnsupported <- withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    _ <- generateWaspApp nspePath root
    before <- snapshotDirectory root
    fresh' <- generateWaspApp unsafePath (scratch </> "fresh")
    existing <- generateWaspApp unsafePath root
    after <- snapshotDirectory root
    entries <- listDirectory scratch
    pure (fresh', existing, before == after, entries)
  let (first, files, second, filesAgain, checked, leftovers) = fresh
      (collisionOutcome, collisionEntries) = collision
      (fileOutcome, linkOutcome, missingParent) = unsafeRoots
      (unsupportedFresh, unsupportedExisting, untouched, unsupportedEntries) = generatedUnsupported
  pure
    [ check
        "generate into a fresh root writes exactly the bundle and reports GENERATED"
        (isGeneratedInto (fixtureReportFor first) first && files == bundleBytes bundle)
    , check
        "regeneration into the managed root succeeds and changes nothing"
        (isGeneratedInto (fixtureReportFor second) second && filesAgain == files)
    , check
        "a generated root passes check with the CONFINED report"
        ( case checked of
            Right (WaspConfined completed) ->
              reportCore completed == nspePath && reportSummary completed == waspBundleSummary bundle
            _ -> False
        )
    , check
        "generation leaves no staging or backup material beside the root"
        (leftovers == ["app"])
    , check
        "an unmarked root holding an unmanaged file is refused with exit 4 and nothing is written"
        ( collisionOutcome
            == Right
              ( WaspNotConfined
                  (collisionRoot collisionOutcome)
                  (markerViolation :| [ConfinementViolation "notes.txt" "an unexpected file is not part of the closed path inventory"])
              )
            && collisionEntries == ["notes.txt"]
        )
    , check
        "a root that is a file, a symbolic link, or under a missing parent is unusable"
        ( isRootError "is not a directory" fileOutcome
            && isRootError "is a symbolic link" linkOutcome
            && isRootError "its parent directory does not exist" missingParent
        )
    , check
        "check on a missing root is unusable with the exact reason"
        (isRootError "does not exist" missingRoot)
    , check
        "the canonical Acme document is unsupported to both commands with the verifier's reasons"
        ( case unsupported of
            Right (WaspUnsupported reasons) -> length reasons == 3
            _ -> False
        )
    , check
        "an unsupported document neither creates a root nor replaces an existing one"
        ( case (unsupportedFresh, unsupportedExisting) of
            (Right (WaspUnsupported _), Right (WaspUnsupported _)) -> untouched && unsupportedEntries == ["app"]
            _ -> False
        )
    , check
        "an invalid document keeps the validate classification byte-identically"
        ( case (invalid, validateOutcome) of
            (Left (WaspInputError actual), Left expected) -> actual == expected
            _ -> False
        )
    ]
  where
    fixtureReportFor outcome =
      case outcome of
        Right (WaspGenerated completed) -> Just (reportRoot completed)
        _ -> Nothing
    isGeneratedInto expectedRoot outcome =
      case (expectedRoot, outcome) of
        (Just root, Right (WaspGenerated completed)) ->
          reportRoot completed == root
            && reportCore completed == nspePath
            && reportSummary completed == waspBundleSummary bundle
        _ -> False
    collisionRoot outcome =
      case outcome of
        Right (WaspNotConfined root _) -> root
        _ -> ""
    isRootError reason outcome =
      case outcome of
        Left (WaspRootError _ actual) -> actual == reason
        _ -> False

--------------------------------------------------------------------
-- Rendering and exit classification
--------------------------------------------------------------------

renderingChecks :: WaspBundle -> [Check]
renderingChecks bundle =
  [ check
      "the CONFINED report renders deterministically with the verification gate and the inventory"
      ( renderWaspSuccess nspePath (WaspConfined completed)
          == Text.intercalate
            "\n"
            ( [ "app: CONFINED (Wasp Confinement Profile v0)"
              , "  core: test/fixtures/acme-nspe.mir.json"
              , "  verification: VERIFIED by the production verifier before the bundle was rendered"
              , "  guarantee: NoSelfPrivilegeEscalation"
              , "  case action: \"Membership.changeRole\""
              , "  operation: mithrilCaseAction (POST /operations/mithril-case-action)"
              , "  target: Wasp 0.25.0, PostgreSQL, Prisma runtime supplied by Wasp"
              , "  managed files: 14"
              ]
                <> ["    " <> Text.pack path | path <- expectedInventory]
            )
      )
  , check
      "the GENERATED report states the verification gate and ends with the confinement line"
      ( "\n  confinement: CONFINED" `Text.isSuffixOf` renderWaspSuccess nspePath (WaspGenerated completed)
          && "app: GENERATED (Wasp Confinement Profile v0)\n  core: test/fixtures/acme-nspe.mir.json\n  verification: VERIFIED by the production verifier before the bundle was rendered\n"
            `Text.isPrefixOf` renderWaspSuccess nspePath (WaspGenerated completed)
      )
  , check
      "the NOT CONFINED report escapes hostile paths and messages on single lines"
      ( renderWaspSuccess
          nspePath
          ( WaspNotConfined
              "app"
              (ConfinementViolation "evil\nname" "why\ESC" :| [ConfinementViolation "b" "c"])
          )
          == "app: NOT CONFINED (Wasp Confinement Profile v0)\n  evil\\nname: why\\ESC\n  b: c"
      )
  , check
      "the unsupported report renders under the Wasp support rule heading"
      ( renderWaspSuccess "doc.mir.json" (WaspUnsupported (UnsupportedReason ["guarantees"] "why" :| []))
          == "doc.mir.json: UNSUPPORTED by the implemented Wasp support rule\n  /guarantees: why"
      )
  , check
      "failures render with their pinned prefixes and no violation verdict"
      ( renderWaspFailure (WaspRootError "app" "is a symbolic link")
          == "app: unusable Wasp root\n  is a symbolic link"
          && renderWaspFailure (WaspWorkspaceError "installing the staged bundle failed: permission denied; the previous root was restored")
            == "mithril: internal Core Wasp emitter error: the generated bundle could not be installed\n  installing the staged bundle failed: permission denied; the previous root was restored"
          && renderWaspFailure (WaspRenderInvariantError (VerifierInvariantViolation ["x"] "drift" :| []))
            == "mithril: internal Core Wasp emitter error: the normalized document does not match the Wasp emitter's Core v0 interpretation\n  /x: drift"
      )
  , check
      "exit classifications are pinned"
      ( waspSuccessExitCode (WaspGenerated completed) == ExitSuccess
          && waspSuccessExitCode (WaspConfined completed) == ExitSuccess
          && waspSuccessExitCode (WaspUnsupported (UnsupportedReason [] "x" :| [])) == ExitFailure 3
          && waspSuccessExitCode (WaspNotConfined "app" (ConfinementViolation "a" "b" :| [])) == ExitFailure 4
          && waspFailureExitCode (WaspRootError "app" "x") == ExitFailure 1
          && waspFailureExitCode (WaspWorkspaceError "x") == ExitFailure 2
          && waspFailureExitCode (WaspRenderInvariantError (VerifierInvariantViolation [] "x" :| [])) == ExitFailure 2
          && waspFailureExitCode (WaspInputError (FileReadError "f" "gone")) == ExitFailure 1
      )
  ]
  where
    completed =
      WaspReport
        { reportCore = nspePath
        , reportRoot = "app"
        , reportSummary = waspBundleSummary bundle
        }

--------------------------------------------------------------------
-- Scratch plumbing
--------------------------------------------------------------------

-- | A fresh scratch directory (openTempFile-anchored) under the
-- canonical temporary directory — so no ancestor is a symbolic link
-- — removed afterwards with everything the action put in it.
withScratchDirectory :: (FilePath -> IO a) -> IO a
withScratchDirectory action = do
  temporaryBase <- canonicalizePath =<< getTemporaryDirectory
  (anchorPath, handle) <- openTempFile temporaryBase "mithril-wasp-tests.txt"
  hClose handle
  let root = anchorPath ++ ".d"
  createDirectory root
  outcome <- try (action root)
  restoreWritable root
  removeDirectoryRecursive root
  removeFile anchorPath
  case outcome of
    Left failure -> ioError (userError (show (failure :: SomeException)))
    Right result -> pure result
  where
    -- A check may have made a directory read-only; make the tree
    -- writable again before removing it.
    restoreWritable path = do
      isLink <- pathIsSymbolicLink path
      isDirectory <- if isLink then pure False else doesDirectoryExist path
      if isDirectory
        then do
          permissions <- getPermissions path
          setPermissions path permissions {writable = True}
          names <- listDirectory path
          forM_ names (\name -> restoreWritable (path </> name))
        else pure ()

-- | Run an action on a fresh copy of the committed fixture, given
-- the scratch directory and the copy's root inside it.
withFixtureCopy :: (FilePath -> FilePath -> IO a) -> IO a
withFixtureCopy action =
  withScratchDirectory $ \scratch -> do
    let root = scratch </> "app"
    copyTree fixtureRoot root
    action scratch root

copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
  createDirectoryIfMissing True to
  names <- listDirectory from
  forM_ names $ \name -> do
    let source = from </> name
        destination = to </> name
    isDirectory <- doesDirectoryExist source
    if isDirectory then copyTree source destination else copyFile source destination

-- | Every regular file below a directory as (relative path, bytes),
-- sorted; symbolic links and other entries are reported with a
-- marker byte string so an unexpected entry never compares equal to a
-- managed file.  A missing directory snapshots as empty.
snapshotDirectory :: FilePath -> IO [(FilePath, ByteString)]
snapshotDirectory root = do
  present <- doesPathExist root
  isLink <- if present then pathIsSymbolicLink root else pure False
  isDirectory <- if present && not isLink then doesDirectoryExist root else pure False
  if isDirectory then sort <$> walk "" else pure []
  where
    walk relative = do
      names <- listDirectory (if null relative then root else root </> relative)
      concat <$> forM names (\name -> entry (if null relative then name else relative <> "/" <> name))
    entry relativePath = do
      let fullPath = root </> relativePath
      isLink <- pathIsSymbolicLink fullPath
      if isLink
        then pure [(relativePath, "<symbolic link>")]
        else do
          isDirectory <- doesDirectoryExist fullPath
          if isDirectory
            then walk relativePath
            else do
              bytes <- ByteString.readFile fullPath
              pure [(relativePath, bytes)]
