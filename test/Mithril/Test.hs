-- | Minimal manual test harness shared by the test modules.
--
-- A check is a named 'Bool'.  Groups build their checks in 'IO' (some
-- need to read files or load the bundled schema); the runner forces
-- every check, reports each failure by name on stderr, and exits
-- nonzero if anything failed.  No third-party test framework is used.
module Mithril.Test
  ( Check
  , check
  , runGroups
  ) where

import Control.Exception (SomeException, evaluate, try)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | A named check: the name is reported when the check fails.
type Check = (String, Bool)

-- | Build a named check.
check :: String -> Bool -> Check
check name passed = (name, passed)

-- | Run named groups of checks and exit accordingly.
--
-- Exceptions are contained: a group whose setup throws becomes a
-- single failed check, and a check whose 'Bool' throws when forced
-- fails alone without aborting the harness.
runGroups :: [(String, IO [Check])] -> IO ()
runGroups groups = do
  results <- mapM runGroup groups
  let allChecks = concat results
      failures = [name | (name, passed) <- allChecks, not passed]
  case failures of
    [] -> putStrLn ("All " ++ show (length allChecks) ++ " checks passed.")
    _ -> do
      mapM_ (\name -> hPutStrLn stderr ("FAIL: " ++ name)) failures
      hPutStrLn stderr
        ( show (length failures)
            ++ " of "
            ++ show (length allChecks)
            ++ " checks failed."
        )
      exitFailure

-- | Run one group, qualifying every check name with the group name.
runGroup :: (String, IO [Check]) -> IO [Check]
runGroup (groupName, buildChecks) = do
  outcome <- try buildChecks
  case outcome of
    Left failure ->
      pure
        [ ( groupName ++ ": group setup raised " ++ show (failure :: SomeException)
          , False
          )
        ]
    Right checks -> mapM (forceCheck groupName) checks

-- | Force one check so that an exception inside its 'Bool' fails just
-- that check.
forceCheck :: String -> Check -> IO Check
forceCheck groupName (name, passed) = do
  outcome <- try (evaluate passed)
  pure $ case outcome of
    Left failure ->
      ( groupName ++ ": " ++ name
          ++ " (raised " ++ show (failure :: SomeException) ++ ")"
      , False
      )
    Right forced -> (groupName ++ ": " ++ name, forced)
