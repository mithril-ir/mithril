{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The Core v0 static typechecker: the one place that assigns static
-- types to the explicit decoded and name-resolved Core representation
-- of "Mithril.Core.Internal.Resolved" and checks every Core v0
-- typing judgment the schema and the resolver defer.  It consumes
-- only that representation — never Aeson @Value@, never raw JSON, and
-- never textual names for linkage — and it re-resolves nothing:
-- every reference it follows is an already-resolved identifier.
--
-- == The Core v0 type language
--
-- Value terms have exactly the four /value types/ of the surface
-- grammar — @Bool@, @Unit@, @Enum E@, and @EntityRef E@ — and policy
-- terms additionally have the /optional types/ @Optional T@ over a
-- value type, which model relation-payload presence: a @Lookup@ has
-- type @Optional P@ for its relation's payload type @P@, @None@ has
-- the optional type of its written payload type, and @Some@ lifts a
-- value term into the optional level.  Optional types nest exactly
-- one level deep by construction, because @Some@ takes a value term.
--
-- == The typing judgment, construct by construct
--
-- /Value terms/: @Bool@ literals have type @Bool@; @Unit@ has type
-- @Unit@; an @Enum@ term has its enum's type; an @Argument@ has its
-- parameter's declared type; @Actor@ has type @EntityRef User@ (the
-- distinguished entity); an @Attribute@ projection has the projected
-- attribute's declared type (its source is entity-typed by name
-- resolution; disagreement is drift, not a user error).
--
-- /Policy terms/: a @Lookup@ requires exactly its relation's endpoint
-- arity and, per position, an endpoint term of that endpoint's entity
-- type, and has type @Optional P@; @None@ has type @Optional P@ for
-- its written payload type; @Some v@ has type @Optional T@ for the
-- value type @T@ of @v@; @IsSome@ requires an @Optional@-typed
-- operand and has type @Bool@; @Equal@ requires its two operands to
-- have the same type — equality is total at every type, mirroring the
-- kernel semantics — and has type @Bool@; @LessOrEqual@ requires its
-- two operands to have the same /ordered/ type — @Enum E@ or
-- @Optional (Enum E)@ where @E@ declares an explicit order; absence
-- ranks as bottom — and has type @Bool@; @And@, @Or@, and @Not@
-- require @Bool@ operands and have type @Bool@.
--
-- /Actions/: every allow policy — the @AuthenticatedOnly@ policy and
-- both branches of an @AnyPrincipal@ allow pair — must have type
-- @Bool@.  An @Observe@ result must observe an entity reference.  A
-- @CreateEntity@ effect must initialize every attribute of its target
-- entity exactly once (keys are unique and target-owned by
-- construction) with a term of the attribute's declared type.  A
-- @DeleteEntity@ target must be an entity reference.  @SetRelation@
-- and @RemoveRelation@ require their relation's exact endpoint arity
-- and per-position endpoint entity types, and @SetRelation@ requires
-- a payload term of the relation's payload type.  @NoChange@,
-- @Created@, and @Done@ carry no terms.
--
-- /Enum declarations/: a declared @order@ must be a complete
-- permutation of the enum's values.  Order members are structurally
-- unique and resolve to the enum's own values, so the one remaining
-- judgment is completeness: every declared value must appear.
--
-- /Guarantees/: @AuthenticatedMutation@ carries no terms — its truth
-- is a verification question, not a typing one.  Each
-- @TenantIsolation@ case is checked in its named action's parameter
-- environment: the @tenant@ term must be an entity reference and the
-- @protected@ and @tenantAccess@ terms must have type @Bool@.  A
-- @NoSelfPrivilegeEscalation@ authority must be well-formed for the
-- guarantee's semantics: its subject endpoint must reference the
-- distinguished @User@ entity (the subject of a self-escalation is
-- the acting principal), its scope endpoint must be distinct from the
-- subject endpoint, subject and scope together must cover the
-- relation's endpoints (an arity-two relation needs the one scope
-- endpoint), and the relation's payload must be exactly the
-- @payloadOrder@ enum, which must declare an order.  Each case must
-- name exactly as many scope terms as the authority names scope
-- endpoints, and each scope term — checked in the case's action
-- environment — must have the scope endpoint's entity type.
--
-- Nothing else in the model carries an unchecked typing obligation:
-- attribute, parameter, relation-payload, and endpoint declared types
-- are bare resolved references (established at name resolution), and
-- the model name, @Created@\/@Done@ results, and the
-- @AuthenticatedMutation@ selector carry no terms.
--
-- == Diagnostics, cascades, and failure classification
--
-- After successful name resolution every term's type is determined
-- bottom-up — no user error can leave a type unknown — so every
-- reported violation is an independent fact about the document:
-- violations aggregate across the whole model without cascades, at
-- the retained source path of the offending node (this module
-- constructs no paths; it only reads the ones the representation
-- carries).  The two deliberate dependent-check suppressions are
-- endpoint-position compatibility under an arity mismatch (the
-- pairing would be a guess) and authority endpoint coverage under a
-- duplicated scope endpoint (the duplicate is the root cause).  A
-- root cause is likewise reported once: an enum without a declared
-- order is reported at each @LessOrEqual@ site that needs the order,
-- while an /incomplete/ declared order is reported only at the enum
-- declaration — the comparison sites see a declared order and stay
-- quiet.
--
-- Shapes the typechecker cannot interpret — identifier references
-- outside the model, owner disagreements, an @Actor@ term that does
-- not carry the distinguished entity — are impossible after
-- successful name resolution.  They are 'TypecheckerInvariantViolation's
-- (frontend drift or a resolver\/typechecker bug, exit status 2),
-- kept apart from user 'TypeViolation's and dominating them, and the
-- checker is total: it walks the whole model, aggregates everything
-- it finds, and never throws.
--
-- What this stage does /not/ establish: no policy evaluation, no
-- guarantee truth, no normalization, no verification.  A well-typed
-- document is not typed /normalized/ Core and proves no property.
module Mithril.Core.Internal.Typecheck
  ( -- * Violations
    TypeViolation (..)
  , TypecheckerInvariantViolation (..)
  , TypingProblem (..)

    -- * The checking pass
  , checkModel
  ) where

