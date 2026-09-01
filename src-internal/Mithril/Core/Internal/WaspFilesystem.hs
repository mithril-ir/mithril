{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | __Internal module — never expose.__
--
-- The effectful filesystem half of the Wasp Confinement Profile
-- commands, shared by both profiles — Profile v0 (the exact singleton
-- rule-1 plan) and Profile v1 (the exact ordered rule-1, rule-2 pair;
-- every other plan is refused before this module is reached):
-- root-path validation, the no-follow snapshot walker, and the
-- complete-root installation of a rendered bundle of either profile,
-- including the whole-root transitions between them (an owned root of
-- either profile is replaced as a whole by a regeneration of either
-- profile).  The CLI boundary "Mithril.Command.Wasp" is the only
-- production caller; the test suite reaches the installation seam
-- directly to inject faults between its steps.
--
-- == Root paths
--
-- A root argument is accepted only in lexical form.  The grammar is:
-- the path is not empty; split on @\/@, every component is non-empty
-- and is neither @.@ nor @..@ — so a doubled separator, a trailing
-- separator (@app\/@, @\/tmp\/app\/@), @.\/app@, and @sub\/..\/app@ are
-- all rejected, never normalized; the one-character path @\/@ is the
-- filesystem root and is refused as a destination in its own right
-- (its separator is not a trailing empty component).  A relative path
-- is joined to the current working directory, giving one well-defined
-- absolute lexical path.  Every existing ancestor of that path is then
-- inspected with no-follow metadata ('getSymbolicLinkStatus'): an
-- ancestor that is a symbolic link or not a directory refuses the
-- root.  The final root must be a directory or absent; a symbolic
-- link (dangling or not) or any other entry refuses it.  The same
-- validation runs again immediately before the directory swap.
--
-- == Snapshots
--
-- 'snapshotTree' lists a root recursively in a deterministic order,
-- classifying every entry from its no-follow metadata before touching
-- it: a symbolic link is recorded and never followed, a regular file
-- with a link count above one is recorded as hard-linked and never
-- read, and everything that is neither a directory nor a regular
-- file is recorded as an unsupported entry.
--
-- == Installation (the ownership and replacement rule)
--
-- 'installBundle' never writes into a live root file by file.  It
--
-- 1. inspects the destination and decides: absent or empty — the
--    root may be initialized; nonempty — it may be replaced only if
--    'Mithril.Core.Internal.WaspConfinement.OwnershipCheck' accepts
--    the snapshot (the byte-exact ownership marker, nothing outside
--    the fixed inventory, no links, no foreign entries); otherwise it
--    refuses without any mutation;
-- 2. confirms with no-follow metadata that the backup sibling
--    (@\<root\>.mithril-wasp-backup@) is absent: an existing entry of
--    any kind there — an empty or nonempty directory, a regular file,
--    a symbolic link (dangling or not), anything else — refuses the
--    installation, and is never removed, replaced, truncated,
--    followed, or otherwise touched;
-- 3. creates the sibling staging directory (@\<root\>.mithril-wasp-staging@,
--    refused if it already exists) atomically with the requested
--    private mode @0700@ ('System.Posix.Directory.createDirectory'
--    — never created wider and narrowed afterwards), verifies from its
--    no-follow metadata that the permission bits are exactly @0700@
--    (so an unusual umask cannot leave it wider or narrower), and
--    writes every file of the new bundle there;
-- 4. runs the full confinement check against the staging directory;
-- 5. revalidates the ancestors and the destination, and re-decides;
-- 6. when an existing root must be moved aside, repeats the no-follow
--    absence check of the backup sibling immediately before the
--    rename, then renames the existing root to it;
-- 7. renames the complete staging directory into the destination;
--    if that fails, renames the backup back into place;
-- 8. removes the backup only after the new root is installed; and
-- 9. runs the full confinement check over the installed root and
--    confirms the installed root — the very directory created in
--    step 3, so it keeps that mode across the rename — still has the
--    private permission bits @0700@.
--
-- Every failure is classified with a stable operation label plus the
-- classified I\/O error kind, names the backup or staging directory
-- it had to leave behind, and leaves either the complete previous
-- root (in place, or at the named backup) or the complete new root —
-- never a mixture — because the only mutations of the destination
-- are whole-directory renames.
--
-- == Private mode: what it establishes
--
-- The staging directory and therefore the installed root carry the
-- permission bits @0700@ regardless of the process umask (a
-- generation under @umask 000@ still yields a @0700@ root).  Other
-- unprivileged users of the machine therefore cannot traverse, read,
-- link into, or write below the staging tree or the installed root
-- while this tool works or afterwards; the files and the @src@
-- directory inside are created under the ambient umask, which is
-- sufficient because the root itself is not traversable by them.
-- Nothing is claimed against privileged users (root can traverse any
-- mode) or against a malicious process running as the same user,
-- which can chmod, rename, or replace the directories at will.
--
-- == Exclusions (stated, not claimed)
--
-- The validation is path-based: metadata is read by path before the
-- renames, not through descriptor-relative no-follow operations, so a
-- malicious same-user process racing this tool between a check and
-- the operation it guards — including between the second backup
-- absence check and the rename onto the backup path — is outside the
-- claim.  So are POSIX platforms other than the one exercised
-- (Linux): the metadata and the mode-requesting directory creation
-- come from the @unix@ package.
module Mithril.Core.Internal.WaspFilesystem
  ( -- * Root paths
    lexicalRootPath
  , resolveRootPath
  , validateAncestors

    -- * Inspection
  , RootState (..)
  , inspectRoot
  , snapshotTree
  , privateDirectoryMode
  , directoryPermissionBits

    -- * Installation
  , InstallHooks (..)
  , noInstallHooks
  , InstallFailure (..)
  , installBundle
  , stagingPathOf
  , backupPathOf
  ) where

import Control.Exception (IOException, try)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import Data.List (intercalate, isPrefixOf, sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import Numeric (showOct)
import System.Directory
  ( createDirectoryIfMissing
  , getCurrentDirectory
  , listDirectory
  , removeDirectoryRecursive
  , renameDirectory
  )
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (ioeGetErrorType, isDoesNotExistError)
import qualified System.Posix.Directory as Posix (createDirectory)
import System.Posix.Files
  ( FileStatus
  , fileMode
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , linkCount
  )
import System.Posix.Types (FileMode)

import Mithril.Core.Internal.Wasp (WaspBundle, WaspManagedFile (..), bundleFiles)
import Mithril.Core.Internal.WaspConfinement
  ( ConfinementMode (..)
  , ConfinementViolation (..)
  , EntryKind (..)
  , RootEntry (..)
  , checkConfinement
  )

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

-- | The classified kind of an I\/O error — stable and path-free.
describeIOError :: IOException -> Text
describeIOError = Text.pack . show . ioeGetErrorType

--------------------------------------------------------------------
-- Root paths
--------------------------------------------------------------------

-- | The absolute lexical path of a root argument, given the current
-- working directory (module header: the path grammar), or the reason
-- it is refused.
lexicalRootPath :: FilePath -> FilePath -> Either Text FilePath
lexicalRootPath cwd given
  | null given = Left "is empty"
  | given == "/" = Left "is the filesystem root"
  | any null parts = Left emptyComponentReason
  | any (`elem` [".", ".."]) parts = Left dotComponentReason
  | absolute = Right ("/" <> intercalate "/" parts)
  | otherwise = Right (cwd </> intercalate "/" parts)
  where
    absolute = "/" `isPrefixOf` given
    parts = splitOnSeparator (if absolute then drop 1 given else given)
    splitOnSeparator path =
      case break (== '/') path of
        (segment, []) -> [segment]
        (segment, _ : rest) -> segment : splitOnSeparator rest

emptyComponentReason :: Text
emptyComponentReason =
  "contains an empty path component (a doubled or trailing separator); pass a path without empty components"

dotComponentReason :: Text
dotComponentReason =
  "contains a dot path component (. or ..); pass a path without dot components"

-- | Resolve a root argument against the current working directory
-- and validate its ancestors (module header).
resolveRootPath :: FilePath -> IO (Either Text FilePath)
resolveRootPath given = do
  cwd <- getCurrentDirectory
  case lexicalRootPath cwd given of
    Left reason -> pure (Left reason)
    Right absolute -> do
      ancestors <- validateAncestors absolute
      pure (absolute <$ ancestors)

-- | Inspect every existing ancestor of an absolute root path with
-- no-follow metadata: each must be a directory that is not a
-- symbolic link; a missing ancestor means the parent directory does
-- not exist.
validateAncestors :: FilePath -> IO (Either Text ())
validateAncestors absolute = go (ancestorsOf absolute)
  where
    go [] = pure (Right ())
    go (ancestor : deeper) = do
      status <- tryIO (getSymbolicLinkStatus ancestor)
      case status of
        Left _ -> pure (Left "its parent directory does not exist")
        Right metadata
          | isSymbolicLink metadata ->
              pure (Left ("its ancestor " <> Text.pack ancestor <> " is a symbolic link"))
          | isDirectory metadata -> go deeper
          | otherwise ->
              pure (Left ("its ancestor " <> Text.pack ancestor <> " is not a directory"))

-- | The proper ancestors of an absolute path below the filesystem
-- root, outermost first (@\/a\/b\/app@ ↦ @[\/a, \/a\/b]@).
ancestorsOf :: FilePath -> [FilePath]
ancestorsOf absolute =
  case takeDirectory absolute of
    parent
      | parent == absolute || parent == "/" -> []
      | otherwise -> ancestorsOf parent <> [parent]

--------------------------------------------------------------------
-- Inspection
--------------------------------------------------------------------

-- | What an absolute root path is right now.
data RootState
  = RootAbsent
  | RootDirectory [RootEntry]
  deriving (Eq, Show)

-- | Classify an absolute root with no-follow metadata and, when it is
-- a directory, snapshot its complete tree (module header).
inspectRoot :: FilePath -> IO (Either Text RootState)
inspectRoot absolute = do
  status <- tryIO (getSymbolicLinkStatus absolute)
  case status of
    Left problem
      | isDoesNotExistError problem -> pure (Right RootAbsent)
      | otherwise -> pure (Left ("could not be inspected: " <> describeIOError problem))
    Right metadata
      | isSymbolicLink metadata -> pure (Left "is a symbolic link")
      | isDirectory metadata -> do
          snapshot <- tryIO (snapshotTree absolute)
          pure $ case snapshot of
            Left problem -> Left ("could not be read: " <> describeIOError problem)
            Right entries -> Right (RootDirectory entries)
      | otherwise -> pure (Left "is not a directory")

-- | Every entry below a directory, in a deterministic order,
-- classified from no-follow metadata (module header).
snapshotTree :: FilePath -> IO [RootEntry]
snapshotTree root = walk ""
  where
    walk relative = do
      names <- listDirectory (if null relative then root else root </> relative)
      concat <$> mapM (entry relative) (sort names)
    entry relative name = do
      let relativePath = if null relative then name else relative <> "/" <> name
          fullPath = root </> relativePath
      metadata <- getSymbolicLinkStatus fullPath
      if isSymbolicLink metadata
        then pure [RootEntry relativePath SymbolicLink]
        else
          if isDirectory metadata
            then (RootEntry relativePath Directory :) <$> walk relativePath
            else
              if isRegularFile metadata
                then
                  if linkCount metadata > 1
                    then pure [RootEntry relativePath HardLinkedFile]
                    else do
                      bytes <- ByteString.readFile fullPath
                      pure [RootEntry relativePath (RegularFile bytes)]
                else pure [RootEntry relativePath OtherEntry]

-- | The permission bits the staging directory is created with and the
-- installed root therefore carries: owner read, write, and search
-- only (module header: private mode).
privateDirectoryMode :: FileMode
privateDirectoryMode = 0o700

-- | The permission bits (@0o777@ mask; the set-user-ID, set-group-ID,
-- and sticky bits are not permission bits and are ignored) of a
-- directory read with no-follow metadata, or why they could not be
-- read: the path is not a directory (a symbolic link counts as not a
-- directory), or its metadata is unreadable.
directoryPermissionBits :: FilePath -> IO (Either Text FileMode)
directoryPermissionBits path = do
  status <- tryIO (getSymbolicLinkStatus path)
  pure $ case status of
    Left problem -> Left ("could not be inspected: " <> describeIOError problem)
    Right metadata
      | isSymbolicLink metadata -> Left "is a symbolic link"
      | isDirectory metadata -> Right (permissionBits metadata)
      | otherwise -> Left "is not a directory"

permissionBits :: FileStatus -> FileMode
permissionBits metadata = fileMode metadata .&. 0o777

-- | Render permission bits the way @chmod@ reads them (@0700@).
renderMode :: FileMode -> Text
renderMode bits =
  let digits = showOct bits ""
   in Text.pack ('0' : replicate (3 - length digits) '0' <> digits)

--------------------------------------------------------------------
-- Installation
--------------------------------------------------------------------

-- | Fault-injection seams between the installation steps, for the
-- test suite: each receives the path it names and may mutate the
-- filesystem before the next step.  Production passes
-- 'noInstallHooks'.
data InstallHooks = InstallHooks
  { hookAfterStaging :: FilePath -> IO ()
    -- ^ Runs after the staged bundle passed its confinement check
    -- and before the destination is revalidated (and before the
    -- backup sibling's absence is confirmed a second time); receives
    -- the staging directory.
  , hookAfterBackup :: FilePath -> IO ()
    -- ^ Runs after an existing root was renamed to the backup and
    -- before the staging directory is renamed into place; receives
    -- the backup directory (or the would-be backup path when the
    -- destination was absent).
  }

-- | No injected faults.
noInstallHooks :: InstallHooks
noInstallHooks = InstallHooks (\_ -> pure ()) (\_ -> pure ())

-- | Why a bundle was not installed.
data InstallFailure
  = -- | The destination, one of its ancestors, or its backup sibling
    -- is unusable (exit 1 at the CLI); the 'Text' is the reason.
    -- Nothing was mutated.
    InstallUnusableRoot Text
  | -- | The destination is a nonempty root this tool does not own
    -- (exit 4 at the CLI): the sorted, deduplicated violations of
    -- the ownership rule.  Nothing was mutated.
    InstallNotOwned (NonEmpty ConfinementViolation)
  | -- | Staging, moving, installing, restoring, or cleaning up
    -- failed (exit 2 at the CLI); the 'Text' names the operations,
    -- the classified I\/O error kinds, and any directory left behind.
    InstallWorkspaceFailure Text
  | -- | The installed root failed the final full confinement check
    -- (exit 4 at the CLI).
    InstallNotConfined (NonEmpty ConfinementViolation)
  deriving (Eq, Show)

-- | The staging directory of a root: a sibling this tool creates
-- exclusively.
stagingPathOf :: FilePath -> FilePath
stagingPathOf root = root <> ".mithril-wasp-staging"

-- | The backup directory of a root: the sibling an existing root is
-- renamed to while the new root is installed.
backupPathOf :: FilePath -> FilePath
backupPathOf root = root <> ".mithril-wasp-backup"

-- | Install a rendered bundle at an absolute root path (module
-- header: the ownership and replacement rule).
installBundle :: InstallHooks -> WaspBundle -> FilePath -> IO (Either InstallFailure ())
installBundle hooks bundle root = do
  decided <- decide
  case decided of
    Left failure -> pure (Left failure)
    Right _ -> do
      backupClear <- backupAbsent
      case backupClear of
        Left reason -> pure (Left (InstallUnusableRoot reason))
        Right () -> do
          created <- tryIO (Posix.createDirectory staging privateDirectoryMode)
          case created of
            Left problem ->
              pure (Left (InstallWorkspaceFailure (labelled "creating the staging directory" problem)))
            Right () -> do
              private <- confirmPrivate staging "the staging directory"
              case private of
                Left reason -> abandon reason
                Right () -> stageAndInstall
  where
    staging = stagingPathOf root
    backup = backupPathOf root

    labelled operation problem = operation <> " failed: " <> describeIOError problem

    -- Validate ancestors, inspect the destination, and decide whether
    -- it may be initialized (False: nothing to move aside) or
    -- replaced (True: an existing directory must be moved aside).
    decide :: IO (Either InstallFailure Bool)
    decide = do
      ancestors <- validateAncestors root
      case ancestors of
        Left reason -> pure (Left (InstallUnusableRoot reason))
        Right () -> do
          state <- inspectRoot root
          pure $ case state of
            Left reason -> Left (InstallUnusableRoot reason)
            Right RootAbsent -> Right False
            Right (RootDirectory entries) ->
              case NonEmpty.nonEmpty (checkConfinement OwnershipCheck bundle entries) of
                Just violations -> Left (InstallNotOwned violations)
                Nothing -> Right True

    -- The backup sibling must be absent (no-follow); whatever exists
    -- there is refused and never touched.
    backupAbsent :: IO (Either Text ())
    backupAbsent = do
      status <- tryIO (getSymbolicLinkStatus backup)
      pure $ case status of
        Left problem
          | isDoesNotExistError problem -> Right ()
          | otherwise ->
              Left ("its backup path " <> Text.pack backup <> " could not be inspected: " <> describeIOError problem)
        Right metadata ->
          Left
            ( "its backup path "
                <> Text.pack backup
                <> " already exists ("
                <> entryLabel metadata
                <> ") and is never replaced; move it away first"
            )

    entryLabel metadata
      | isSymbolicLink metadata = "a symbolic link"
      | isDirectory metadata = "a directory"
      | isRegularFile metadata = "a regular file"
      | otherwise = "another filesystem entry"

    -- The directory at the path must be a real directory with exactly
    -- the private permission bits.
    confirmPrivate :: FilePath -> Text -> IO (Either Text ())
    confirmPrivate path label = do
      bits <- directoryPermissionBits path
      pure $ case bits of
        Left reason -> Left (label <> " " <> reason)
        Right mode
          | mode == privateDirectoryMode -> Right ()
          | otherwise ->
              Left
                ( label
                    <> " is not private: mode "
                    <> renderMode mode
                    <> " instead of "
                    <> renderMode privateDirectoryMode
                )

    stageAndInstall = do
      written <- tryIO (mapM_ materialize (bundleFiles bundle))
      case written of
        Left problem -> abandon (labelled "writing the staged bundle" problem)
        Right () -> do
          staged <- tryIO (snapshotTree staging)
          case staged of
            Left problem -> abandon (labelled "inspecting the staged bundle" problem)
            Right entries ->
              case checkConfinement FullCheck bundle entries of
                problems@(_ : _) ->
                  abandon ("the staged bundle failed its own confinement check: " <> renderProblems problems)
                [] -> do
                  hookAfterStaging hooks staging
                  decidedAgain <- decide
                  case decidedAgain of
                    Left failure -> abandonWith failure
                    Right False -> install False
                    Right True -> do
                      backupStillClear <- backupAbsent
                      case backupStillClear of
                        Left reason -> abandonWith (InstallUnusableRoot reason)
                        Right () -> do
                          moved <- tryIO (renameDirectory root backup)
                          case moved of
                            Left problem -> abandon (labelled "moving the existing root aside" problem)
                            Right () -> do
                              hookAfterBackup hooks backup
                              install True

    install hadBackup = do
      installed <- tryIO (renameDirectory staging root)
      case installed of
        Left problem
          | hadBackup -> do
              restored <- tryIO (renameDirectory backup root)
              case restored of
                Right () ->
                  abandon (labelled "installing the staged bundle" problem <> "; the previous root was restored")
                Left restoreProblem ->
                  abandon
                    ( labelled "installing the staged bundle" problem
                        <> "; restoring the previous root failed: "
                        <> describeIOError restoreProblem
                        <> "; the previous root remains at "
                        <> Text.pack backup
                    )
          | otherwise -> abandon (labelled "installing the staged bundle" problem)
        Right () -> do
          cleaned <-
            if hadBackup
              then tryIO (removeDirectoryRecursive backup)
              else pure (Right ())
          case cleaned of
            Left problem ->
              pure
                ( Left
                    ( InstallWorkspaceFailure
                        ( "the new root is installed, but removing the previous root's backup failed: "
                            <> describeIOError problem
                            <> "; it remains at "
                            <> Text.pack backup
                        )
                    )
                )
            Right () -> finalCheck

    finalCheck = do
      state <- inspectRoot root
      case state of
        Left reason -> pure (Left (InstallWorkspaceFailure ("inspecting the installed root failed: " <> reason)))
        Right RootAbsent -> pure (Left (InstallWorkspaceFailure "inspecting the installed root failed: does not exist"))
        Right (RootDirectory entries) ->
          case NonEmpty.nonEmpty (checkConfinement FullCheck bundle entries) of
            Just violations -> pure (Left (InstallNotConfined violations))
            Nothing -> do
              private <- confirmPrivate root "the installed root"
              pure $ case private of
                Left reason -> Left (InstallWorkspaceFailure reason)
                Right () -> Right ()

    materialize file = do
      let destination = staging </> managedPath file
      createDirectoryIfMissing True (takeDirectory destination)
      ByteString.writeFile destination (managedBytes file)

    -- Remove the staging directory after a failure, surfacing a
    -- removal failure with the directory left behind.
    abandon message = do
      removed <- tryIO (removeDirectoryRecursive staging)
      pure (Left (InstallWorkspaceFailure (withStagingRemoval message removed)))

    abandonWith failure = do
      removed <- tryIO (removeDirectoryRecursive staging)
      pure $ case removed of
        Right () -> Left failure
        Left problem
          | isDoesNotExistError problem -> Left failure
        Left problem ->
          Left
            ( InstallWorkspaceFailure
                ( withStagingRemoval
                    ( case failure of
                        InstallUnusableRoot reason -> "the destination became unusable before the swap: " <> reason
                        InstallNotOwned violations ->
                          "the destination stopped being replaceable before the swap: "
                            <> renderProblems (NonEmpty.toList violations)
                        InstallWorkspaceFailure reason -> reason
                        InstallNotConfined violations ->
                          "the destination is not confined: " <> renderProblems (NonEmpty.toList violations)
                    )
                    (Left problem)
                )
            )

    -- A staging directory that no longer exists (an injected fault
    -- or a concurrent removal) is not a removal failure: nothing
    -- remains behind.
    withStagingRemoval message removed =
      case removed of
        Right () -> message
        Left problem
          | isDoesNotExistError problem -> message
        Left problem ->
          message
            <> "; removing the staging directory failed: "
            <> describeIOError problem
            <> "; it remains at "
            <> Text.pack staging

    renderProblems problems =
      Text.intercalate
        "; "
        [confinementPath problem <> ": " <> confinementMessage problem | problem <- problems]
