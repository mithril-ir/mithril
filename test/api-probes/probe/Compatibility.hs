{-# LANGUAGE OverloadedStrings #-}

-- Compatibility control (must compile): the adapter surface as it was
-- frozen before the Wasp Confinement Profile v1 existed, written
-- exactly as a downstream consumer of that time would write it — the
-- three legacy summary selectors, positional and record construction
-- and matching of the legacy WaspBundleSummary view (record update
-- included), and construction and matching of the two-argument
-- WaspNotConfined outcome — next to the explicit profile and the
-- complete ordered operation list a new consumer reads from the very
-- same values.  Compiling under the repository warning set with
-- -Werror (an exhaustive match over the four pre-Profile-v1 outcome
-- constructors included) proves that the compatibility layer neither
-- breaks old source nor hides Profile-v1 information from new source.
-- If this probe ever stops compiling, the documented frozen boundary
-- was broken again; the driver builds it right after probe-control
-- and requires success.  Nothing here runs the pipeline: every value
-- is built directly, so the probe never touches Agda or a Wasp root.
module Main
  ( main
  ) where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty

import Mithril.Command.Wasp
  ( WaspFileSuccess (..)
  , WaspReport (..)
  , renderWaspSuccess
  , waspSuccessExitCode
  )
import Mithril.Core.Wasp
  ( ConfinementViolation (..)
  , NspeRule (..)
  , WaspBundleSummary (..)
  , WaspOperationSummary (..)
  , WaspProfile (..)
  , nspeRuleLabel
  , waspProfileLabel
  , waspProfileName
  )

-- Legacy: positional construction, exactly as pre-Profile-v1 source
-- wrote it.
legacyPositional :: WaspBundleSummary
legacyPositional =
  WaspBundleSummary
    "Acme"
    "NoSelfPrivilegeEscalation"
    "Membership.changeRole"
    "mithrilCaseAction"
    "/operations/mithril-case-action"
    ["main.wasp.ts", "src/mithrilCaseAction.ts"]

-- Legacy: record construction through the six legacy fields.
legacyRecord :: WaspBundleSummary
legacyRecord =
  WaspBundleSummary
    { summaryModelName = "Acme"
    , summaryGuarantee = "NoSelfPrivilegeEscalation"
    , summaryCaseAction = "Membership.changeRole"
    , summaryOperation = "mithrilCaseAction"
    , summaryRoute = "/operations/mithril-case-action"
    , summaryManagedPaths = ["main.wasp.ts", "src/mithrilCaseAction.ts"]
    }

-- Legacy: positional matching.
legacyFields :: WaspBundleSummary -> Int
legacyFields (WaspBundleSummary modelName guarantee caseAction operation route paths) =
  length (show (modelName, guarantee, caseAction, operation, route)) + length paths

-- Legacy: record matching.
legacyOperationLine :: WaspBundleSummary -> String
legacyOperationLine WaspBundleSummary {summaryOperation = operation, summaryRoute = route} =
  show operation ++ " (POST " ++ show route ++ ")"

-- Legacy: the three selectors that existed before Profile v1.
legacySelectors :: WaspBundleSummary -> String
legacySelectors summary =
  show (summaryCaseAction summary, summaryOperation summary, summaryRoute summary)

-- Legacy: record update through a compatibility field.
legacyUpdated :: WaspBundleSummary -> WaspBundleSummary
legacyUpdated summary = summary {summaryCaseAction = "Membership.renamed"}

-- Legacy: the report record still holds the same summary type.
legacyReport :: WaspReport
legacyReport =
  WaspReport
    { reportCore = "acme.mir.json"
    , reportRoot = "app"
    , reportSummary = legacyRecord
    }

-- Legacy: the two-argument outcome, constructed ...
legacyOutcome :: WaspFileSuccess
legacyOutcome =
  WaspNotConfined "app" (ConfinementViolation "main.wasp.ts" "altered" :| [])

-- ... and matched, in an exhaustive case over exactly the four
-- constructors that existed before Profile v1 (-Wincomplete-patterns
-- is an error here, so the COMPLETE pragma must hold).
legacyClassify :: WaspFileSuccess -> Int
legacyClassify outcome =
  case outcome of
    WaspUnsupported reasons -> NonEmpty.length reasons
    WaspNotConfined root violations -> length root + NonEmpty.length violations
    WaspGenerated report -> length (summaryManagedPaths (reportSummary report))
    WaspConfined report -> length (summaryManagedPaths (reportSummary report))

-- New: the explicit profile and the complete ordered operation list,
-- read from the same summary type the legacy code constructs.
newDescribe :: WaspBundleSummary -> String
newDescribe WaspProfileSummary {summaryProfile = profile, summaryOperations = operations} =
  show (waspProfileLabel profile, waspProfileName profile)
    ++ concat
      [ show (operationCasePosition operation, nspeRuleLabel (operationRule operation), operationName operation, operationRoute operation)
      | operation <- NonEmpty.toList operations
      ]

-- New: the public rule tag of every operation is matched by its
-- constructors (the NspeRule re-export is what operationRule exposes).
newRuleKind :: WaspOperationSummary -> Int
newRuleKind operation =
  case operationRule operation of
    ChangeOtherRule -> 1
    BoundedSelfUpdateRule -> 2

-- New: the profile-aware outcome, constructed and matched next to the
-- legacy one.
newOutcome :: WaspFileSuccess
newOutcome =
  WaspRootNotConfined WaspProfileV1 "app" (ConfinementViolation "main.wasp.ts" "altered" :| [])

newProfileOf :: WaspFileSuccess -> Maybe WaspProfile
newProfileOf outcome =
  case outcome of
    WaspRootNotConfined profile _ _ -> Just profile
    WaspUnsupported _ -> Nothing
    WaspGenerated _ -> Nothing
    WaspConfined _ -> Nothing

main :: IO ()
main = do
  print (legacyPositional == legacyRecord)
  print (legacyFields legacyPositional)
  putStrLn (legacyOperationLine legacyRecord)
  putStrLn (legacySelectors (legacyUpdated legacyRecord))
  print (map legacyClassify [legacyOutcome, newOutcome, WaspGenerated legacyReport, WaspConfined legacyReport])
  print (waspSuccessExitCode legacyOutcome == waspSuccessExitCode newOutcome)
  putStrLn (show (renderWaspSuccess "acme.mir.json" newOutcome))
  putStrLn (newDescribe legacyRecord)
  print (map newRuleKind (NonEmpty.toList (summaryOperations legacyRecord)))
  print (newProfileOf legacyOutcome == Just WaspProfileV0 && newProfileOf newOutcome == Just WaspProfileV1)