import Data.Foldable (toList, traverse_)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text

import Mithril.Core.Internal.Report
  ( Collect
  , andThen
  , quoted
  , refuse
  , reporting
  )
import Mithril.Core.Internal.Resolved
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , sourcePathSegments
  )
import Mithril.Core.Internal.Syntax
  ( OneOrTwo (..)
  , distinguishedUserEntity
  )

--------------------------------------------------------------------
-- Violations
--------------------------------------------------------------------

-- | One static-typing violation in the user's document: a term,
-- effect, result, declaration, or guarantee that breaks a Core v0
-- typing rule.
data TypeViolation = TypeViolation
  { typeViolationPath :: [Text]
    -- ^ Instance path of the failing site, as raw (unescaped)
    -- segments; render with
    -- 'Mithril.Core.Validation.renderJsonPointer'.
  , typeViolationMessage :: Text
    -- ^ Description of the violation, with every referenced name
    -- quoted.
  }
  deriving (Eq, Ord, Show)

-- | One typechecker-invariant violation: a shape of the resolved
-- representation the typechecker cannot interpret even though name
-- resolution succeeded.  This is evidence of frontend drift or a
-- resolver\/typechecker bug — an internal error of the @mithril@
-- tool, never a problem with the user's document.
data TypecheckerInvariantViolation = TypecheckerInvariantViolation
  { typecheckerInvariantPath :: [Text]
    -- ^ Instance path of the uninterpretable site, as raw segments.
  , typecheckerInvariantMessage :: Text
    -- ^ Description of the expectation that failed.
  }
  deriving (Eq, Ord, Show)

-- | The two problem classes of the one checking pass.  The caller
-- partitions them; any internal problem dominates the verdict.
data TypingProblem
  = UserTypingProblem TypeViolation
  | InternalTypingProblem TypecheckerInvariantViolation
  deriving (Eq, Show)

--------------------------------------------------------------------
-- Checking computations
--------------------------------------------------------------------

-- | A typing step: aggregates problems while checking the model.
-- User violations are always attached with 'flagged', which carries
-- on with a value — after resolution every type is determined, so no
-- user error needs to withhold one — while internal invariants use
-- 'invariant', which withholds the value: the typechecker no longer
-- trusts its reading at that site, and dependent checks stay quiet.
type Check a = Collect TypingProblem a

-- | Report one user violation and keep going.
flagged :: SourcePath -> Text -> Check ()
flagged path message =
  reporting
    [UserTypingProblem (TypeViolation (sourcePathSegments path) message)]

-- | Fail with one internal invariant violation.
invariant :: SourcePath -> Text -> Check a
invariant path message =
  refuse
    ( InternalTypingProblem
        (TypecheckerInvariantViolation (sourcePathSegments path) message)
    )

--------------------------------------------------------------------
-- The type language
--------------------------------------------------------------------

-- | The Core v0 value types: the types of value terms and of
-- attribute, parameter, and payload declarations.
data ValueType
  = BoolType
  | UnitType
  | EnumType EnumId
  | EntityRefType EntityId
  deriving (Eq)

-- | The Core v0 policy types: every value type plus the optional
-- types that model relation-payload presence.  Optionals nest one
-- level by construction ('SomeTerm' wraps a value term).
data PolicyType
  = ValuePolicyType ValueType
  | OptionalPolicyType ValueType
  deriving (Eq)

boolPolicyType :: PolicyType
boolPolicyType = ValuePolicyType BoolType

-- | The value type of a declared attribute type.
attributeValueType :: AttributeType -> ValueType
attributeValueType declared =
  case declared of
    BoolAttributeType _ -> BoolType
    EnumAttributeType _ ref -> EnumType (refTarget ref)
    EntityRefAttributeType _ ref -> EntityRefType (refTarget ref)

