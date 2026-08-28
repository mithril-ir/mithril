{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Checks over the contract-rendering boundary:
-- "Mithril.Core.Contract" and its integration in
-- "Mithril.Command.Contract".
--
-- The positive side goes through the production API: the Acme example
-- and the well-typed coverage fixture flow through the complete
-- public pipeline ('validateCoreFile') to a
-- @'CoreDocument' 'Normalized'@ and are rendered with
-- 'renderCoreContract'.  The exact output bytes are frozen twice
-- over, independently of the renderer: byte-for-byte against the
-- golden files @test\/fixtures\/acme.contract.txt@ and
-- @test\/fixtures\/welltyped.contract.txt@, and — for Acme — against
-- a full in-module literal.  Repeated renders, renders of two
-- independent pipeline runs, and renders of byte-identical Core
-- content read from a different filesystem path must all be
-- byte-identical, successful contracts must end with exactly one
-- final newline and contain no carriage return or tab, and a
-- constructor-consumption matrix pins the exact number of times every
-- declaration, type, action, principal-mode, effect, result,
-- value-term, policy-term, and guarantee constructor family surfaces
-- in the rendered contracts — so no rendering branch can silently
-- stop being exercised.
--
-- The forged-document checks are the deliberate exception to the
-- public-pipeline rule, mirroring the normalization boundary's:
-- contract rendering has /no user-error class/, and the public
-- pipeline cannot produce a normalized document whose model breaks
-- the renderer's referential invariants, so these checks construct
-- broken normalized models directly and stamp them @Normalized@
-- through the sublibrary constructor.  Every resulting problem must
-- come back as 'ContractRendererInvariantViolations' (the exit-2
-- internal class) with the exact pinned violations — never as a
-- crash, a user-addressed error, or placeholder output.  Forged
-- but well-formed models also pin /materiality/: stored static-type
-- annotations, materialized ranks, stored ordered evidence, and
-- stored binding order each visibly determine the output, so the
-- renderer demonstrably consumes the normalized model instead of
-- re-deriving any of it.
module Mithril.CoreContractTests
  ( tests
  ) where

import Control.Exception (bracket)
import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.IO (hClose, openTempFile)

import Mithril.Command.Contract
  ( ContractFileError (..)
  , contractCoreFile
  , contractFailureExitCode
  , renderContractFailure
  )
import Mithril.Command.Validate
  ( ValidateFileError (..)
  , renderValidateFailure
  , validateCoreFile
  )
import Mithril.Core.Contract
  ( ContractRendererInvariantViolation (..)
  , ContractRenderingFailure (..)
  , Normalized
  , normalizeContractRendererInvariantViolations
  , renderCoreContract
  )
import Mithril.Core.Internal.Document (CoreDocument (..))
import qualified Mithril.Core.Internal.Normalized as Internal
import Mithril.Core.Internal.Resolved
  ( ActionId (..)
  , AttributeId (..)
  , EndpointId (..)
  , EntityId (..)
  , EnumId (..)
  , EnumValueId (..)
  , ParameterId (..)
  , Ref (..)
  , RelationId (..)
  )
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , memberPath
  , rootPath
  )
import Mithril.Core.Internal.StaticType
  ( OrderedType (..)
  , PolicyType (..)
  , ValueType (..)
  )
import Mithril.Core.Internal.Syntax
  ( AbsenceLevel (..)
  , ActorAvailability (..)
  , OneOrTwo (..)
  )
import Mithril.Test (Check, check)

-- | The handwritten well-typed example and its frozen contract.
acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

acmeContractPath :: FilePath
acmeContractPath = "test/fixtures/acme.contract.txt"

-- | The well-typed full-coverage fixture and its frozen contract.
welltypedPath :: FilePath
welltypedPath = "test/fixtures/welltyped.mir.json"

welltypedContractPath :: FilePath
welltypedContractPath = "test/fixtures/welltyped.contract.txt"

-- | All contract-boundary checks.  The file reads assume the test
-- process runs from the package root, which is how @cabal test@ runs
-- it.
tests :: IO [Check]
tests = do
  acmeFirst <- renderThroughPipeline acmePath
  acmeSecond <- renderThroughPipeline acmePath
  welltypedFirst <- renderThroughPipeline welltypedPath
  welltypedSecond <- renderThroughPipeline welltypedPath
  acmeGolden <- ByteString.readFile acmeContractPath
  welltypedGolden <- ByteString.readFile welltypedContractPath
  copiedOutcome <- renderFromCopiedPath welltypedPath
  commandOutcome <- contractCoreFile acmePath
  pure $
    concat
      [ pipelineChecks
          acmeFirst
          acmeSecond
          welltypedFirst
          welltypedSecond
          acmeGolden
          welltypedGolden
          copiedOutcome
      , [ check
            "contractCoreFile returns exactly the frozen Acme contract text"
            (commandOutcome == Right acmeContractLiteral)
        ]
      , byteDisciplineChecks acmeFirst welltypedFirst
      , consumptionMatrixChecks acmeFirst welltypedFirst
      , authoredStructureChecks welltypedFirst
      , syntheticModelChecks
      , materialityChecks
      , invariantChecks
      , failureRenderingChecks
      ]

-- | One complete production run: 'validateCoreFile' (the public
-- pipeline) followed by 'renderCoreContract'.  Each call reads and
-- stages the file afresh, so two calls are two independent runs.
renderThroughPipeline :: FilePath -> IO (Maybe Text)
renderThroughPipeline file = do
  outcome <- validateCoreFile file
  pure $ case outcome of
    Left _ -> Nothing
    Right pipelineDocument ->
      either (const Nothing) Just (renderCoreContract pipelineDocument)

-- | Copy a fixture's exact bytes to a collision-safe temporary path,
-- render the copy through the public pipeline, and clean up — the
-- input-path-independence oracle.  The unique name comes from
-- 'openTempFile', so nothing that might belong to someone else is
-- created or deleted.
renderFromCopiedPath :: FilePath -> IO (Maybe Text)
renderFromCopiedPath original = do
  temporaryBase <- getTemporaryDirectory
  bracket
    (acquire temporaryBase)
    removeFile
    renderThroughPipeline
  where
    acquire temporaryBase = do
      (copyPath, handle) <- openTempFile temporaryBase "mithril-contract-copy.mir.json"
      hClose handle
      bytes <- ByteString.readFile original
      ByteString.writeFile copyPath bytes
      pure copyPath

--------------------------------------------------------------------
-- Golden bytes, literals, determinism, path independence
--------------------------------------------------------------------

pipelineChecks
  :: Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> ByteString.ByteString
  -> ByteString.ByteString
  -> Maybe Text
  -> [Check]
pipelineChecks acmeFirst acmeSecond welltypedFirst welltypedSecond acmeGolden welltypedGolden copiedOutcome =
  [ check
      "the Acme contract matches the frozen golden file byte for byte"
      (fmap Encoding.encodeUtf8 acmeFirst == Just acmeGolden)
  , check
      "the Acme contract matches the full in-module literal"
      (acmeFirst == Just acmeContractLiteral)
  , check
      "the well-typed coverage contract matches the frozen golden file byte for byte"
      (fmap Encoding.encodeUtf8 welltypedFirst == Just welltypedGolden)
  , check
      "two independent Acme pipeline runs render byte-identical contracts"
      (acmeFirst == acmeSecond && acmeFirst /= Nothing)
  , check
      "two independent well-typed pipeline runs render byte-identical contracts"
      (welltypedFirst == welltypedSecond && welltypedFirst /= Nothing)
  , check
      "rendering one normalized document twice is byte-identical"
      renderTwiceDeterministic
  , check
      "byte-identical Core content read from a different filesystem path renders identical contract bytes"
      (copiedOutcome == welltypedFirst && copiedOutcome /= Nothing)
  ]

-- | Render two separately constructed but equal normalized documents;
-- the results must be byte-equal.  (The independent-pipeline-run
-- checks above pin the same property over the real fixture
-- documents.)
renderTwiceDeterministic :: Bool
renderTwiceDeterministic =
  case ( renderCoreContract (normalizedDocument syntheticTinyModel)
       , renderCoreContract (normalizedDocument syntheticTinyModel)
       ) of
    (Right once, Right twice) -> once == twice
    _ -> False

--------------------------------------------------------------------
-- The frozen Acme contract, as an in-module literal
--------------------------------------------------------------------

