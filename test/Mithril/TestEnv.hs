{-# LANGUAGE OverloadedStrings #-}

-- | Environment and scratch-directory helpers for the
-- schema-provenance regression tests.
--
-- The helpers here exist so that every test which manipulates the
-- process environment or the filesystem does it exception-safely and
-- without touching anything it did not create:
--
-- * 'withEnvVarSet' restores the environment variable exactly,
--   distinguishing a previously /absent/ variable (restored by
--   unsetting) from a previously /present/ one (restored to its old
--   value), on success, on assertion failure, and on exceptions.
--
-- * 'withPermissiveDatadir' builds a collision-safe scratch directory
--   shaped like a Cabal data directory (@\<dir\>\/core\/schema.json@)
--   holding 'permissiveSchemaBytes', and removes exactly the material
--   it created, also under exceptions.  The unique name is derived
--   from 'openTempFile' (base), so no predictable path is ever
--   created, and nothing that might belong to someone else is ever
--   deleted.
module Mithril.TestEnv
  ( datadirVariable
  , permissiveSchemaBytes
  , withEnvVarSet
  , withPermissiveDatadir
  ) where

import Control.Exception (bracket, bracket_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

-- | The Cabal data-directory override variable for this package.  It
-- once selected where @Paths_mithril_ir@ looked for package data;
-- since the schema became a compile-time constant it must have no
-- effect on validation, and the regression tests set it to hostile
-- values to prove that.
datadirVariable :: String
datadirVariable = "mithril_ir_datadir"

-- | A schema inside the supported Core v0 profile that accepts any
-- JSON object.  This is the independent review's substitution attack:
-- were the tool still willing to read its schema from a runtime
-- location, planting these bytes there would mint
-- @CoreDocument StructurallyValid@ — and then @Resolved@ or an
-- internal-error exit — for non-Core documents.  With the schema
-- compiled in, planting them anywhere must change nothing.
permissiveSchemaBytes :: ByteString
permissiveSchemaBytes =
  "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\"}"

-- | Run an action with an environment variable set to a value,
-- restoring the previous state exactly afterwards — including when
-- the action throws.  A variable that was absent beforehand is
-- unset again, not left behind as an empty string.
withEnvVarSet :: String -> String -> IO a -> IO a
withEnvVarSet variable value action =
  bracket acquire restore (const action)
  where
    acquire = do
      original <- lookupEnv variable
      setEnv variable value
      pure original
    restore original =
      case original of
        Just previous -> setEnv variable previous
        Nothing -> unsetEnv variable

-- | Run an action on a fresh scratch data directory containing
-- @core\/schema.json@ with 'permissiveSchemaBytes'.
--
-- Uniqueness comes from 'openTempFile' in the system temporary
-- directory; the directory is the anchor file's name plus @.d@, so it
-- can only collide with leftovers of this very helper, and
-- 'createDirectory' fails loudly instead of adopting a foreign
-- directory if it somehow exists.  Cleanup removes exactly the anchor
-- file and the directory tree this helper created, and runs on
-- exceptions as well.
withPermissiveDatadir :: (FilePath -> IO a) -> IO a
withPermissiveDatadir action = do
  temporaryBase <- getTemporaryDirectory
  bracket (acquireAnchor temporaryBase) removeFile $ \anchorPath ->
    let root = anchorPath ++ ".d"
     in bracket_ (createDirectory root) (removeDirectoryRecursive root) $ do
          createDirectory (root </> "core")
          ByteString.writeFile (root </> "core" </> "schema.json") permissiveSchemaBytes
          action root
  where
    acquireAnchor temporaryBase = do
      (anchorPath, handle) <- openTempFile temporaryBase "mithril-ir-datadir-probe.txt"
      hClose handle
      pure anchorPath