-- | The value type of a declared parameter type.
parameterValueType :: ParameterType -> ValueType
parameterValueType declared =
  case declared of
    BoolParameterType _ -> BoolType
    UnitParameterType _ -> UnitType
    EnumParameterType _ ref -> EnumType (refTarget ref)
    EntityRefParameterType _ ref -> EntityRefType (refTarget ref)

-- | The value type of a declared relation payload type.
payloadValueType :: PayloadType -> ValueType
payloadValueType declared =
  case declared of
    UnitPayloadType _ -> UnitType
    EnumPayloadType _ ref -> EnumType (refTarget ref)

--------------------------------------------------------------------
-- The signature
--------------------------------------------------------------------

-- | The typing signature of a resolved model: every declaration
-- keyed by its own identifier, plus the distinguished @User@ entity.
-- Built once per model; identifier lookups that miss are internal
-- invariant violations, never user errors.
data Signature = Signature
  { signatureEntities :: Map EntityId Entity
  , signatureAttributes :: Map AttributeId Attribute
  , signatureEnums :: Map EnumId EnumDefinition
  , signatureRelations :: Map RelationId Relation
  , signatureEndpoints :: Map EndpointId Endpoint
  , signatureActions :: Map ActionId Action
  , signatureParameters :: Map ParameterId Parameter
  , signatureUser :: Maybe EntityId
    -- ^ The distinguished @User@ entity — the same name-designated
    -- entity the resolver gives every @Actor@ term.  'Nothing' after
    -- successful resolution is drift, reported as an invariant at
    -- the first site that needs it.
  }

buildSignature :: Model -> Signature
buildSignature model =
  Signature
    { signatureEntities =
        Map.fromList [(entityId entity, entity) | entity <- entities]
    , signatureAttributes =
        Map.fromList
          [ (attributeId attribute, attribute)
          | entity <- entities
          , attribute <- entityAttributes entity
          ]
    , signatureEnums =
        Map.fromList
          [ (enumDefinitionId definition, definition)
          | definition <- modelEnums model
          ]
    , signatureRelations =
        Map.fromList [(relationId relation, relation) | relation <- relations]
    , signatureEndpoints =
        Map.fromList
          [ (endpointId endpoint, endpoint)
          | relation <- relations
          , endpoint <- toList (relationEndpoints relation)
          ]
    , signatureActions =
        Map.fromList [(actionId action, action) | action <- actions]
    , signatureParameters =
        Map.fromList
          [ (parameterId parameter, parameter)
          | action <- actions
          , parameter <- actionParameters action
          ]
    , signatureUser =
        case
          [ entityId entity
          | entity <- entities
          , sourcedValue (entityName entity) == distinguishedUserEntity
          ]
        of
          found : _ -> Just found
          [] -> Nothing
    }
  where
    entities = modelEntities model
    relations = modelRelations model
    actions = modelActions model

-- | Look up a resolved reference, classifying a miss as an internal
-- invariant at the reference's own path.
referenced
  :: Ord key
  => (Signature -> Map key declaration)
  -> Text
  -> Signature
  -> Ref key
  -> Check declaration
referenced select label sig ref =
  case Map.lookup (refTarget ref) (select sig) of
    Just declaration -> pure declaration
    Nothing ->
      invariant
        (refPath ref)
        ("a resolved " <> label <> " reference does not name a " <> label <> " of the model")

entitySig :: Signature -> Ref EntityId -> Check Entity
entitySig = referenced signatureEntities "entity"

attributeSig :: Signature -> Ref AttributeId -> Check Attribute
attributeSig = referenced signatureAttributes "attribute"

relationSig :: Signature -> Ref RelationId -> Check Relation
relationSig = referenced signatureRelations "relation"

endpointSig :: Signature -> Ref EndpointId -> Check Endpoint
endpointSig = referenced signatureEndpoints "endpoint"

enumSig :: Signature -> Ref EnumId -> Check EnumDefinition
enumSig = referenced signatureEnums "enum"

parameterSig :: Signature -> Ref ParameterId -> Check Parameter
parameterSig = referenced signatureParameters "parameter"

-- | Look up an enum carried inside an already-inferred type (no
-- reference site of its own; the invariant lands at the use site).
enumSigAt :: Signature -> SourcePath -> EnumId -> Check EnumDefinition
enumSigAt sig path target =
  case Map.lookup target (signatureEnums sig) of
    Just definition -> pure definition
    Nothing ->
      invariant path "a resolved enum reference does not name an enum of the model"

--------------------------------------------------------------------
-- Names and type rendering
--------------------------------------------------------------------

-- | The declared name behind an identifier, for diagnostics.  The
-- positional fallbacks are unreachable while the model upholds the
-- resolver's contract (every judgment site checks its identifiers
-- first); they only keep rendering total.
entityLabel :: Signature -> EntityId -> Text
entityLabel sig target@(EntityId position) =
  quoted $ case Map.lookup target (signatureEntities sig) of
    Just entity -> sourcedValue (entityName entity)
    Nothing -> positionalName position