-- | The complete expected Acme contract, line by line — an
-- expectation independent of both the renderer and the golden file.
acmeContractLiteral :: Text
acmeContractLiteral =
  Text.unlines
    ( [ "Mithril Core v0 security contract"
      , "model: Acme"
      , ""
      , "Entities"
      , "  entity User"
      , "    (no attributes)"
      , "  entity Organization"
      , "    (no attributes)"
      , "  entity Project"
      , "    attribute organization : EntityRef[Organization]"
      , ""
      , "Enums"
      , "  enum MembershipRole"
      , "    value Member"
      , "    value Admin"
      , "    order: Member = 0, Admin = 1"
      , ""
      , "Relations"
      , "  relation Membership"
      , "    endpoint user : User"
      , "    endpoint organization : Organization"
      , "    payload: Enum[MembershipRole]"
      , ""
      , "Actions"
      , "  action Project.read"
      , "    parameter project : EntityRef[Project]"
      , "    principal mode: AuthenticatedOnly"
      , "    classification: Read"
      , "    allow: LessOrEqual[order optional MembershipRole, absence as\
        \ bottom](Some(Enum[MembershipRole.Member]), Lookup[Membership](user\
        \ = Actor[User], organization =\
        \ Attribute[organization](Argument[project]))) : Bool"
      , "    effect: NoChange"
      , "    result: Observe"
      , "      entity: Argument[project] : EntityRef[Project]"
      , "  action Project.create"
      , "    parameter organization : EntityRef[Organization]"
      , "    principal mode: AuthenticatedOnly"
      , "    classification: Mutation"
      , "    allow: LessOrEqual[order optional MembershipRole, absence as\
        \ bottom](Some(Enum[MembershipRole.Member]), Lookup[Membership](user\
        \ = Actor[User], organization = Argument[organization])) : Bool"
      , "    effect: CreateEntity[Project]"
      , "      initialize organization = Argument[organization] :\
        \ EntityRef[Organization]"
      , "    result: Created"
      , "  action Project.delete"
      , "    parameter project : EntityRef[Project]"
      , "    principal mode: AuthenticatedOnly"
      , "    classification: Mutation"
      , "    allow: LessOrEqual[order optional MembershipRole, absence as\
        \ bottom](Some(Enum[MembershipRole.Admin]), Lookup[Membership](user\
        \ = Actor[User], organization =\
        \ Attribute[organization](Argument[project]))) : Bool"
      , "    effect: DeleteEntity"
      , "      target: Argument[project] : EntityRef[Project]"
      , "    result: Done"
      , "  action Membership.addMember"
      , "    parameter target : EntityRef[User]"
      , "    parameter organization : EntityRef[Organization]"
      , "    principal mode: AuthenticatedOnly"
      , "    classification: Mutation"
      , "    allow: And(LessOrEqual[order optional MembershipRole, absence as\
        \ bottom](Some(Enum[MembershipRole.Admin]), Lookup[Membership](user\
        \ = Actor[User], organization = Argument[organization])),\
        \ Equal(Lookup[Membership](user = Argument[target], organization =\
        \ Argument[organization]), None[Enum[MembershipRole]])) : Bool"
      , "    effect: SetRelation[Membership]"
      , "      endpoint user = Argument[target] : EntityRef[User]"
      , "      endpoint organization = Argument[organization] :\
        \ EntityRef[Organization]"
      , "      payload: Enum[MembershipRole.Member] : Enum[MembershipRole]"
      , "    result: Done"
      , "  action Membership.changeRole"
      , "    parameter target : EntityRef[User]"
      , "    parameter organization : EntityRef[Organization]"
      , "    parameter newRole : Enum[MembershipRole]"
      , "    principal mode: AuthenticatedOnly"
      , "    classification: Mutation"
      , "    allow: And(LessOrEqual[order optional MembershipRole, absence as\
        \ bottom](Some(Enum[MembershipRole.Admin]), Lookup[Membership](user\
        \ = Actor[User], organization = Argument[organization])),\
        \ And(Not(Equal(Actor[User], Argument[target])),\
        \ IsSome(Lookup[Membership](user = Argument[target], organization =\
        \ Argument[organization])))) : Bool"
      , "    effect: SetRelation[Membership]"
      , "      endpoint user = Argument[target] : EntityRef[User]"
      , "      endpoint organization = Argument[organization] :\
        \ EntityRef[Organization]"
      , "      payload: Argument[newRole] : Enum[MembershipRole]"
      , "    result: Done"
      , ""
      , "Selected guarantees (unverified proof obligations)"
      , "  guarantee AuthenticatedMutation (unverified proof obligation)"
      , "  guarantee TenantIsolation (unverified proof obligation)"
      , "    access relation: Membership"
      , "    access subject endpoint: user"
      , "    access tenant endpoint: organization"
      , "    case for action Project.read"
      , "      tenant: Attribute[organization](Argument[project]) :\
        \ EntityRef[Organization]"
      , "      protected: Bool[true] : Bool"
      , "    case for action Project.create"
      , "      tenant: Argument[organization] : EntityRef[Organization]"
      , "      protected: Bool[true] : Bool"
      , "    case for action Project.delete"
      , "      tenant: Attribute[organization](Argument[project]) :\
        \ EntityRef[Organization]"
      , "      protected: Bool[true] : Bool"
      , "  guarantee NoSelfPrivilegeEscalation (unverified proof obligation)"
      , "    authority relation: Membership"
      , "    authority subject endpoint: user"
      , "    authority scope endpoint: organization"
      , "    authority absence level: Bottom"
      , "    authority payload order: MembershipRole"
      , "    case for action Membership.changeRole"
      , "      scope organization = Argument[organization] :\
        \ EntityRef[Organization]"
      , ""
      , "Limitations and non-claims"
      ]
        <> limitationsBlockLines
    )

