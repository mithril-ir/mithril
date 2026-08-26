{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The pure half of the Wasp Confinement Profile v0 checker: given the
-- regenerated bundle ("Mithril.Core.Internal.Wasp") and a snapshot of
-- a source root (every entry, taken without following symbolic links
-- and with hard links classified — "Mithril.Core.Internal.WaspFilesystem"
-- takes it), decide deterministically whether the root is exactly
-- the closed profile, or — before a regeneration — whether the root
-- is one this tool owns and may replace.
--
-- == The authority
--
-- The authority is the regenerated closed path inventory plus exact
-- bytes: every managed file of the bundle must be present as a
-- private regular file (link count one) with byte-identical content,
-- and nothing else may exist in the root except the directories the
-- managed paths require.  Missing, altered, hard-linked, and
-- unexpected inputs are all violations.  The denylist scan below is
-- deliberately /not/ the authority — a file that differs from the
-- bundle or lies outside the inventory is already rejected; the scan
-- only labels /why/ a rejected file is dangerous (a second Prisma
-- import, a raw-query API, a database driver, dynamic code, an
-- additional operation or server path, dependency or
-- database-provider drift), so a reviewer sees the bypass by name.
--
-- == The snapshot itself is validated first
--
-- Before any path is looked up, every supplied snapshot path must be
-- a canonical root-relative path (no leading separator, no empty,
-- dot, or dot-dot component) and no two entries may name the same
-- path — neither literally nor after alias normalization.  A snapshot
-- violating this is rejected with those diagnostics alone, so no
-- duplicate, aliased, or absolute entry can ever shadow, resolve, or
-- mask another; the result is independent of the entries' order.
--
-- == Ownership
--
-- 'OwnershipCheck' is the rule a regeneration applies to an existing
-- root before replacing it as a whole: an empty root may be
-- initialized; a nonempty root may be replaced only if it carries
-- the byte-exact Mithril ownership marker and holds nothing outside
-- the fixed inventory (altered or missing managed files are
-- recoverable and permitted); an unmarked nonempty root, an
-- unmanaged path, a symbolic link, a hard link, or a foreign entry
-- kind refuses the replacement.
--
-- Diagnostics are deterministic: path-labelled, sorted, and
-- deduplicated.  Paths are root-relative with forward slashes.
module Mithril.Core.Internal.WaspConfinement
  ( -- * Root snapshots
    RootEntry (..)
  , EntryKind (..)

    -- * Checking
  , ConfinementMode (..)
  , ConfinementViolation (..)
  , checkConfinement
  , validateSnapshot
  , normalizeConfinementViolations
  , scanFindings
  ) where

import Data.ByteString (ByteString)
import Data.Char (isAlphaNum)
import Data.List (isPrefixOf, isSuffixOf, sort)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding

import Mithril.Core.Internal.Wasp
  ( WaspBundle
  , WaspManagedFile (..)
  , bundleFiles
  , operationPath
  , ownershipMarkerPath
  , packagePath
  , schemaPath
  )

--------------------------------------------------------------------
-- Root snapshots
--------------------------------------------------------------------

-- | What one entry of the source root is.  The walker classifies a
-- symbolic link before anything else and never follows it, and
-- classifies a regular file whose link count exceeds one as
-- 'HardLinkedFile' without reading it: its bytes could be changed
-- through another path, so it is never a private managed file.
data EntryKind
  = RegularFile ByteString
  | HardLinkedFile
  | Directory
  | SymbolicLink
  | OtherEntry
  deriving (Eq, Show)

-- | One entry of a source-root snapshot: its root-relative path
-- (forward slashes) and its kind.
data RootEntry = RootEntry
  { entryPath :: FilePath
  , entryKind :: EntryKind
  }
  deriving (Eq, Show)

--------------------------------------------------------------------
-- Checking
--------------------------------------------------------------------

-- | Which rule applies.  'FullCheck' is @mithril wasp check@ and the
-- final step of @generate@: every managed file must be present,
-- private, and byte-identical.  'OwnershipCheck' is the replacement
-- rule of @generate@ over an existing root (module header): an empty
-- snapshot is acceptable, and a nonempty one must carry the exact
-- ownership marker and nothing outside the inventory.
data ConfinementMode
  = FullCheck
  | OwnershipCheck
  deriving (Eq, Show)

-- | One confinement violation: the root-relative path and what is
-- wrong with it.
data ConfinementViolation = ConfinementViolation
  { confinementPath :: Text
  , confinementMessage :: Text
  }
  deriving (Eq, Ord, Show)

-- | Sort violations (by path, then message) and remove duplicates.
normalizeConfinementViolations :: [ConfinementViolation] -> [ConfinementViolation]
normalizeConfinementViolations = map NonEmpty.head . NonEmpty.group . sort

-- | Check a root snapshot against the regenerated bundle (module
-- header).  The result is sorted and deduplicated; empty means the
-- root is exactly the closed profile ('FullCheck') or may be
-- initialized or replaced ('OwnershipCheck').  A snapshot whose
-- entries are not canonical and pairwise distinct is rejected with
-- exactly the 'validateSnapshot' diagnostics, before anything else.
checkConfinement
  :: ConfinementMode -> WaspBundle -> [RootEntry] -> [ConfinementViolation]
checkConfinement mode bundle entries =
  case validateSnapshot entries of
    problems@(_ : _) -> problems
    []
      | mode == OwnershipCheck && null entries -> []
      | otherwise ->
          normalizeConfinementViolations (managedFindings <> unmanagedFindings)
  where
    managed = Map.fromList [(managedPath file, managedBytes file) | file <- bundleFiles bundle]
    present = Map.fromList [(entryPath entry, entryKind entry) | entry <- entries]
    expectedDirectories = Set.fromList (concatMap parentDirectories (Map.keys managed))

    managedFindings =
      concat
        [ classifyManaged path bytes (Map.lookup path present)
        | (path, bytes) <- Map.toList managed
        ]

    classifyManaged path bytes found =
      case found of
        Nothing
          | mode == FullCheck -> [violation path "the managed file is missing"]
          | path == ownershipMarkerPath -> [violation path markerMessage]
          | otherwise -> []
        Just (RegularFile actual)
          | actual == bytes -> []
          | mode == OwnershipCheck && path == ownershipMarkerPath -> [violation path markerMessage]
          | mode == OwnershipCheck -> []
          | otherwise ->
              violation path (differsMessage path)
                : scanFindings path actual
        Just HardLinkedFile ->
          [violation path "the managed path is occupied by a hard-linked regular file (link count above one), not a private managed regular file"]
        Just Directory ->
          [violation path "the managed path is occupied by a directory, not the managed regular file"]
        Just SymbolicLink ->
          [violation path "the managed path is occupied by a symbolic link, not the managed regular file"]
        Just OtherEntry ->
          [violation path "the managed path is occupied by an unsupported filesystem entry, not the managed regular file"]

    unmanagedFindings =
      concat
        [ classifyUnmanaged (entryPath entry) (entryKind entry)
        | entry <- entries
        , not (Map.member (entryPath entry) managed)
        ]

    classifyUnmanaged path kind =
      case kind of
        SymbolicLink ->
          [violation path "a symbolic link is not allowed inside the confined source root (path escape)"]
        HardLinkedFile ->
          violation path (fileMessage path)
            : [violation path "a hard-linked regular file (link count above one) is not allowed inside the confined source root (its bytes can be changed through another path)"]
        Directory
          | Set.member path expectedDirectories -> []
          | otherwise -> [violation path (directoryMessage path)]
        RegularFile bytes ->
          violation path (fileMessage path) : scanFindings path bytes
        OtherEntry ->
          [violation path "an unsupported filesystem entry (neither a regular file nor a directory) is not allowed inside the confined source root"]

    markerMessage =
      "the root carries no byte-exact Mithril ownership marker, so it is not an owned Wasp Confinement Profile v0 root (an unmarked nonempty root is never replaced)"

    differsMessage path
      | path == packagePath =
          "the managed dependency configuration differs from the regenerated bundle (dependency drift)"
      | path == schemaPath =
          "the managed Prisma schema differs from the regenerated bundle (schema or database-provider drift)"
      | path == operationPath =
          "the generated Action differs from the regenerated bundle (edited generated authorization)"
      | otherwise = "the managed file differs from the regenerated bundle"

-- | Validate the shape of a snapshot before any lookup (module
-- header): every path canonical and root-relative, no two entries
-- naming the same path literally or after alias normalization.
-- Sorted, deduplicated, and independent of the entries' order; empty
-- means the snapshot may be checked.
validateSnapshot :: [RootEntry] -> [ConfinementViolation]
validateSnapshot entries =
  normalizeConfinementViolations (shapeProblems <> duplicateProblems)
  where
    shapeProblems =
      [ violation path "the snapshot path is not a canonical root-relative path (no leading separator, no empty, dot, or dot-dot component)"
      | entry <- entries
      , let path = entryPath entry
      , not (isCanonicalPath path)
      ]
    duplicateProblems =
      [ violation key "the snapshot lists this path more than once (duplicate or aliased entries)"
      | (key, count) <-
          Map.toList
            (Map.fromListWith (+) [(aliasKey (entryPath entry), 1 :: Int) | entry <- entries])
      , count > 1
      ]

-- | A canonical root-relative path: non-empty, no leading separator,
-- and no empty, @.@, or @..@ segment.
isCanonicalPath :: FilePath -> Bool
isCanonicalPath path =
  not (null path)
    && not ("/" `isPrefixOf` path)
    && all (\segment -> segment /= "" && segment /= "." && segment /= "..") (rawSegments path)

-- | The path two aliased spellings share: empty and @.@ segments and
-- a leading separator dropped (@..@ is kept, since it cannot be
-- resolved lexically against an unknown parent).
aliasKey :: FilePath -> FilePath
aliasKey path =
  joinSegments (filter (\segment -> segment /= "" && segment /= ".") (rawSegments path))

violation :: FilePath -> Text -> ConfinementViolation
violation path = ConfinementViolation (Text.pack path)

-- | Every proper ancestor directory of a managed path
-- (@src\/x.ts@ ↦ @[src]@).
parentDirectories :: FilePath -> [FilePath]
parentDirectories path =
  case reverse (splitSegments path) of
    [] -> []
    _ : ancestors ->
      [ joinSegments (take n (reverse ancestors))
      | n <- [1 .. length ancestors]
      ]

-- | The segments of a path, empty segments kept.
rawSegments :: FilePath -> [String]
rawSegments = go
  where
    go [] = [[]]
    go ('/' : rest) = [] : go rest
    go (c : rest) =
      case go rest of
        segment : more -> (c : segment) : more
        [] -> [[c]]

splitSegments :: FilePath -> [String]
splitSegments = filter (not . null) . rawSegments

joinSegments :: [String] -> FilePath
joinSegments [] = ""
joinSegments segments = foldr1 (\a b -> a <> "/" <> b) segments

baseName :: FilePath -> String
baseName path =
  case reverse (splitSegments path) of
    name : _ -> name
    [] -> path

directoryMessage :: FilePath -> Text
directoryMessage path
  | name `elem` ["node_modules", ".wasp"] =
      "installation and build outputs (node_modules, .wasp) are not part of the clean source profile"
  | name == "migrations" =
      "deployable migrations are not part of the clean source profile (migrate only in a temporary copy)"
  | name `elem` ["dist", "build", ".git"] =
      "build outputs and version-control directories are not part of the clean source profile"
  | otherwise = "an unexpected directory is not part of the closed path inventory"
  where
    name = baseName path

fileMessage :: FilePath -> Text
fileMessage path
  | name == "package-lock.json" =
      "a dependency lockfile is not part of the clean source profile (dependency drift)"
  | name == ".env" || ".env." `isPrefixOf` name =
      "environment files are not part of the clean source profile"
  | ".wasp.ts" `isSuffixOf` name =
      "an additional Wasp specification file is not part of the closed path inventory"
  | "src/" `isPrefixOf` path && isScriptPath path =
      "an additional server-capable source file is not part of the closed path inventory"
  | otherwise = "an unexpected file is not part of the closed path inventory"
  where
    name = baseName path

isScriptPath :: FilePath -> Bool
isScriptPath path =
  any (`isSuffixOf` path) [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"]

--------------------------------------------------------------------
-- The denylist scan (labels, never the authority)
--------------------------------------------------------------------

-- | Content findings for one file that is already rejected (an
-- unmanaged file, or a managed file whose bytes differ): the named
-- bypass channels it carries.  The generated Action's own path is
-- the only file permitted to import @prisma@ from @wasp\/server@.
scanFindings :: FilePath -> ByteString -> [ConfinementViolation]
scanFindings path bytes =
  map (violation path) (specFindings <> packageFindings <> schemaFindings <> scriptFindings)
  where
    text = Encoding.decodeUtf8Lenient bytes
    isSpec = ".wasp.ts" `isSuffixOf` path
    isScript = isScriptPath path

    specFindings
      | not isSpec = []
      | otherwise =
          [ "the Wasp specification declares " <> what <> ", which the profile does not permit"
          | (token, what) <-
              [ ("query(", "a Query")
              , ("api(", "a custom HTTP API")
              , ("crud(", "a CRUD")
              , ("job(", "a job")
              , ("apiNamespace(", "an API namespace")
              ]
          , occursAsToken token text
          ]
            <> [ "the Wasp specification declares a server setup or middleware path, which the profile does not permit"
               | any (`Text.isInfixOf` text) ["setupFn", "middlewareConfigFn"]
               ]
            <> [ "the Wasp specification declares database seeds or a Prisma setup function, which the profile does not permit"
               | any (`Text.isInfixOf` text) ["seeds", "prismaSetupFn"]
               ]
            <> [ "the Wasp specification declares a WebSocket or email-sender path, which the profile does not permit"
               | any (`Text.isInfixOf` text) ["webSocket", "emailSender"]
               ]
            <> ( case countTokens "action(" text of
                   0 -> ["the Wasp specification no longer declares the generated Action"]
                   1 -> []
                   _ -> ["the Wasp specification declares an additional Action, which the profile does not permit"]
               )

    packageFindings
      | path /= packagePath = []
      | otherwise =
          [ "the dependency configuration declares " <> name <> " (no second ORM or database client is permitted)"
          | name <- databaseLibraries
          , ("\"" <> name <> "\":") `Text.isInfixOf` text
          ]

    schemaFindings
      | path /= schemaPath = []
      | otherwise =
          [ "the Prisma schema does not declare the PostgreSQL datasource provider (database-provider drift)"
          | not ("provider = \"postgresql\"" `Text.isInfixOf` text)
          ]
            <> [ "the Prisma schema declares the database provider " <> provider <> " (database-provider drift)"
               | provider <- ["sqlite", "mysql", "mongodb", "sqlserver", "cockroachdb"]
               , ("\"" <> provider <> "\"") `Text.isInfixOf` text
               ]

    scriptFindings
      | not (isScript || isSpec) = []
      | otherwise =
          [ message
          | (token, message) <- scriptRules
          , occursAsToken token text
          ]
            <> [ "the file imports the database library " <> name <> " (no second ORM or database client is permitted)"
               | name <- databaseLibraries
               , any (`Text.isInfixOf` text) ["\"" <> name <> "\"", "'" <> name <> "'"]
               ]
            <> [ "the file imports prisma from wasp/server outside the generated Action"
               | path /= operationPath
               , "wasp/server" `Text.isInfixOf` text
               , occursAsToken "prisma" text
               ]

    scriptRules =
      [ ("@prisma/client", "the file imports the Prisma client package directly (only the Prisma runtime supplied by Wasp is permitted)")
      , ("$queryRaw", "the file uses a Prisma raw-query API ($queryRaw or $queryRawUnsafe)")
      , ("$executeRaw", "the file uses a Prisma raw-query API ($executeRaw or $executeRawUnsafe)")
      , ("eval(", "the file constructs code with eval")
      , ("Function(", "the file constructs code with the Function constructor")
      , ("import(", "the file uses a dynamic import")
      , ("require(", "the file uses CommonJS require")
      , ("child_process", "the file reaches child_process")
      , ("worker_threads", "the file reaches worker_threads")
      ]

-- | Module specifiers of database drivers and ORMs the profile
-- refuses alongside the Prisma runtime Wasp supplies.
databaseLibraries :: [Text]
databaseLibraries =
  [ "@prisma/client", "pg", "pg-promise", "postgres", "knex", "typeorm"
  , "sequelize", "drizzle-orm", "kysely", "@mikro-orm/core", "mongoose"
  , "mysql", "mysql2", "sqlite3", "better-sqlite3", "@neondatabase/serverless"
  , "@vercel/postgres", "slonik", "objection"
  ]

-- | Does the needle occur where the preceding character is not an
-- identifier character (so @eval(@ matches but @myeval(@ does not,
-- and @Function(@ matches @new Function(@ but not @myFunction(@)?
occursAsToken :: Text -> Text -> Bool
occursAsToken needle haystack = countTokens needle haystack > 0

countTokens :: Text -> Text -> Int
countTokens needle haystack =
  length
    [ ()
    | (before, _) <- Text.breakOnAll needle haystack
    , case Text.unsnoc before of
        Nothing -> True
        Just (_, previous) -> not (isAlphaNum previous || previous == '_' || previous == '$')
    ]