enumLabel :: Signature -> EnumId -> Text
enumLabel sig target@(EnumId position) =
  quoted $ case Map.lookup target (signatureEnums sig) of
    Just definition -> sourcedValue (enumDefinitionName definition)
    Nothing -> positionalName position

positionalName :: Int -> Text
positionalName position = "#" <> Text.pack (show position)

-- | Render a value type the way the surface syntax spells its
-- constructors: @Bool@, @Unit@, @Enum \"Level\"@, @EntityRef \"User\"@.
describeValueType :: Signature -> ValueType -> Text
describeValueType sig valueType =
  case valueType of
    BoolType -> "Bool"
    UnitType -> "Unit"
    EnumType target -> "Enum " <> enumLabel sig target
    EntityRefType target -> "EntityRef " <> entityLabel sig target

-- | Render a policy type; optional compound types are parenthesized.
describePolicyType :: Signature -> PolicyType -> Text
describePolicyType sig policyType =
  case policyType of
    ValuePolicyType inner -> describeValueType sig inner
    OptionalPolicyType inner ->
      case inner of
        BoolType -> "Optional Bool"
        UnitType -> "Optional Unit"
        _ -> "Optional (" <> describeValueType sig inner <> ")"

--------------------------------------------------------------------
-- Term typing
--------------------------------------------------------------------