-- | The seven fixed limitation bullets, shared by the literal
-- expectations (independent of the renderer's own constants).
limitationsBlockLines :: [Text]
limitationsBlockLines =
  [ "  - This contract is a deterministic rendering of one well-typed,\
    \ normalized Mithril Core v0 document; it restates that document and\
    \ adds nothing to it."
  , "  - No policy was evaluated: allow policies, effects, and results are\
    \ rendered as authored, not interpreted, simplified, or executed."
  , "  - The selected guarantees above are unverified proof obligations;\
    \ selecting them establishes nothing about the document or any system."
  , "  - No proof was generated or checked."
  , "  - No executable backend or runtime enforcement was generated."
  , "  - Authentication of the acting principal is supplied by an external\
    \ trusted boundary; this document does not establish it."
  , "  - This output is not a semantic diff: it does not compare this\
    \ document with any other document or revision."
  ]

--------------------------------------------------------------------
-- Byte discipline
--------------------------------------------------------------------

byteDisciplineChecks :: Maybe Text -> Maybe Text -> [Check]
byteDisciplineChecks acmeOutcome welltypedOutcome =
  [ check
      "the Acme contract ends with exactly one final newline"
      (maybe False endsWithExactlyOneNewline acmeOutcome)
  , check
      "the well-typed contract ends with exactly one final newline"
      (maybe False endsWithExactlyOneNewline welltypedOutcome)
  , check
      "neither contract contains a carriage return or a tab"
      ( maybe False noCarriageReturnOrTab acmeOutcome
          && maybe False noCarriageReturnOrTab welltypedOutcome
      )
  , -- The removed arbitrary per-case tenantAccess policy must never
    -- resurface: no rendered contract may carry a tenantAccess line.
    check
      "no rendered contract contains a tenantAccess line"
      ( maybe False (not . Text.isInfixOf "tenantAccess") acmeOutcome
          && maybe False (not . Text.isInfixOf "tenantAccess") welltypedOutcome
          && not (Text.isInfixOf "tenantAccess" syntheticTinyContract)
      )
  ]

endsWithExactlyOneNewline :: Text -> Bool
endsWithExactlyOneNewline contract =
  "\n" `Text.isSuffixOf` contract
    && not ("\n\n" `Text.isSuffixOf` contract)

noCarriageReturnOrTab :: Text -> Bool
noCarriageReturnOrTab contract =
  not (Text.any (\c -> c == '\r' || c == '\t') contract)

--------------------------------------------------------------------
-- The constructor-consumption matrix
--------------------------------------------------------------------

-- | Every current constructor family must surface in the rendered
-- contracts, with its exact site count pinned per fixture — so the
-- matrix cannot pass vacuously and no rendering branch can silently
-- stop being exercised.  Counts are over the rendered Acme,
-- well-typed, and synthetic contracts (needles anchored with a
-- leading newline where an indented label would otherwise match a
-- deeper-indented one).  The two branches no well-typed fixture can
-- reach on the annotation side — the @Optional[...]@ policy-type
-- annotation and the forged-order variants — are pinned by the
-- materiality checks below instead.
consumptionMatrixChecks :: Maybe Text -> Maybe Text -> [Check]
consumptionMatrixChecks acmeOutcome welltypedOutcome =
  case (acmeOutcome, welltypedOutcome) of
    (Just acme, Just welltyped) ->
      [ check
          ("consumption matrix: " <> label <> " surfaces exactly "
             <> show acmeCount <> "/" <> show welltypedCount <> "/"
             <> show syntheticCount <> " times (Acme/well-typed/synthetic)")
          ( countIn needle acme == acmeCount
              && countIn needle welltyped == welltypedCount
              && countIn needle syntheticTinyContract == syntheticCount
              && acmeCount + welltypedCount + syntheticCount > 0
          )
      | (label, needle, acmeCount, welltypedCount, syntheticCount) <-
          consumptionMatrix
      ]
        <> [ check
              "consumption matrix: value-term Some sites are the Some count minus the IsSome count"
              ( countIn "Some(" acme - countIn "IsSome(" acme == 5
                  && countIn "Some(" welltyped - countIn "IsSome(" welltyped == 1
              )
           , check
              "consumption matrix: plain-enum ordered readings are the LessOrEqual total minus the optional readings"
              ( countIn "LessOrEqual[order " acme
                  - countIn "LessOrEqual[order optional " acme
                  == 0
                  && countIn "LessOrEqual[order " welltyped
                    - countIn "LessOrEqual[order optional " welltyped
                    == 2
              )
           ]
    _ ->
      [ check
          "both fixtures render through the public pipeline (consumption-matrix prerequisite)"
          False
      ]

-- | (label, needle, Acme count, well-typed count, synthetic count).
consumptionMatrix :: [(String, Text, Int, Int, Int)]
consumptionMatrix =
  [ ("the contract header", "Mithril Core v0 security contract\n", 1, 1, 1)
  , ("the model name line", "\nmodel: ", 1, 1, 1)
  , ("entity declarations", "\n  entity ", 3, 3, 1)
  , ("attribute declarations", "\n    attribute ", 1, 5, 0)
  , ("Bool attribute types", "\n    attribute urgent : Bool", 0, 1, 0)
  , ("Enum attribute types", "\n    attribute role : Enum[Rank]", 0, 1, 0)
  , ( "EntityRef attribute types"
    , "\n    attribute organization : EntityRef[Organization]"
    , 1
    , 1
    , 0
    )
  , ("attribute-free entities", "(no attributes)", 2, 0, 1)
  , ("enum declarations", "\n  enum ", 1, 3, 0)
  , ("enum value declarations", "\n    value ", 2, 6, 0)
  , ("materialized enum orders", "\n    order: ", 1, 2, 0)
  , ( "the authored Acme ranking"
    , "\n    order: Member = 0, Admin = 1"
    , 1
    , 0
    , 0
    )
  , ( "a materialized ranking that differs from declaration order"
    , "\n    order: Final = 0, Draft = 1"
    , 0
    , 1
    , 0
    )
  , ("order-free enums", "(no declared order)", 0, 1, 0)
  , ("relation declarations", "\n  relation ", 1, 3, 0)
  , ("endpoint declarations", "\n    endpoint ", 2, 4, 0)
  , ("relation payload types", "\n    payload: ", 1, 3, 0)
  , ("Unit relation payloads", "\n    payload: Unit", 0, 1, 0)
  , ("action declarations", "\n  action ", 5, 10, 1)
  , ("parameter declarations", "\n    parameter ", 8, 14, 1)
  , ("Bool parameter types", "\n    parameter urgent : Bool", 0, 1, 0)
  , ("Unit parameter types", "\n    parameter token : Unit", 0, 0, 1)
  , ("Enum parameter types", "\n    parameter level : Enum[Rank]", 0, 2, 0)
  , ( "EntityRef parameter types"
    , "\n    parameter project : EntityRef[Project]"
    , 2
    , 0
    , 0
    )
  , ("parameter-free actions", "(no parameters)", 0, 1, 0)
  , ("AuthenticatedOnly actions", "principal mode: AuthenticatedOnly", 5, 6, 1)
  , ("AnyPrincipal actions", "principal mode: AnyPrincipal", 0, 4, 0)
  , ("Read classifications", "classification: Read", 1, 3, 0)
  , ("Mutation classifications", "classification: Mutation", 4, 7, 1)
  , ("AuthenticatedOnly allow policies", "\n    allow: ", 5, 6, 1)
  , ("anonymous allow branches", "\n    allow (anonymous): ", 0, 4, 0)
  , ("authenticated allow branches", "\n    allow (authenticated): ", 0, 4, 0)
  , ("NoChange effects", "effect: NoChange", 1, 4, 1)
  , ("CreateEntity effects", "effect: CreateEntity[", 1, 2, 0)
  , ("DeleteEntity effects", "effect: DeleteEntity", 1, 1, 0)
  , ("SetRelation effects", "effect: SetRelation[", 2, 2, 0)
  , ("RemoveRelation effects", "effect: RemoveRelation[", 0, 1, 0)
  , ("Observe results", "result: Observe", 1, 3, 0)
  , ("Created results", "result: Created", 1, 2, 0)
  , ("Done results", "result: Done", 3, 5, 1)
  , ("CreateEntity initializer lines", "\n      initialize ", 1, 4, 0)
  , ("effect endpoint-binding lines", "\n      endpoint ", 4, 4, 0)
  , ("SetRelation payload lines", "\n      payload: ", 2, 2, 0)
  , ("DeleteEntity target lines", "\n      target: ", 1, 1, 0)
  , ("Observe entity lines", "\n      entity: ", 1, 3, 0)
  , ("Bool[true] terms", "Bool[true]", 3, 7, 1)
  , ("Bool[false] terms", "Bool[false]", 0, 2, 0)
  , ("the Unit payload term with its stored Unit type", "\n      payload: Unit : Unit", 0, 1, 0)
  , ("Enum brackets (terms and types)", "Enum[", 11, 11, 0)
  , ("Argument terms", "Argument[", 22, 24, 0)
  , ("Actor terms", "Actor[User]", 6, 7, 0)
  , ("Attribute projections", "Attribute[", 4, 4, 0)
  , ("Lookup terms", "Lookup[", 7, 5, 0)
  , ("None terms", "None[", 1, 2, 0)
  , ("None over a Unit payload", "None[Unit]", 0, 1, 0)
  , ("None over an Enum payload", "None[Enum[MembershipRole]]", 1, 0, 0)
  , ("IsSome terms", "IsSome(", 1, 2, 0)
  , ("Equal terms", "Equal(", 2, 5, 0)
  , ( "optional ordered readings with absence as bottom"
    , "LessOrEqual[order optional "
    , 5
    , 1
    , 0
    )
  , ("plain-enum ordered readings", "LessOrEqual[order Rank]", 0, 1, 0)
  , ( "the reversed-rank ordered reading"
    , "LessOrEqual[order Phase]"
    , 0
    , 1
    , 0
    )
  , ("And terms", "And(", 3, 3, 0)
  , ("Or terms", "Or(", 0, 1, 0)
  , ("Not terms", "Not(", 1, 1, 0)
  , ("EntityRef type annotations", "EntityRef[", 19, 26, 0)
  , ("Bool type annotations", " : Bool", 8, 18, 1)
  , ("Unit type annotations", " : Unit", 0, 1, 1)
  , ( "the AuthenticatedMutation obligation"
    , "guarantee AuthenticatedMutation (unverified proof obligation)"
    , 1
    , 1
    , 0
    )
  , ( "the TenantIsolation obligation"
    , "guarantee TenantIsolation (unverified proof obligation)"
    , 1
    , 1
    , 0
    )
  , ( "the NoSelfPrivilegeEscalation obligation"
    , "guarantee NoSelfPrivilegeEscalation (unverified proof obligation)"
    , 1
    , 2
    , 0
    )
  , ("guarantee case lines", "case for action ", 4, 3, 0)
  , ("TenantIsolation tenant terms", "\n      tenant: ", 3, 1, 0)
  , ("TenantIsolation protected terms", "\n      protected: ", 3, 1, 0)
  , ("TenantIsolation access relations", "access relation: ", 1, 1, 0)
  , ( "TenantIsolation access subject endpoints"
    , "access subject endpoint: "
    , 1
    , 1
    , 0
    )
  , ( "TenantIsolation access tenant endpoints"
    , "access tenant endpoint: "
    , 1
    , 1
    , 0
    )
  , ("authority relations", "authority relation: ", 1, 2, 0)
  , ("authority subject endpoints", "authority subject endpoint: ", 1, 2, 0)
  , ( "declared authority scope endpoints"
    , "authority scope endpoint: organization"
    , 1
    , 1
    , 0
    )
  , ( "scope-free authorities"
    , "authority scope endpoint: (none)"
    , 0
    , 1
    , 0
    )
  , ("authority absence levels", "authority absence level: Bottom", 1, 2, 0)
  , ("authority payload orders", "authority payload order: ", 1, 2, 0)
  , ("bound case scopes", "\n      scope organization = ", 1, 1, 0)
  , ("scope-free cases", "\n      scope: (none)", 0, 1, 0)
  , ("empty sections", "\n  (none)", 0, 0, 3)
  , ( "the unverified-obligations section title"
    , "Selected guarantees (unverified proof obligations)"
    , 1
    , 1
    , 1
    )
  , ( "the fixed limitations section"
    , "Limitations and non-claims"
    , 1
    , 1
    , 1
    )
  , ("the policies-not-evaluated non-claim", "No policy was evaluated", 1, 1, 1)
  , ("the no-proof non-claim", "No proof was generated or checked.", 1, 1, 1)
  , ( "the no-enforcement non-claim"
    , "No executable backend or runtime enforcement was generated."
    , 1
    , 1
    , 1
    )
  , ( "the external-authentication assumption"
    , "Authentication of the acting principal is supplied by an external trusted boundary"
    , 1
    , 1
    , 1
    )
  , ( "the not-a-semantic-diff non-claim"
    , "This output is not a semantic diff"
    , 1
    , 1
    , 1
    )
  ]

-- | Non-overlapping occurrence count of a needle in a text.
countIn :: Text -> Text -> Int
countIn needle haystack = Text.count needle haystack

--------------------------------------------------------------------
-- Authored-structure preservation (explicit, beyond the frozen bytes)
--------------------------------------------------------------------

-- | The goldens pin these bytes already; these checks state the
-- as-authored preservation facts explicitly so they cannot be lost in
-- a golden refresh: a foldable @And(true, true)@, a redundant
-- @Or(..., false)@, and the authored binary operand order (the
-- @Actor@ on the authored left of an @Equal@) all surface verbatim,
-- unsimplified and unreordered.
authoredStructureChecks :: Maybe Text -> [Check]
authoredStructureChecks welltypedOutcome =
  [ check
      "a foldable authored And(true, true) surfaces verbatim, unsimplified"
      (contains "And(Bool[true], Bool[true])")
  , check
      "a redundant authored Or branch surfaces verbatim, unsimplified"
      ( contains
          "Or(Equal(Lookup[Membership](member = Argument[target],\
          \ organization = Argument[organization]), None[Enum[Rank]]),\
          \ Bool[false])"
      )
  , check
      "the authored binary operand order surfaces unreordered"
      (contains "Not(Equal(Actor[User], Argument[target]))")
  ]
  where
    contains needle = maybe False (Text.isInfixOf needle) welltypedOutcome

--------------------------------------------------------------------
-- The synthetic model: rare branches, pinned as a full literal
--------------------------------------------------------------------

-- | Stamp a hand-built normalized model as 'Normalized' through the
-- sublibrary constructor — the forgery no public caller can perform,
-- used to reach the renderer with content the fixtures do not
-- exercise (a Unit parameter, empty sections) and with the broken
-- models of the invariant checks.
normalizedDocument :: Internal.Model -> CoreDocument Normalized
normalizedDocument = CoreDocument

synthetic :: Text -> SourcePath
synthetic segment = memberPath rootPath segment

-- | A minimal well-formed normalized model: one attribute-free
-- @User@ entity, no enums, no relations, no guarantees, and one
-- parameterless-effect mutation action with a @Unit@-typed parameter
-- and a trivially true allow.
syntheticTinyModel :: Internal.Model
syntheticTinyModel =
  Internal.Model
    { Internal.modelName = Sourced (synthetic "name") "Tiny"
    , Internal.modelUserEntity = EntityId 0
    , Internal.modelEntities = [tinyUserEntity]
    , Internal.modelEnums = []
    , Internal.modelRelations = []
    , Internal.modelActions = [tinyTouchAction boolTrueAllow]
    , Internal.modelGuarantees = []
    }

syntheticTinyDocument :: CoreDocument Normalized
syntheticTinyDocument = normalizedDocument syntheticTinyModel

tinyUserEntity :: Internal.Entity
tinyUserEntity =
  Internal.Entity
    { Internal.entityId = EntityId 0
    , Internal.entityPath = synthetic "userEntity"
    , Internal.entityName = Sourced (synthetic "userEntityName") "User"
    , Internal.entityAttributes = []
    }

tinyTouchAction :: Internal.PolicyTerm 'ActorAvailable -> Internal.Action
tinyTouchAction allow =
  Internal.Action
    { Internal.actionId = ActionId 0
    , Internal.actionPath = synthetic "action"
    , Internal.actionName = Sourced (synthetic "actionName") "Tiny.touch"
    , Internal.actionParameters =
        [ Internal.Parameter
            { Internal.parameterId = ParameterId (ActionId 0) 0
            , Internal.parameterPath = synthetic "tokenParameter"
            , Internal.parameterName = Sourced (synthetic "tokenName") "token"
            , Internal.parameterType =
                Internal.UnitParameterType (synthetic "tokenType")
            }
        ]
    , Internal.actionBody =
        Internal.AuthenticatedOnlyBody allow noChangeShape
    }

noChangeShape :: Internal.ActionShape 'ActorAvailable
noChangeShape =
  Internal.MutationShape
    (Internal.NoChangeEffect (synthetic "effect"))
    (synthetic "result")

boolTrueAllow :: Internal.PolicyTerm availability
boolTrueAllow =
  Internal.PolicyTerm
    { Internal.policyTermPath = synthetic "allow"
    , Internal.policyTermType = ValuePolicyType BoolType
    , Internal.policyTermNode = Internal.ValuePolicyNode boolTrueTerm
    }

boolTrueTerm :: Internal.ValueTerm availability
boolTrueTerm =
  Internal.ValueTerm
    { Internal.valueTermPath = synthetic "allowValue"
    , Internal.valueTermType = BoolType
    , Internal.valueTermNode = Internal.BoolNode True
    }

-- | The synthetic model's complete expected contract: the Unit
-- parameter type and the explicit @(none)@ markers of the empty
-- sections reach their rendering branches, with every byte pinned.
syntheticTinyContract :: Text
syntheticTinyContract =
  Text.unlines
    ( [ "Mithril Core v0 security contract"
      , "model: Tiny"
      , ""
      , "Entities"
      , "  entity User"
      , "    (no attributes)"
      , ""
      , "Enums"
      , "  (none)"
      , ""
      , "Relations"
      , "  (none)"
      , ""
      , "Actions"
      , "  action Tiny.touch"
      , "    parameter token : Unit"
      , "    principal mode: AuthenticatedOnly"
      , "    classification: Mutation"
      , "    allow: Bool[true] : Bool"
      , "    effect: NoChange"
      , "    result: Done"
      , ""
      , "Selected guarantees (unverified proof obligations)"
      , "  (none)"
      , ""
      , "Limitations and non-claims"
      ]
        <> limitationsBlockLines
    )

syntheticModelChecks :: [Check]
syntheticModelChecks =
  [ check
      "the synthetic model renders to its complete pinned literal"
      ( case renderCoreContract syntheticTinyDocument of
          Right contract -> contract == syntheticTinyContract
          Left _ -> False
      )
  ]

--------------------------------------------------------------------
-- Materiality: stored data visibly determines the output
--------------------------------------------------------------------

-- | Each check flips exactly one stored datum of a well-formed forged
-- model — a stored static-type annotation, materialized rank numbers,
-- the stored ordered evidence, the stored binding order — and pins
-- the changed line, so the renderer demonstrably consumes the stored
-- normalized data rather than re-deriving it.
materialityChecks :: [Check]
materialityChecks =
  [ check
      "a stored term-type annotation alone changes the output (no type inference is rerun)"
      ( rendersWithLine
          syntheticTinyModel
          "    allow: Bool[true] : Bool"
          && rendersWithLine
            (tinyWithAllowType (OptionalPolicyType UnitType))
            "    allow: Bool[true] : Optional[Unit]"
      )
  , check
      "stored rank numbers alone change the order line (ranks are consumed, not positional)"
      ( rendersWithLine shadeModel "    order: Light = 0, Dark = 1"
          && rendersWithLine
            (shadeModelWithRanks 3 7)
            "    order: Light = 3, Dark = 7"
      )
  , check
      "the stored ordered evidence alone changes the comparison bracket (evidence is consumed, not re-classified)"
      ( rendersWithLine
          shadeModel
          "    allow: LessOrEqual[order Shade](Enum[Shade.Light], Enum[Shade.Dark]) : Bool"
          && rendersWithLine
            (shadeModelWithEvidence (OptionalEnumOrderedType (EnumId 0)))
            "    allow: LessOrEqual[order optional Shade, absence as bottom](Enum[Shade.Light], Enum[Shade.Dark]) : Bool"
      )
  , check
      "the stored binding order alone reorders the rendered endpoint lines"
      ( rendersWithLines
          (pairModel id)
          [ "      endpoint first = Actor[User] : EntityRef[User]"
          , "      endpoint second = Bool[true] : EntityRef[User]"
          ]
          && rendersWithLines
            (pairModel swapTwo)
            [ "      endpoint second = Bool[true] : EntityRef[User]"
            , "      endpoint first = Actor[User] : EntityRef[User]"
            ]
      )
  , check
      "the stored initializer order alone reorders the rendered initializer lines"
      ( rendersWithLines
          (createOrderModel id)
          [ "      initialize alpha = Bool[true] : Bool"
          , "      initialize beta = Bool[false] : Bool"
          ]
          && rendersWithLines
            (createOrderModel reverse)
            [ "      initialize beta = Bool[false] : Bool"
            , "      initialize alpha = Bool[true] : Bool"
            ]
      )
  , check
      "the stored scope information alone changes the authority and case scope lines (both models render successfully)"
      scopeInformationMateriality
  , check
      "the stored access endpoint identities alone swap the two access endpoint lines (both models render successfully)"
      ( rendersWithLines
          (tenantContractModelWith pairAccess (boolEntityRefTerm "tenantTerm"))
          [ "    access relation: Pair"
          , "    access subject endpoint: first"
          , "    access tenant endpoint: second"
          ]
          && rendersWithLines
            (tenantContractModelWith swappedPairAccess (boolEntityRefTerm "tenantTerm"))
            [ "    access relation: Pair"
            , "    access subject endpoint: second"
            , "    access tenant endpoint: first"
            ]
      )
  , check
      "the stored tenant-term annotation alone changes the tenant line (no type inference is rerun)"
      ( rendersWithLine
          (tenantContractModelWith pairAccess (boolEntityRefTerm "tenantTerm"))
          "      tenant: Bool[true] : EntityRef[User]"
          && rendersWithLine
            (tenantContractModelWith pairAccess (unitTerm "tenantTerm"))
            "      tenant: Unit : Unit"
      )
  ]
  where
    swappedPairAccess =
      pairAccess
        { Internal.tenantIsolationAccessSubjectEndpoint =
            Ref (synthetic "accessSubject") (EndpointId (RelationId 0) 1)
        , Internal.tenantIsolationAccessTenantEndpoint =
            Ref (synthetic "accessTenant") (EndpointId (RelationId 0) 0)
        }
    swapTwo bindings =
      case bindings of
        Two firstBinding secondBinding -> Two secondBinding firstBinding
        One only -> One only

-- | The model renders successfully and its contract contains the
-- exact line.
rendersWithLine :: Internal.Model -> Text -> Bool
rendersWithLine model expectedLine = rendersWithLines model [expectedLine]

-- | The model renders successfully and its contract contains the
-- exact lines consecutively, in order.
rendersWithLines :: Internal.Model -> [Text] -> Bool
rendersWithLines model expectedLines =
  case renderCoreContract (normalizedDocument model) of
    Right contract -> Text.unlines expectedLines `Text.isInfixOf` contract
    Left _ -> False

-- | 'syntheticTinyModel' with a different stored allow annotation
-- (nothing else changes).
tinyWithAllowType :: PolicyType -> Internal.Model
tinyWithAllowType annotation =
  syntheticTinyModel
    { Internal.modelActions =
        [tinyTouchAction boolTrueAllow {Internal.policyTermType = annotation}]
    }

--------------------------------------------------------------------
-- The Shade family (ordered enum, ordered comparison)
--------------------------------------------------------------------

shadeValueId :: Int -> EnumValueId
shadeValueId = EnumValueId (EnumId 0)

-- | The two-value @Shade@ enum with a materialized order carrying the
-- given rank numbers.
shadeEnumRanked :: Maybe (Int, Int) -> Internal.EnumDefinition
shadeEnumRanked ranks =
  Internal.EnumDefinition
    { Internal.enumDefinitionId = EnumId 0
    , Internal.enumDefinitionPath = synthetic "shadeEnum"
    , Internal.enumDefinitionName = Sourced (synthetic "shadeName") "Shade"
    , Internal.enumDefinitionValues =
        Internal.EnumMember (shadeValueId 0) (Sourced (synthetic "lightValue") "Light")
          :| [ Internal.EnumMember
                 (shadeValueId 1)
                 (Sourced (synthetic "darkValue") "Dark")
             ]
    , Internal.enumDefinitionOrder =
        fmap
          ( \(lightRank, darkRank) ->
              Internal.EnumOrder
                ( Internal.RankedValue
                    lightRank
                    (Ref (synthetic "orderLight") (shadeValueId 0))
                    :| [ Internal.RankedValue
                           darkRank
                           (Ref (synthetic "orderDark") (shadeValueId 1))
                       ]
                )
          )
          ranks
    }

shadeTerm :: Text -> Int -> Internal.PolicyTerm 'ActorAvailable
shadeTerm segment valueIndex =
  Internal.PolicyTerm
    { Internal.policyTermPath = synthetic segment
    , Internal.policyTermType = ValuePolicyType (EnumType (EnumId 0))
    , Internal.policyTermNode =
        Internal.ValuePolicyNode
          Internal.ValueTerm
            { Internal.valueTermPath = synthetic segment
            , Internal.valueTermType = EnumType (EnumId 0)
            , Internal.valueTermNode =
                Internal.EnumNode
                  (Ref (synthetic (segment <> "Enum")) (EnumId 0))
                  (Ref (synthetic (segment <> "Value")) (shadeValueId valueIndex))
            }
    }

shadeComparisonAllow :: OrderedType -> Internal.PolicyTerm 'ActorAvailable
shadeComparisonAllow evidence =
  Internal.PolicyTerm
    { Internal.policyTermPath = synthetic "allow"
    , Internal.policyTermType = ValuePolicyType BoolType
    , Internal.policyTermNode =
        Internal.LessOrEqualNode
          evidence
          (shadeTerm "leftShade" 0)
          (shadeTerm "rightShade" 1)
    }

-- | @User@ plus the ranked @Shade@ enum plus one action comparing two
-- @Shade@ values under the stored plain-enum evidence.
shadeModel :: Internal.Model
shadeModel = shadeModelWith (Just (0, 1)) (EnumOrderedType (EnumId 0))

shadeModelWithRanks :: Int -> Int -> Internal.Model
shadeModelWithRanks lightRank darkRank =
  shadeModelWith (Just (lightRank, darkRank)) (EnumOrderedType (EnumId 0))

shadeModelWithEvidence :: OrderedType -> Internal.Model
shadeModelWithEvidence = shadeModelWith (Just (0, 1))

shadeModelWith :: Maybe (Int, Int) -> OrderedType -> Internal.Model
shadeModelWith ranks evidence =
  syntheticTinyModel
    { Internal.modelEnums = [shadeEnumRanked ranks]
    , Internal.modelActions = [tinyTouchAction (shadeComparisonAllow evidence)]
    }

--------------------------------------------------------------------
-- The Pair family (two-endpoint relation, effect bindings)
--------------------------------------------------------------------

pairEndpoint :: Int -> Text -> Internal.Endpoint
pairEndpoint position name =
  Internal.Endpoint
    { Internal.endpointId = EndpointId (RelationId 0) position
    , Internal.endpointPath = synthetic (name <> "Endpoint")
    , Internal.endpointName = Sourced (synthetic (name <> "Name")) name
    , Internal.endpointEntity =
        Ref (synthetic (name <> "Entity")) (EntityId 0)
    }

pairRelation :: Internal.Relation
pairRelation =
  Internal.Relation
    { Internal.relationId = RelationId 0
    , Internal.relationPath = synthetic "pairRelation"
    , Internal.relationName = Sourced (synthetic "pairName") "Pair"
    , Internal.relationEndpoints =
        Two (pairEndpoint 0 "first") (pairEndpoint 1 "second")
    , Internal.relationPayload =
        Internal.UnitPayloadType (synthetic "pairPayload")
    }

actorEntityRefTerm :: Text -> Internal.ValueTerm 'ActorAvailable
actorEntityRefTerm segment =
  Internal.ValueTerm
    { Internal.valueTermPath = synthetic segment
    , Internal.valueTermType = EntityRefType (EntityId 0)
    , Internal.valueTermNode = Internal.ActorNode (EntityId 0)
    }

boolEntityRefTerm :: Text -> Internal.ValueTerm availability
boolEntityRefTerm segment =
  Internal.ValueTerm
    { Internal.valueTermPath = synthetic segment
    , Internal.valueTermType = EntityRefType (EntityId 0)
    , Internal.valueTermNode = Internal.BoolNode True
    }

unitTerm :: Text -> Internal.ValueTerm availability
unitTerm segment =
  Internal.ValueTerm
    { Internal.valueTermPath = synthetic segment
    , Internal.valueTermType = UnitType
    , Internal.valueTermNode = Internal.UnitNode
    }

-- | @User@ plus the two-endpoint @Pair@ relation plus one action
-- whose @SetRelation@ effect carries the given transformation of the
-- stored binding order.
pairModel
  :: ( OneOrTwo (Internal.EndpointBinding 'ActorAvailable)
       -> OneOrTwo (Internal.EndpointBinding 'ActorAvailable)
     )
  -> Internal.Model
pairModel arrange =
  syntheticTinyModel
    { Internal.modelRelations = [pairRelation]
    , Internal.modelActions =
        [ (tinyTouchAction boolTrueAllow)
            { Internal.actionBody =
                Internal.AuthenticatedOnlyBody
                  boolTrueAllow
                  ( Internal.MutationShape
                      ( Internal.SetRelationEffect
                          (synthetic "effect")
                          (Ref (synthetic "effectRelation") (RelationId 0))
                          ( arrange
                              ( Two
                                  ( Internal.EndpointBinding
                                      (EndpointId (RelationId 0) 0)
                                      (actorEntityRefTerm "firstTerm")
                                  )
                                  ( Internal.EndpointBinding
                                      (EndpointId (RelationId 0) 1)
                                      (boolEntityRefTerm "secondTerm")
                                  )
                              )
                          )
                          (unitTerm "payloadTerm")
                      )
                      (synthetic "result")
                  )
            }
        ]
    }

--------------------------------------------------------------------
-- The Doc family (two-attribute entity, initializer order)
--------------------------------------------------------------------

docAttribute :: Int -> Text -> Internal.Attribute
docAttribute position name =
  Internal.Attribute
    { Internal.attributeId = AttributeId (EntityId 0) position
    , Internal.attributePath = synthetic (name <> "Attribute")
    , Internal.attributeName = Sourced (synthetic (name <> "Name")) name
    , Internal.attributeType =
        Internal.BoolAttributeType (synthetic (name <> "Type"))
    }

boolValueTerm :: Text -> Bool -> Internal.ValueTerm availability
boolValueTerm segment flag =
  Internal.ValueTerm
    { Internal.valueTermPath = synthetic segment
    , Internal.valueTermType = BoolType
    , Internal.valueTermNode = Internal.BoolNode flag
    }

docInitializer :: Int -> Text -> Bool -> Internal.Initializer 'ActorAvailable
docInitializer position name flag =
  Internal.Initializer
    { Internal.initializerKey =
        Ref (synthetic (name <> "Key")) (AttributeId (EntityId 0) position)
    , Internal.initializerValue = boolValueTerm (name <> "Value") flag
    }

-- | A @Doc@ entity with two Bool attributes and one action whose
-- @CreateEntity@ effect carries the given transformation of the
-- stored initializer order.
createOrderModel
  :: ( [Internal.Initializer 'ActorAvailable]
       -> [Internal.Initializer 'ActorAvailable]
     )
  -> Internal.Model
createOrderModel arrange =
  syntheticTinyModel
    { Internal.modelEntities =
        [ Internal.Entity
            { Internal.entityId = EntityId 0
            , Internal.entityPath = synthetic "docEntity"
            , Internal.entityName = Sourced (synthetic "docEntityName") "Doc"
            , Internal.entityAttributes =
                [docAttribute 0 "alpha", docAttribute 1 "beta"]
            }
        ]
    , Internal.modelActions =
        [ (tinyTouchAction boolTrueAllow)
            { Internal.actionBody =
                Internal.AuthenticatedOnlyBody
                  boolTrueAllow
                  ( Internal.CreateShape
                      ( Internal.CreateEntityEffect
                          { Internal.createEntityEffectPath = synthetic "effect"
                          , Internal.createEntityEffectEntity =
                              Ref (synthetic "effectEntity") (EntityId 0)
                          , Internal.createEntityEffectInitializers =
                              arrange
                                [ docInitializer 0 "alpha" True
                                , docInitializer 1 "beta" False
                                ]
                          }
                      )
                      (synthetic "result")
                  )
            }
        ]
    }

--------------------------------------------------------------------
-- Internal invariants (white-box, through core-internal)
--------------------------------------------------------------------

-- | The fail-closed classification of every refusal branch of the
-- renderer, each reached by a forged normalized document: every
-- dangling-reference class (entity, enum, relation, action), every
-- same-owner missing-member class (an existing entity without the
-- referenced attribute, an existing enum without the referenced
-- value, an existing relation without the referenced endpoint, an
-- existing action without the referenced parameter, an existing
-- access relation without the referenced access endpoint), every
-- cross-ownership class (foreign enum value, foreign ranked value,
-- foreign endpoint binding, foreign initializer key, foreign
-- authority endpoint, foreign tenant-access endpoint, foreign
-- @Argument@ action), both unranked-order classes, all three
-- scope-correspondence classes, the dangling tenant-access relation,
-- and the recursive validation of nested stored term annotations.
-- Each check pins the exact sorted, deduplicated violation list —
-- never a crash, never placeholder output.
invariantChecks :: [Check]
invariantChecks =
  [ check
      "a well-formed forged normalized model renders successfully (control)"
      ( case renderCoreContract (normalizedDocument shadeModel) of
          Right _ -> True
          Left _ -> False
      )
  , check
      "a dangling entity reference in an attribute type is an internal invariant"
      ( invariantOutcome (withUserAttribute danglingEntityAttribute)
          == Just
            [ ContractRendererInvariantViolation
                ["ghostAttribute"]
                "a resolved entity reference does not name an entity of the model"
            ]
      )
  , check
      "a dangling enum reference in an attribute type is an internal invariant"
      ( invariantOutcome (withUserAttribute danglingEnumAttribute)
          == Just
            [ ContractRendererInvariantViolation
                ["ghostAttribute"]
                "a resolved enum reference does not name an enum of the model"
            ]
      )
  , check
      "a dangling relation reference in a Lookup is an internal invariant at both the reference and the binding"
      ( invariantOutcome danglingLookupModel
          == Just
            [ ContractRendererInvariantViolation
                ["allow"]
                "a resolved relation reference does not name a relation of the model"
            , ContractRendererInvariantViolation
                ["lookupRelation"]
                "a resolved relation reference does not name a relation of the model"
            ]
      )
  , check
      "an endpoint binding outside its relation is an internal invariant"
      ( invariantOutcome crossRelationBindingModel
          == Just
            [ ContractRendererInvariantViolation
                ["effect"]
                "an endpoint binding does not name an endpoint of the bound relation"
            ]
      )
  , check
      "a dangling parameter reference is an internal invariant"
      ( invariantOutcome (tinyWithAllow (argumentAllow (ParameterId (ActionId 0) 5)))
          == Just
            [ ContractRendererInvariantViolation
                ["argumentName"]
                "a resolved parameter reference does not name a parameter of the model"
            ]
      )
  , check
      "an Argument naming a foreign action's parameter is an internal invariant"
      ( invariantOutcome (tinyWithAllow (argumentAllow (ParameterId (ActionId 3) 0)))
          == Just
            [ ContractRendererInvariantViolation
                ["argumentName"]
                "an \"Argument\" term does not name a parameter of its action's environment"
            ]
      )
  , check
      "an enum value outside the term's enum is an internal invariant"
      ( invariantOutcome foreignEnumValueModel
          == Just
            [ ContractRendererInvariantViolation
                ["allowValueValue"]
                "the value of an enum term does not belong to the term's enum"
            ]
      )
  , check
      "a ranked order value outside the order's enum is an internal invariant"
      ( invariantOutcome foreignRankedValueModel
          == Just
            [ ContractRendererInvariantViolation
                ["orderDark"]
                "a ranked value of a declared enum order does not belong to the order's enum"
            ]
      )
  , check
      "ordered evidence naming an unranked enum is an internal invariant"
      ( invariantOutcome
          (shadeModelWith Nothing (EnumOrderedType (EnumId 0)))
          == Just
            [ ContractRendererInvariantViolation
                ["allow"]
                "the ordered reading of a \"LessOrEqual\" names an enum without a materialized ranking"
            ]
      )
  , check
      "a CreateEntity initializer key outside the target entity is an internal invariant"
      ( invariantOutcome foreignInitializerModel
          == Just
            [ ContractRendererInvariantViolation
                ["initializerKey"]
                "a \"CreateEntity\" initializer key does not name an attribute of the target entity"
            ]
      )
  , check
      "a dangling action reference in a guarantee case is an internal invariant"
      ( invariantOutcome danglingCaseActionModel
          == Just
            [ ContractRendererInvariantViolation
                ["caseAction"]
                "a resolved action reference does not name an action of the model"
            ]
      )
  , check
      "a well-formed forged TenantIsolation access renders successfully (control)"
      ( case renderCoreContract
          (normalizedDocument (tenantContractModelWith pairAccess (boolEntityRefTerm "tenantTerm"))) of
          Right _ -> True
          Left _ -> False
      )
  , check
      "a dangling access relation is an internal invariant at every access site that follows it"
      ( invariantOutcome danglingAccessRelationModel
          == Just
            [ ContractRendererInvariantViolation
                ["accessRelation"]
                "a resolved relation reference does not name a relation of the model"
            , ContractRendererInvariantViolation
                ["accessSubject"]
                "a resolved relation reference does not name a relation of the model"
            , ContractRendererInvariantViolation
                ["accessTenant"]
                "a resolved relation reference does not name a relation of the model"
            ]
      )
  , check
      "a missing access endpoint of the existing access relation is an internal invariant"
      ( invariantOutcome
          ( tenantContractModelWith
              pairAccess
                { Internal.tenantIsolationAccessSubjectEndpoint =
                    Ref (synthetic "accessSubject") (EndpointId (RelationId 0) 5)
                }
              (boolEntityRefTerm "tenantTerm")
          )
          == Just
            [ ContractRendererInvariantViolation
                ["accessSubject"]
                "a resolved endpoint reference does not name an endpoint of the model"
            ]
      )
  , check
      "an access endpoint owned by a foreign relation is an internal invariant"
      ( invariantOutcome
          ( tenantContractModelWith
              pairAccess
                { Internal.tenantIsolationAccessTenantEndpoint =
                    Ref (synthetic "accessTenant") (EndpointId (RelationId 1) 0)
                }
              (boolEntityRefTerm "tenantTerm")
          )
          == Just
            [ ContractRendererInvariantViolation
                ["accessTenant"]
                "an access endpoint reference does not name an endpoint of the access relation"
            ]
      )
  , check
      "an authority endpoint outside the authority's relation is an internal invariant"
      ( invariantOutcome foreignAuthorityEndpointModel
          == Just
            [ ContractRendererInvariantViolation
                ["authoritySubject"]
                "an authority endpoint reference does not name an endpoint of the authority's relation"
            ]
      )
  , check
      "an unranked authority payload order is an internal invariant"
      ( invariantOutcome unrankedPayloadOrderModel
          == Just
            [ ContractRendererInvariantViolation
                ["payloadOrder"]
                "the authority's payload order names an enum without a materialized ranking"
            ]
      )
  , check
      "a scope binding under a scope-free authority is an internal invariant"
      ( invariantOutcome (escalationModel Nothing (Just subjectScopeBinding))
          == Just
            [ ContractRendererInvariantViolation
                ["case"]
                "this case binds a scope term, but the authority declares no scope endpoint"
            ]
      )
  , check
      "a missing scope binding under a declared scope endpoint is an internal invariant"
      ( invariantOutcome (escalationModel (Just scopeEndpointRef) Nothing)
          == Just
            [ ContractRendererInvariantViolation
                ["case"]
                "this case binds no scope term, but the authority declares a scope endpoint"
            ]
      )
  , check
      "a scope binding naming a different endpoint than the authority is an internal invariant"
      ( invariantOutcome
          (escalationModel (Just scopeEndpointRef) (Just subjectScopeBinding))
          == Just
            [ ContractRendererInvariantViolation
                ["case"]
                "a case scope binding does not name the authority's scope endpoint"
            ]
      )
  , check
      "a missing attribute of an existing owner entity is an internal invariant"
      ( invariantOutcome missingAttributeModel
          == Just
            [ ContractRendererInvariantViolation
                ["missingAttribute"]
                "a resolved attribute reference does not name an attribute of the model"
            ]
      )
  , check
      "a missing value of an existing owner enum is an internal invariant"
      ( invariantOutcome missingEnumValueModel
          == Just
            [ ContractRendererInvariantViolation
                ["missingEnumValue"]
                "a resolved enum value reference does not name a value of the model"
            ]
      )
  , check
      "a missing endpoint of an existing owner relation is an internal invariant"
      ( invariantOutcome missingEndpointModel
          == Just
            [ ContractRendererInvariantViolation
                ["effect"]
                "a resolved endpoint reference does not name an endpoint of the model"
            ]
      )
  , check
      "a dangling declared-type reference in a nested value term's stored annotation is an internal invariant"
      ( invariantOutcome nestedValueAnnotationModel
          == Just
            [ ContractRendererInvariantViolation
                ["someInner"]
                "a resolved entity reference does not name an entity of the model"
            ]
      )
  , check
      "a dangling declared-type reference in a nested policy term's stored annotation is an internal invariant"
      ( invariantOutcome nestedPolicyAnnotationModel
          == Just
            [ ContractRendererInvariantViolation
                ["notInner"]
                "a resolved enum reference does not name an enum of the model"
            ]
      )
  , check
      "multiple nested-annotation violations come back sorted and deduplicated"
      ( invariantOutcome nestedAnnotationAggregateModel
          == Just
            [ ContractRendererInvariantViolation
                ["dupInner"]
                "a resolved enum reference does not name an enum of the model"
            , ContractRendererInvariantViolation
                ["valueInner"]
                "a resolved entity reference does not name an entity of the model"
            ]
      )
  , check
      "invariant classification and rendering are deterministic across repeated runs"
      ( renderForged danglingLookupModel == renderForged danglingLookupModel
          && renderForged danglingLookupModel /= "NOT-REFUSED"
      )
  ]
  where
    invariantOutcome model =
      case renderCoreContract (normalizedDocument model) of
        Left (ContractRendererInvariantViolations problems) ->
          Just (NonEmpty.toList problems)
        Right _ -> Nothing
    renderForged model =
      case renderCoreContract (normalizedDocument model) of
        Left (ContractRendererInvariantViolations problems) ->
          renderContractFailure (InternalContractRendererError problems)
        Right _ -> "NOT-REFUSED"

-- | 'syntheticTinyModel' with one attribute on @User@.
withUserAttribute :: Internal.Attribute -> Internal.Model
withUserAttribute attribute =
  syntheticTinyModel
    { Internal.modelEntities =
        [tinyUserEntity {Internal.entityAttributes = [attribute]}]
    }

danglingEntityAttribute :: Internal.Attribute
danglingEntityAttribute =
  Internal.Attribute
    { Internal.attributeId = AttributeId (EntityId 0) 0
    , Internal.attributePath = synthetic "ghostAttribute"
    , Internal.attributeName = Sourced (synthetic "ghostName") "ghost"
    , Internal.attributeType =
        Internal.EntityRefAttributeType
          (synthetic "ghostType")
          (Ref (synthetic "ghostTarget") (EntityId 9))
    }

danglingEnumAttribute :: Internal.Attribute
danglingEnumAttribute =
  danglingEntityAttribute
    { Internal.attributeType =
        Internal.EnumAttributeType
          (synthetic "ghostType")
          (Ref (synthetic "ghostTarget") (EnumId 9))
    }

-- | 'syntheticTinyModel' with a different allow policy on its one
-- action.
tinyWithAllow :: Internal.PolicyTerm 'ActorAvailable -> Internal.Model
tinyWithAllow allow =
  syntheticTinyModel {Internal.modelActions = [tinyTouchAction allow]}

argumentAllow :: ParameterId -> Internal.PolicyTerm 'ActorAvailable
argumentAllow target =
  Internal.PolicyTerm
    { Internal.policyTermPath = synthetic "allow"
    , Internal.policyTermType = ValuePolicyType BoolType
    , Internal.policyTermNode =
        Internal.ValuePolicyNode
          Internal.ValueTerm
            { Internal.valueTermPath = synthetic "allowValue"
            , Internal.valueTermType = BoolType
            , Internal.valueTermNode =
                Internal.ArgumentNode (Ref (synthetic "argumentName") target)
            }
    }

-- | A lookup whose relation identifier is outside the model; the
-- binding's endpoint identifier embeds the same dangling relation.
danglingLookupModel :: Internal.Model
danglingLookupModel =
  tinyWithAllow
    Internal.PolicyTerm
      { Internal.policyTermPath = synthetic "allow"
      , Internal.policyTermType = ValuePolicyType BoolType
      , Internal.policyTermNode =
          Internal.LookupNode
            (Ref (synthetic "lookupRelation") (RelationId 9))
            ( One
                ( Internal.EndpointBinding
                    (EndpointId (RelationId 9) 0)
                    (actorEntityRefTerm "lookupEndpointTerm")
                )
            )
      }

-- | The access relation reference dangling, with both endpoint
-- identifiers embedding the same dangling relation: every access line
-- fails closed on the missing relation, at its own reference site.
danglingAccessRelationModel :: Internal.Model
danglingAccessRelationModel =
  tenantContractModelWith
    Internal.TenantIsolationAccess
      { Internal.tenantIsolationAccessPath = synthetic "access"
      , Internal.tenantIsolationAccessRelation =
          Ref (synthetic "accessRelation") (RelationId 9)
      , Internal.tenantIsolationAccessSubjectEndpoint =
          Ref (synthetic "accessSubject") (EndpointId (RelationId 9) 0)
      , Internal.tenantIsolationAccessTenantEndpoint =
          Ref (synthetic "accessTenant") (EndpointId (RelationId 9) 1)
      }
    (boolEntityRefTerm "tenantTerm")

-- | The @Pair@ effect with one binding naming an endpoint of a
-- relation other than the bound one.
crossRelationBindingModel :: Internal.Model
crossRelationBindingModel =
  pairModel
    ( \_bindings ->
        One
          ( Internal.EndpointBinding
              (EndpointId (RelationId 1) 0)
              (actorEntityRefTerm "crossTerm")
          )
    )

-- | An attribute projection whose reference is owned by the existing
-- @User@ entity but names an attribute position that entity does not
-- declare.  Every earlier gate succeeds — the owner entity exists,
-- the source term and every stored annotation are valid — so exactly
-- the same-owner missing-attribute branch is reached.
missingAttributeModel :: Internal.Model
missingAttributeModel =
  tinyWithAllow
    Internal.PolicyTerm
      { Internal.policyTermPath = synthetic "allow"
      , Internal.policyTermType = ValuePolicyType BoolType
      , Internal.policyTermNode =
          Internal.ValuePolicyNode
            Internal.ValueTerm
              { Internal.valueTermPath = synthetic "allowValue"
              , Internal.valueTermType = BoolType
              , Internal.valueTermNode =
                  Internal.AttributeNode
                    (actorEntityRefTerm "attributeSource")
                    ( Ref
                        (synthetic "missingAttribute")
                        (AttributeId (EntityId 0) 5)
                    )
              }
      }

-- | An enum term whose value reference is owned by the existing
-- @Shade@ enum (so the same-enum ownership gate succeeds) but names a
-- value position that enum does not declare — exactly the same-owner
-- missing-value branch.
missingEnumValueModel :: Internal.Model
missingEnumValueModel =
  (shadeModelWith (Just (0, 1)) (EnumOrderedType (EnumId 0)))
    { Internal.modelActions =
        [ tinyTouchAction
            Internal.PolicyTerm
              { Internal.policyTermPath = synthetic "allow"
              , Internal.policyTermType = ValuePolicyType (EnumType (EnumId 0))
              , Internal.policyTermNode =
                  Internal.ValuePolicyNode
                    Internal.ValueTerm
                      { Internal.valueTermPath = synthetic "allowValue"
                      , Internal.valueTermType = EnumType (EnumId 0)
                      , Internal.valueTermNode =
                          Internal.EnumNode
                            (Ref (synthetic "allowValueEnum") (EnumId 0))
                            ( Ref
                                (synthetic "missingEnumValue")
                                (shadeValueId 5)
                            )
                      }
              }
        ]
    }

-- | A @Pair@ effect binding owned by the existing bound relation (so
-- the same-relation ownership gate succeeds) but naming an endpoint
-- position that relation does not declare — exactly the same-owner
-- missing-endpoint branch.
missingEndpointModel :: Internal.Model
missingEndpointModel =
  pairModel
    ( \_bindings ->
        One
          ( Internal.EndpointBinding
              (EndpointId (RelationId 0) 5)
              (actorEntityRefTerm "missingEndpointTerm")
          )
    )

-- | A @Some@ whose nested value term is well-formed except that its
-- stored static annotation references an entity outside the model.
-- Every reference the node rendering follows is valid (the actor
-- entity exists) and the labelled root's stored annotation is valid,
-- so the pinned violation can only come from the recursive validation
-- of the nested term's stored annotation — the branch no
-- labelled-root check reaches.
nestedValueAnnotationModel :: Internal.Model
nestedValueAnnotationModel =
  tinyWithAllow
    Internal.PolicyTerm
      { Internal.policyTermPath = synthetic "allow"
      , Internal.policyTermType = OptionalPolicyType (EntityRefType (EntityId 0))
      , Internal.policyTermNode =
          Internal.SomeNode
            Internal.ValueTerm
              { Internal.valueTermPath = synthetic "someInner"
              , Internal.valueTermType = EntityRefType (EntityId 9)
              , Internal.valueTermNode = Internal.ActorNode (EntityId 0)
              }
      }

-- | A @Not@ whose nested policy operand is well-formed except that
-- its stored static annotation references an enum outside the model;
-- as above, only the recursive annotation validation of the nested
-- policy term can produce the pinned violation.
nestedPolicyAnnotationModel :: Internal.Model
nestedPolicyAnnotationModel =
  tinyWithAllow
    Internal.PolicyTerm
      { Internal.policyTermPath = synthetic "allow"
      , Internal.policyTermType = ValuePolicyType BoolType
      , Internal.policyTermNode =
          Internal.NotNode
            Internal.PolicyTerm
              { Internal.policyTermPath = synthetic "notInner"
              , Internal.policyTermType = ValuePolicyType (EnumType (EnumId 9))
              , Internal.policyTermNode = Internal.ValuePolicyNode boolTrueTerm
              }
      }

-- | An @And@ over two nested policy operands that share one source
-- path and one dangling stored annotation (a duplicate after
-- normalization), one of which nests a value term with a second,
-- distinct dangling annotation — so the outcome pins both the sorting
-- and the deduplication of recursive annotation violations.
nestedAnnotationAggregateModel :: Internal.Model
nestedAnnotationAggregateModel =
  tinyWithAllow
    Internal.PolicyTerm
      { Internal.policyTermPath = synthetic "allow"
      , Internal.policyTermType = ValuePolicyType BoolType
      , Internal.policyTermNode = Internal.AndNode dupLeft dupRight
      }
  where
    dupLeft =
      Internal.PolicyTerm
        { Internal.policyTermPath = synthetic "dupInner"
        , Internal.policyTermType = ValuePolicyType (EnumType (EnumId 9))
        , Internal.policyTermNode =
            Internal.ValuePolicyNode
              Internal.ValueTerm
                { Internal.valueTermPath = synthetic "valueInner"
                , Internal.valueTermType = EntityRefType (EntityId 9)
                , Internal.valueTermNode = Internal.BoolNode True
                }
        }
    dupRight =
      Internal.PolicyTerm
        { Internal.policyTermPath = synthetic "dupInner"
        , Internal.policyTermType = ValuePolicyType (EnumType (EnumId 9))
        , Internal.policyTermNode = Internal.ValuePolicyNode boolTrueTerm
        }

-- | An enum term whose value belongs to a different enum than the
-- term references.
foreignEnumValueModel :: Internal.Model
foreignEnumValueModel =
  (shadeModelWith (Just (0, 1)) (EnumOrderedType (EnumId 0)))
    { Internal.modelActions =
        [ tinyTouchAction
            Internal.PolicyTerm
              { Internal.policyTermPath = synthetic "allow"
              , Internal.policyTermType = ValuePolicyType (EnumType (EnumId 0))
              , Internal.policyTermNode =
                  Internal.ValuePolicyNode
                    Internal.ValueTerm
                      { Internal.valueTermPath = synthetic "allowValue"
                      , Internal.valueTermType = EnumType (EnumId 0)
                      , Internal.valueTermNode =
                          Internal.EnumNode
                            (Ref (synthetic "allowValueEnum") (EnumId 0))
                            ( Ref
                                (synthetic "allowValueValue")
                                (EnumValueId (EnumId 1) 0)
                            )
                      }
              }
        ]
    }

-- | A materialized order whose second ranked value belongs to a
-- foreign enum.
foreignRankedValueModel :: Internal.Model
foreignRankedValueModel =
  syntheticTinyModel
    { Internal.modelEnums =
        [ (shadeEnumRanked Nothing)
            { Internal.enumDefinitionOrder =
                Just
                  ( Internal.EnumOrder
                      ( Internal.RankedValue
                          0
                          (Ref (synthetic "orderLight") (shadeValueId 0))
                          :| [ Internal.RankedValue
                                 1
                                 ( Ref
                                     (synthetic "orderDark")
                                     (EnumValueId (EnumId 1) 0)
                                 )
                             ]
                      )
                  )
            }
        ]
    }

-- | A @CreateEntity@ effect on the attribute-free @User@ entity with
-- an initializer key owned by a foreign entity.
foreignInitializerModel :: Internal.Model
foreignInitializerModel =
  syntheticTinyModel
    { Internal.modelActions =
        [ (tinyTouchAction boolTrueAllow)
            { Internal.actionBody =
                Internal.AuthenticatedOnlyBody
                  boolTrueAllow
                  ( Internal.CreateShape
                      ( Internal.CreateEntityEffect
                          { Internal.createEntityEffectPath = synthetic "effect"
                          , Internal.createEntityEffectEntity =
                              Ref (synthetic "effectEntity") (EntityId 0)
                          , Internal.createEntityEffectInitializers =
                              [ Internal.Initializer
                                  { Internal.initializerKey =
                                      Ref
                                        (synthetic "initializerKey")
                                        (AttributeId (EntityId 1) 0)
                                  , Internal.initializerValue =
                                      boolTrueTerm
                                  }
                              ]
                          }
                      )
                      (synthetic "result")
                  )
            }
        ]
    }

-- | The well-formed forged access over the @Pair@ relation: subject
-- @first@, tenant @second@.
pairAccess :: Internal.TenantIsolationAccess
pairAccess =
  Internal.TenantIsolationAccess
    { Internal.tenantIsolationAccessPath = synthetic "access"
    , Internal.tenantIsolationAccessRelation =
        Ref (synthetic "accessRelation") (RelationId 0)
    , Internal.tenantIsolationAccessSubjectEndpoint =
        Ref (synthetic "accessSubject") (EndpointId (RelationId 0) 0)
    , Internal.tenantIsolationAccessTenantEndpoint =
        Ref (synthetic "accessTenant") (EndpointId (RelationId 0) 1)
    }

-- | A @TenantIsolation@ guarantee over the @Pair@ relation with the
-- given access and case tenant term; the case names the one action.
tenantContractModelWith
  :: Internal.TenantIsolationAccess
  -> Internal.ValueTerm 'ActorFree
  -> Internal.Model
tenantContractModelWith access tenantTerm =
  syntheticTinyModel
    { Internal.modelRelations = [pairRelation]
    , Internal.modelGuarantees =
        [ Internal.TenantIsolationGuarantee
            (synthetic "guarantee")
            access
            ( Internal.TenantIsolationCase
                { Internal.tenantIsolationCasePath = synthetic "case"
                , Internal.tenantIsolationCaseAction =
                    Ref (synthetic "caseAction") (ActionId 0)
                , Internal.tenantIsolationCaseTenant = tenantTerm
                , Internal.tenantIsolationCaseProtected = boolTrueAllow
                }
                :| []
            )
        ]
    }

-- | A @TenantIsolation@ case naming an action outside the model; the
-- access itself is well-formed, so the dangling action is the only
-- inconsistency.
danglingCaseActionModel :: Internal.Model
danglingCaseActionModel =
  syntheticTinyModel
    { Internal.modelRelations = [pairRelation]
    , Internal.modelGuarantees =
        [ Internal.TenantIsolationGuarantee
            (synthetic "guarantee")
            pairAccess
            ( Internal.TenantIsolationCase
                { Internal.tenantIsolationCasePath = synthetic "case"
                , Internal.tenantIsolationCaseAction =
                    Ref (synthetic "caseAction") (ActionId 9)
                , Internal.tenantIsolationCaseTenant =
                    boolEntityRefTerm "tenantTerm"
                , Internal.tenantIsolationCaseProtected = boolTrueAllow
                }
                :| []
            )
        ]
    }

--------------------------------------------------------------------
-- The escalation family (authority and scope bindings)
--------------------------------------------------------------------

-- | A relation over @User@ with endpoints @subject@ and @scope@ and
-- the ranked @Shade@ payload, so an authority over it is otherwise
-- internally consistent.
scopedRelation :: Internal.Relation
scopedRelation =
  Internal.Relation
    { Internal.relationId = RelationId 0
    , Internal.relationPath = synthetic "authRelation"
    , Internal.relationName = Sourced (synthetic "authName") "Auth"
    , Internal.relationEndpoints =
        Two
          (pairEndpoint 0 "subject")
          (pairEndpoint 1 "scope")
    , Internal.relationPayload =
        Internal.EnumPayloadType
          (synthetic "authPayload")
          (Ref (synthetic "authPayloadEnum") (EnumId 0))
    }

scopeEndpointRef :: Ref EndpointId
scopeEndpointRef =
  Ref (synthetic "authorityScope") (EndpointId (RelationId 0) 1)

-- | A scope binding naming the subject endpoint — matching no scope
-- declaration, or mismatching a declared one.
subjectScopeBinding :: Internal.ScopeBinding
subjectScopeBinding =
  Internal.ScopeBinding
    { Internal.scopeBindingEndpoint = EndpointId (RelationId 0) 0
    , Internal.scopeBindingTerm = actorEntityRefTerm "scopeTerm"
    }

-- | The escalation-guarantee model: ranked @Shade@ payload enum, the
-- scoped relation, one action, and one escalation case with the given
-- authority scope endpoint and case scope binding.
escalationModel
  :: Maybe (Ref EndpointId) -> Maybe Internal.ScopeBinding -> Internal.Model
escalationModel authorityScope caseScope =
  syntheticTinyModel
    { Internal.modelEnums = [shadeEnumRanked (Just (0, 1))]
    , Internal.modelRelations = [scopedRelation]
    , Internal.modelGuarantees =
        [ Internal.NoSelfPrivilegeEscalationGuarantee
            (synthetic "guarantee")
            Internal.Authority
              { Internal.authorityPath = synthetic "authority"
              , Internal.authorityRelation =
                  Ref (synthetic "authorityRelation") (RelationId 0)
              , Internal.authoritySubjectEndpoint =
                  Ref (synthetic "authoritySubject") (EndpointId (RelationId 0) 0)
              , Internal.authorityScopeEndpoint = authorityScope
              , Internal.authorityAbsenceLevel =
                  Sourced (synthetic "absenceLevel") AbsenceBottom
              , Internal.authorityPayloadOrder =
                  Ref (synthetic "payloadOrder") (EnumId 0)
              }
            ( Internal.EscalationCase
                { Internal.escalationCasePath = synthetic "case"
                , Internal.escalationCaseAction =
                    Ref (synthetic "caseAction") (ActionId 0)
                , Internal.escalationCaseScope = caseScope
                }
                :| []
            )
        ]
    }

-- | 'escalationModel' with a consistent scope correspondence over the
-- endpoint at the given position: the authority declares that endpoint
-- as its scope endpoint and the one case binds exactly that endpoint.
-- Position 1 selects the @scope@ endpoint, position 0 the @subject@
-- endpoint; both variants are renderable (no invariant fails), so the
-- pair isolates the stored scope information as the only difference.
scopedEscalationModel :: Int -> Internal.Model
scopedEscalationModel scopePosition =
  escalationModel
    (Just (Ref (synthetic "authorityScope") (EndpointId (RelationId 0) scopePosition)))
    ( Just
        Internal.ScopeBinding
          { Internal.scopeBindingEndpoint = EndpointId (RelationId 0) scopePosition
          , Internal.scopeBindingTerm = actorEntityRefTerm "scopeTerm"
          }
    )

-- | Successful scope-information materiality: mutating only the stored
-- scope information — the authority's declared scope endpoint together
-- with the case's scope binding, consistently, so no invariant check
-- fires — must change exactly the authority scope-endpoint line and
-- the case scope line.  Both renders must succeed; the exact changed
-- fragments are pinned in both directions, so the renderer
-- demonstrably consumes the stored scope information rather than
-- re-deriving it.
scopeInformationMateriality :: Bool
scopeInformationMateriality =
  case ( renderCoreContract (normalizedDocument (scopedEscalationModel 1))
       , renderCoreContract (normalizedDocument (scopedEscalationModel 0))
       ) of
    (Right scopeContract, Right subjectContract) ->
      Text.isInfixOf "\n    authority scope endpoint: scope\n" scopeContract
        && Text.isInfixOf
          "\n      scope scope = Actor[User] : EntityRef[User]\n"
          scopeContract
        && not (Text.isInfixOf "      scope subject = " scopeContract)
        && Text.isInfixOf "\n    authority scope endpoint: subject\n" subjectContract
        && Text.isInfixOf
          "\n      scope subject = Actor[User] : EntityRef[User]\n"
          subjectContract
        && not (Text.isInfixOf "      scope scope = " subjectContract)
    _ -> False

-- | 'escalationModel' with the subject endpoint owned by a foreign
-- relation; the scope correspondence itself is consistent.
foreignAuthorityEndpointModel :: Internal.Model
foreignAuthorityEndpointModel =
  case escalationModel Nothing Nothing of
    model ->
      model
        { Internal.modelGuarantees =
            [ Internal.NoSelfPrivilegeEscalationGuarantee
                (synthetic "guarantee")
                Internal.Authority
                  { Internal.authorityPath = synthetic "authority"
                  , Internal.authorityRelation =
                      Ref (synthetic "authorityRelation") (RelationId 0)
                  , Internal.authoritySubjectEndpoint =
                      Ref
                        (synthetic "authoritySubject")
                        (EndpointId (RelationId 1) 0)
                  , Internal.authorityScopeEndpoint = Nothing
                  , Internal.authorityAbsenceLevel =
                      Sourced (synthetic "absenceLevel") AbsenceBottom
                  , Internal.authorityPayloadOrder =
                      Ref (synthetic "payloadOrder") (EnumId 0)
                  }
                ( Internal.EscalationCase
                    { Internal.escalationCasePath = synthetic "case"
                    , Internal.escalationCaseAction =
                        Ref (synthetic "caseAction") (ActionId 0)
                    , Internal.escalationCaseScope = Nothing
                    }
                    :| []
                )
            ]
        }

-- | 'escalationModel' with the payload-order enum stripped of its
-- materialized ranking.
unrankedPayloadOrderModel :: Internal.Model
unrankedPayloadOrderModel =
  (escalationModel Nothing Nothing)
    { Internal.modelEnums = [shadeEnumRanked Nothing]
    }

--------------------------------------------------------------------
-- Failure rendering and exit classification
--------------------------------------------------------------------

failureRenderingChecks :: [Check]
failureRenderingChecks =
  [ check
      "the internal contract renderer failure block renders exactly as specified"
      ( renderContractFailure
          ( InternalContractRendererError
              ( ContractRendererInvariantViolation ["a~b"] "first detail"
                  :| [ContractRendererInvariantViolation ["c/d", "0"] "second detail"]
              )
          )
          == Text.intercalate
            "\n"
            [ "mithril: internal Core contract renderer error: the normalized\
              \ document does not match the contract renderer's Core v0\
              \ interpretation"
            , "  /a~0b: first detail"
            , "  /c~1d/0: second detail"
            ]
      )
  , check
      "internal contract renderer errors exit with status 2"
      ( contractFailureExitCode
          ( InternalContractRendererError
              (ContractRendererInvariantViolation [] "detail" :| [])
          )
          == ExitFailure 2
      )
  , check
      "input failures keep the validate boundary's rendering bytes"
      ( renderContractFailure (ContractInputError sampleInputFailure)
          == renderValidateFailure sampleInputFailure
      )
  , check
      "input failures keep the validate boundary's exit classification"
      ( contractFailureExitCode (ContractInputError sampleInputFailure)
          == ExitFailure 1
      )
  , check
      "violation normalization sorts by path then message and deduplicates"
      ( normalizeContractRendererInvariantViolations [atB, atA2, atA1, atB]
          == [atA1, atA2, atB]
      )
  ]
  where
    sampleInputFailure =
      FileReadError "missing.mir.json" "does not exist"
    atA1 = ContractRendererInvariantViolation ["a"] "first message"
    atA2 = ContractRendererInvariantViolation ["a"] "second message"
    atB = ContractRendererInvariantViolation ["b"] "first message"