-- | The context a term is checked in: the signature plus the action
-- whose parameter environment is in scope (the enclosing action, or
-- a guarantee case's referenced action).
data Env = Env
  { envSignature :: Signature
  , envAction :: ActionId
  }

-- | The retained source path of a value term.
valueTermPath :: ValueTerm availability -> SourcePath
valueTermPath term =
  case term of
    BoolTerm path _ -> path
    UnitTerm path -> path
    EnumTerm path _ _ -> path
    ArgumentTerm path _ -> path
    ActorTerm path _ -> path
    AttributeTerm path _ _ -> path

-- | The retained source path of a policy term.
policyTermPath :: PolicyTerm availability -> SourcePath
policyTermPath term =
  case term of
    ValuePolicyTerm valueTerm -> valueTermPath valueTerm
    LookupTerm path _ _ -> path
    NoneTerm path _ -> path
    SomeTerm path _ -> path
    IsSomeTerm path _ -> path
    EqualTerm path _ _ -> path
    LessOrEqualTerm path _ _ -> path
    AndTerm path _ _ -> path
    OrTerm path _ _ -> path
    NotTerm path _ -> path

-- | Infer the type of a value term.  After successful resolution
-- this never fails for a user reason: every failure path here is an
-- internal invariant.
inferValue :: Env -> ValueTerm availability -> Check ValueType
inferValue env term =
  case term of
    BoolTerm _ _ -> pure BoolType
    UnitTerm _ -> pure UnitType
    EnumTerm _ enumRef valueRef ->
      enumSig sig enumRef `andThen` \definition ->
        let EnumValueId owner position = refTarget valueRef
         in if owner == enumDefinitionId definition
              && position >= 0
              && position < NonEmpty.length (enumDefinitionValues definition)
              then pure (EnumType (enumDefinitionId definition))
              else
                invariant
                  (refPath valueRef)
                  "a resolved enum-value reference does not name a value of its enum"
    ArgumentTerm _ parameterRef ->
      let ParameterId owner _ = refTarget parameterRef
       in if owner /= envAction env
            then
              invariant
                (refPath parameterRef)
                "an argument reference escapes its action's parameter environment"
            else
              parameterSig sig parameterRef `andThen` \parameter ->
                pure (parameterValueType (parameterType parameter))
    ActorTerm path userEntity ->
      case signatureUser sig of
        Just distinguished
          | distinguished == userEntity -> pure (EntityRefType userEntity)
        _ ->
          invariant
            path
            ( "an Actor term does not reference the distinguished "
                <> quoted distinguishedUserEntity
                <> " entity"
            )
    AttributeTerm _ source attributeRef ->
      attributeSig sig attributeRef `andThen` \attribute ->
        let AttributeId owner _ = refTarget attributeRef
         in inferValue env source `andThen` \sourceType ->
              if sourceType == EntityRefType owner
                then pure (attributeValueType (attributeType attribute))
                else
                  invariant
                    (valueTermPath source)
                    "the source of an attribute projection does not have the attribute's entity type"
  where
    sig = envSignature env

-- | Infer the type of a policy term, reporting every violation of
-- the constructors along the way.  Like 'inferValue', the result is
-- withheld only by internal invariants — user violations are
-- reported and the (still determined) type carries on, so
-- independent problems in an enclosing term are still found.
inferPolicy :: Env -> PolicyTerm availability -> Check PolicyType
inferPolicy env term =
  case term of
    ValuePolicyTerm valueTerm -> ValuePolicyType <$> inferValue env valueTerm
    LookupTerm path relationRef endpointTerms ->
      relationSig sig relationRef `andThen` \relation ->
        checkEndpointTerms env path relation (toList endpointTerms)
          *> pure (OptionalPolicyType (payloadValueType (relationPayload relation)))
    NoneTerm _ payload -> pure (OptionalPolicyType (payloadValueType payload))
    SomeTerm _ valueTerm -> OptionalPolicyType <$> inferValue env valueTerm
    IsSomeTerm _ operand ->
      ( inferPolicy env operand `andThen` \operandType ->
          case operandType of
            OptionalPolicyType _ -> pure ()
            ValuePolicyType _ ->
              flagged
                (policyTermPath operand)
                ( "the operand of \"IsSome\" must have an Optional type, but this term has type "
                    <> describePolicyType sig operandType
                )
      )
        *> pure boolPolicyType
    EqualTerm path left right ->
      checkComparison env "Equal" path left right (\_ -> pure ())
        *> pure boolPolicyType
    LessOrEqualTerm path left right ->
      checkComparison env "LessOrEqual" path left right (requireOrdered env path)
        *> pure boolPolicyType
    AndTerm _ left right ->
      requireBool env "an operand of \"And\"" left
        *> requireBool env "an operand of \"And\"" right
        *> pure boolPolicyType
    OrTerm _ left right ->
      requireBool env "an operand of \"Or\"" left
        *> requireBool env "an operand of \"Or\"" right
        *> pure boolPolicyType
    NotTerm _ operand ->
      requireBool env "the operand of \"Not\"" operand *> pure boolPolicyType
  where
    sig = envSignature env

-- | Both operands must have the same type; when they do, the
-- comparison-specific continuation checks that shared type.
checkComparison
  :: Env
  -> Text
  -> SourcePath
  -> PolicyTerm availability
  -> PolicyTerm availability
  -> (PolicyType -> Check ())
  -> Check ()
checkComparison env operator path left right whenCompatible =
  ((,) <$> inferPolicy env left <*> inferPolicy env right)
    `andThen` \(leftType, rightType) ->
      if leftType == rightType
        then whenCompatible leftType
        else
          flagged
            path
            ( "the operands of "
                <> quoted operator
                <> " have incompatible types: "
                <> describePolicyType (envSignature env) leftType
                <> " and "
                <> describePolicyType (envSignature env) rightType
            )

-- | The shared operand type of a @LessOrEqual@ must be ordered:
-- @Enum E@ or @Optional (Enum E)@ where @E@ declares an explicit
-- order (mirroring the kernel's ordered types, with absence as
-- bottom on the optional level).  An /incomplete/ declared order is
-- reported at the enum declaration, not here.
requireOrdered :: Env -> SourcePath -> PolicyType -> Check ()
requireOrdered env path operandType =
  case orderedCandidate of
    Nothing ->
      flagged
        path
        ( "the operands of \"LessOrEqual\" have type "
            <> describePolicyType sig operandType
            <> ", which has no order"
        )
    Just enumTarget ->
      enumSigAt sig path enumTarget `andThen` \definition ->
        case enumDefinitionOrder definition of
          Just _ -> pure ()
          Nothing ->
            flagged
              path
              ( "the operands of \"LessOrEqual\" have type "
                  <> describePolicyType sig operandType
                  <> ", but enum "
                  <> enumLabel sig enumTarget
                  <> " declares no order"
              )
  where
    sig = envSignature env
    orderedCandidate =
      case operandType of
        ValuePolicyType (EnumType enumTarget) -> Just enumTarget
        OptionalPolicyType (EnumType enumTarget) -> Just enumTarget
        _ -> Nothing

-- | A policy position that must have type @Bool@: allow policies,
-- boolean operands, and the boolean guarantee-case terms.
requireBool :: Env -> Text -> PolicyTerm availability -> Check ()
requireBool env description operand =
  inferPolicy env operand `andThen` \operandType ->
    if operandType == boolPolicyType
      then pure ()
      else
        flagged
          (policyTermPath operand)
          ( description
              <> " must have type Bool, but this term has type "
              <> describePolicyType (envSignature env) operandType
          )

-- | A value position that must reference an entity (of any entity
-- type): @Observe@ results, @DeleteEntity@ targets, and
-- @TenantIsolation@ tenant terms.
requireEntityReference :: Env -> Text -> ValueTerm availability -> Check ()
requireEntityReference env clause term =
  inferValue env term `andThen` \termType ->
    case termType of
      EntityRefType _ -> pure ()
      _ ->
        flagged
          (valueTermPath term)
          ( clause
              <> ", but this term has type "
              <> describeValueType (envSignature env) termType
          )

-- | The endpoint terms of a lookup or relation effect: exact arity,
-- then — only when the arity matches, since any other pairing would
-- be a guess — each position must have its endpoint's entity type.
-- The terms themselves are checked either way.
checkEndpointTerms
  :: Env -> SourcePath -> Relation -> [ValueTerm availability] -> Check ()
checkEndpointTerms env sitePath relation terms
  | length terms /= length declared =
      flagged
        sitePath
        ( "relation "
            <> relationLabel
            <> " declares "
            <> countOf (length declared) "endpoint"
            <> ", but "
            <> countOf (length terms) "endpoint term"
            <> areGiven (length terms)
        )
        *> traverse_ (\term -> () <$ inferValue env term) terms
  | otherwise = traverse_ checkPosition (zip declared terms)
  where
    sig = envSignature env
    declared = toList (relationEndpoints relation)
    relationLabel = quoted (sourcedValue (relationName relation))
    areGiven 1 = " is given"
    areGiven _ = " are given"
    checkPosition (endpoint, term) =
      inferValue env term `andThen` \termType ->
        let expected = EntityRefType (refTarget (endpointEntity endpoint))
         in if termType == expected
              then pure ()
              else
                flagged
                  (valueTermPath term)
                  ( "endpoint "
                      <> quoted (sourcedValue (endpointName endpoint))
                      <> " of relation "
                      <> relationLabel
                      <> " requires type "
                      <> describeValueType sig expected
                      <> ", but this term has type "
                      <> describeValueType sig termType
                  )

countOf :: Int -> Text -> Text
countOf 1 noun = "1 " <> noun
countOf n noun = Text.pack (show n) <> " " <> noun <> "s"

--------------------------------------------------------------------
-- Declarations
--------------------------------------------------------------------

-- | A declared enum order must be a complete permutation of the
-- enum's values.  Members are structurally unique and were resolved
-- against the enum's own values, so completeness is the one
-- remaining judgment; each omitted value is reported at the enum
-- declaration.
checkEnum :: Signature -> EnumDefinition -> Check ()
checkEnum sig definition =
  case enumDefinitionOrder definition of
    Nothing -> pure ()
    Just orderRefs ->
      traverse_ checkOrderMember orderRefs
        *> traverse_ reportMissing missing
      where
        listed =
          Set.fromList (map refTarget (NonEmpty.toList orderRefs))
        members = NonEmpty.toList (enumDefinitionValues definition)
        missing =
          [member | member <- members, enumMemberId member `Set.notMember` listed]
        checkOrderMember ref =
          let EnumValueId owner position = refTarget ref
           in if owner == enumDefinitionId definition
                && position >= 0
                && position < length members
                then pure ()
                else
                  invariant
                    (refPath ref)
                    "an enum-order member does not reference the enum's own values"
        reportMissing member =
          flagged
            (enumDefinitionPath definition)
            ( "the order of enum "
                <> enumLabel sig (enumDefinitionId definition)
                <> " does not include value "
                <> quoted (sourcedValue (enumMemberName member))
            )

--------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------

checkAction :: Signature -> Action -> Check ()
checkAction sig action =
  case actionBody action of
    AuthenticatedOnlyBody allow shape ->
      requireBool env "an allow policy" allow *> checkShape env shape
    AnyPrincipalBody allow shape ->
      requireBool env "an allow policy" (anyPrincipalAnonymous allow)
        *> requireBool env "an allow policy" (anyPrincipalAuthenticated allow)
        *> checkShape env shape
  where
    env = Env sig (actionId action)

checkShape :: Env -> ActionShape availability -> Check ()
checkShape env shape =
  case shape of
    ReadShape _ _ observed ->
      requireEntityReference
        env
        "an \"Observe\" result must observe an entity reference"
        observed
    CreateShape effect _ -> checkCreateEntityEffect env effect
    MutationShape effect _ -> checkDoneEffect env effect

-- | A @CreateEntity@ effect: every attribute of the target entity
-- must be initialized (keys are unique and resolved against the
-- target by construction), and every initializer term must have its
-- attribute's declared type.
checkCreateEntityEffect :: Env -> CreateEntityEffect availability -> Check ()
checkCreateEntityEffect env effect =
  entitySig sig (createEntityEffectEntity effect) `andThen` \entity ->
    let target = entityId entity
        targetLabel = entityLabel sig target
        initializers = createEntityEffectInitializers effect
        initialized =
          Set.fromList [refTarget (initializerKey i) | i <- initializers]
        missing =
          [ attribute
          | attribute <- entityAttributes entity
          , attributeId attribute `Set.notMember` initialized
          ]
        reportMissing attribute =
          flagged
            (createEntityEffectPath effect)
            ( "attribute "
                <> quoted (sourcedValue (attributeName attribute))
                <> " of entity "
                <> targetLabel
                <> " is not initialized"
            )
        checkInitializer initializer =
          let keyRef = initializerKey initializer
              AttributeId owner _ = refTarget keyRef
           in if owner /= target
                then
                  invariant
                    (refPath keyRef)
                    "a \"CreateEntity\" initializer key does not belong to the target entity"
                else
                  attributeSig sig keyRef `andThen` \attribute ->
                    inferValue env (initializerValue initializer)
                      `andThen` \valueType ->
                        let expected = attributeValueType (attributeType attribute)
                         in if valueType == expected
                              then pure ()
                              else
                                flagged
                                  (valueTermPath (initializerValue initializer))
                                  ( "attribute "
                                      <> quoted (sourcedValue (attributeName attribute))
                                      <> " of entity "
                                      <> targetLabel
                                      <> " has type "
                                      <> describeValueType sig expected
                                      <> ", but this initializer has type "
                                      <> describeValueType sig valueType
                                  )
     in traverse_ reportMissing missing *> traverse_ checkInitializer initializers
  where
    sig = envSignature env

checkDoneEffect :: Env -> DoneEffect availability -> Check ()
checkDoneEffect env effect =
  case effect of
    NoChangeEffect _ -> pure ()
    DeleteEntityEffect _ target ->
      requireEntityReference
        env
        "the target of \"DeleteEntity\" must be an entity reference"
        target
    SetRelationEffect path relationRef endpointTerms payload ->
      relationSig sig relationRef `andThen` \relation ->
        checkEndpointTerms env path relation (toList endpointTerms)
          *> checkPayloadTerm relation payload
    RemoveRelationEffect path relationRef endpointTerms ->
      relationSig sig relationRef `andThen` \relation ->
        checkEndpointTerms env path relation (toList endpointTerms)
  where
    sig = envSignature env
    checkPayloadTerm relation payload =
      inferValue env payload `andThen` \payloadType ->
        let expected = payloadValueType (relationPayload relation)
         in if payloadType == expected
              then pure ()
              else
                flagged
                  (valueTermPath payload)
                  ( "the payload of relation "
                      <> quoted (sourcedValue (relationName relation))
                      <> " must have type "
                      <> describeValueType sig expected
                      <> ", but this term has type "
                      <> describeValueType sig payloadType
                  )

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

checkGuarantee :: Signature -> Guarantee -> Check ()
checkGuarantee sig guarantee =
  case guarantee of
    AuthenticatedMutationGuarantee _ ->
      -- The structural selector carries no terms; whether every
      -- mutation actually requires authentication is a verification
      -- question, not a typing one.
      pure ()
    TenantIsolationGuarantee _ cases ->
      traverse_ (checkTenantIsolationCase sig) cases
    NoSelfPrivilegeEscalationGuarantee _ authority cases ->
      checkAuthority sig authority `andThen` \scopeEndpoint ->
        traverse_ (checkEscalationCase sig scopeEndpoint) cases

-- | The environment of a guarantee case: its referenced action's
-- parameter environment (the resolver checked the case terms in the
-- same environment).
caseEnv :: Signature -> Ref ActionId -> Check Env
caseEnv sig actionRef =
  case Map.lookup (refTarget actionRef) (signatureActions sig) of
    Just _ -> pure (Env sig (refTarget actionRef))
    Nothing ->
      invariant
        (refPath actionRef)
        "a resolved action reference does not name an action of the model"

checkTenantIsolationCase :: Signature -> TenantIsolationCase -> Check ()
checkTenantIsolationCase sig tenantCase =
  caseEnv sig (tenantIsolationCaseAction tenantCase) `andThen` \env ->
    requireEntityReference
      env
      "the \"tenant\" term must be an entity reference"
      (tenantIsolationCaseTenant tenantCase)
      *> requireBool
        env
        "the \"protected\" term"
        (tenantIsolationCaseProtected tenantCase)
      *> requireBool
        env
        "the \"tenantAccess\" term"
        (tenantIsolationCaseTenantAccess tenantCase)

-- | The @NoSelfPrivilegeEscalation@ authority, yielding the declared
-- scope endpoint (when any) for the per-case checks.  The subject
-- endpoint must reference the distinguished @User@ entity, subject
-- and scope endpoints must be distinct and together cover the
-- relation's endpoints, and the relation's payload must be exactly
-- the @payloadOrder@ enum, which must declare an order.
checkAuthority :: Signature -> Authority -> Check (Maybe Endpoint)
checkAuthority sig authority =
  relationSig sig (authorityRelation authority) `andThen` \relation ->
    endpointSig sig (authoritySubjectEndpoint authority) `andThen` \subject ->
      ownedByAuthority relation subject (authoritySubjectEndpoint authority)
        *> checkSubjectEntity relation subject
        *> checkPayloadOrder relation
        *> checkScope relation subject
  where
    ownedByAuthority relation endpoint ref =
      let EndpointId owner _ = endpointId endpoint
       in if owner == relationId relation
            then pure ()
            else
              invariant
                (refPath ref)
                "an authority endpoint does not belong to the authority relation"

    checkSubjectEntity relation subject =
      case signatureUser sig of
        Nothing ->
          invariant
            (refPath (authoritySubjectEndpoint authority))
            ( "the resolved model declares no distinguished "
                <> quoted distinguishedUserEntity
                <> " entity"
            )
        Just user
          | refTarget (endpointEntity subject) == user -> pure ()
          | otherwise ->
              flagged
                (refPath (authoritySubjectEndpoint authority))
                ( "the subject endpoint "
                    <> quoted (sourcedValue (endpointName subject))
                    <> " of relation "
                    <> quoted (sourcedValue (relationName relation))
                    <> " must reference the distinguished "
                    <> quoted distinguishedUserEntity
                    <> " entity, but it references entity "
                    <> entityLabel sig (refTarget (endpointEntity subject))
                )

    checkPayloadOrder relation =
      enumSig sig (authorityPayloadOrder authority) `andThen` \orderEnum ->
        let orderPath = refPath (authorityPayloadOrder authority)
            orderName = enumLabel sig (enumDefinitionId orderEnum)
            relationLabel = quoted (sourcedValue (relationName relation))
            compatible =
              case relationPayload relation of
                UnitPayloadType _ ->
                  flagged
                    orderPath
                    ( "relation "
                        <> relationLabel
                        <> " has a Unit payload, so enum "
                        <> orderName
                        <> " cannot rank its authority levels"
                    )
                EnumPayloadType _ payloadEnum
                  | refTarget payloadEnum == enumDefinitionId orderEnum ->
                      pure ()
                  | otherwise ->
                      flagged
                        orderPath
                        ( "relation "
                            <> relationLabel
                            <> " has an Enum "
                            <> enumLabel sig (refTarget payloadEnum)
                            <> " payload, so enum "
                            <> orderName
                            <> " cannot rank its authority levels"
                        )
            ordered =
              case enumDefinitionOrder orderEnum of
                Just _ -> pure ()
                Nothing ->
                  flagged
                    orderPath
                    ( "enum "
                        <> orderName
                        <> " declares no order, so it cannot rank authority levels"
                    )
         in compatible *> ordered

    -- Subject and scope endpoints must cover the relation's
    -- endpoints.  A scope endpoint equal to the subject is the root
    -- cause of any coverage gap, so coverage is judged only when the
    -- endpoints are distinct; with distinct endpoints and the
    -- structural one-or-two bound, the only remaining coverage gap
    -- is an arity-two relation whose authority names no scope
    -- endpoint.
    checkScope relation subject =
      case authorityScopeEndpoint authority of
        Nothing ->
          ( case relationEndpoints relation of
              One _ -> pure ()
              Two _ _ ->
                flagged
                  (authorityPath authority)
                  ( "relation "
                      <> quoted (sourcedValue (relationName relation))
                      <> " declares 2 endpoints, but the authority names only the subject endpoint"
                  )
          )
            *> pure Nothing
        Just scopeRef ->
          endpointSig sig scopeRef `andThen` \scopeEndpoint ->
            ownedByAuthority relation scopeEndpoint scopeRef
              *> ( if endpointId scopeEndpoint == endpointId subject
                     then
                       flagged
                         (refPath scopeRef)
                         ( "the scope endpoint duplicates the subject endpoint "
                             <> quoted (sourcedValue (endpointName subject))
                         )
                     else pure ()
                 )
              *> pure (Just scopeEndpoint)

-- | One @NoSelfPrivilegeEscalation@ case: its scope terms must
-- correspond one-to-one with the authority's scope endpoints, and a
-- present scope term must have the scope endpoint's entity type in
-- the case's action environment.
checkEscalationCase :: Signature -> Maybe Endpoint -> EscalationCase -> Check ()
checkEscalationCase sig scopeEndpoint escalationCase =
  caseEnv sig (escalationCaseAction escalationCase) `andThen` \env ->
    case (scopeEndpoint, escalationCaseScope escalationCase) of
      (Nothing, Nothing) -> pure ()
      (Nothing, Just scopeTerm) ->
        (() <$ inferValue env scopeTerm)
          *> flagged
            (valueTermPath scopeTerm)
            "this case names a scope term, but the authority declares no scope endpoint"
      (Just endpoint, Nothing) ->
        flagged
          (escalationCasePath escalationCase)
          ( "this case names no scope term, but the authority declares the scope endpoint "
              <> quoted (sourcedValue (endpointName endpoint))
          )
      (Just endpoint, Just scopeTerm) ->
        inferValue env scopeTerm `andThen` \termType ->
          let expected = EntityRefType (refTarget (endpointEntity endpoint))
           in if termType == expected
                then pure ()
                else
                  flagged
                    (valueTermPath scopeTerm)
                    ( "the scope term must have type "
                        <> describeValueType (envSignature env) expected
                        <> " (the entity of scope endpoint "
                        <> quoted (sourcedValue (endpointName endpoint))
                        <> "), but this term has type "
                        <> describeValueType (envSignature env) termType
                    )

--------------------------------------------------------------------
-- The model
--------------------------------------------------------------------

-- | Check a complete resolved model: every enum declaration, every
-- action, and every guarantee.  Entity, relation, attribute,
-- parameter, and payload declarations carry only resolved references
-- that name resolution already established, so no further judgment
-- applies to them.  Problems aggregate across the whole model; the
-- caller partitions, normalizes, and classifies them.
checkModel :: Model -> Collect TypingProblem ()
checkModel model =
  traverse_ (checkEnum sig) (modelEnums model)
    *> traverse_ (checkAction sig) (modelActions model)
    *> traverse_ (checkGuarantee sig) (modelGuarantees model)
  where
    sig = buildSignature model
