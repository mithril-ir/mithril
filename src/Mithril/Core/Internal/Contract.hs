{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The Core v0 security-contract renderer: the one pass that turns the
-- explicit typed normalized representation
-- ("Mithril.Core.Internal.Normalized") of a normalized document into
-- the deterministic, line-oriented, human-readable security contract.
-- It is the first consumer of typed normalized Core, and it consumes
-- only that representation — never raw JSON, never the resolved or
-- typed models, and never a rebuilt judgment of an earlier stage:
--
-- * every reference is followed through its resolved
--   namespace-specific identifier to the referenced declaration, whose
--   name metadata is what the contract prints — no textual name is
--   ever resolved again;
-- * every printed type annotation is the static type the typechecker
--   stamped on the normalized term (or the shared declared-type
--   projections of "Mithril.Core.Internal.StaticType" for declared
--   families) — no type inference is rerun;
-- * enum orders are printed from the materialized rankings, ordered
--   comparisons from their stored 'Normalized.OrderedType' evidence,
--   lookups and relation effects from their explicit endpoint
--   bindings, @CreateEntity@ initializers in the normalized
--   (target-attribute declaration) order, and escalation scopes from
--   their explicit scope bindings — nothing is re-derived; and
-- * authored operand and policy structure is preserved exactly: no
--   simplification, folding, reordering, or evaluation, and no
--   information the normalized model does not carry.
--
-- == The format
--
-- The contract is plain, line-oriented text with two-space
-- indentation and a fixed section order: header (the fixed
-- @Mithril Core v0@ language identity and the model name), entities,
-- enums, relations, actions, selected guarantees (explicitly labelled
-- unverified proof obligations), and a fixed limitations section.
-- Declarations appear in normalized declaration order; nothing is
-- alphabetized.  Terms render in an unambiguous, fully parenthesized,
-- constructor-preserving syntax — @Constructor[metadata](subterms)@,
-- for example @LessOrEqual[order optional Rank, absence as
-- bottom](Some(Enum[Rank.Silver]), Lookup[Membership](member =
-- Actor[User], organization = Argument[organization]))@ — and every
-- term printed at a labelled site carries its stored static type
-- after @ : @.  A successful contract contains no internal numeric
-- identifiers, no timestamps, no file or environment paths, and no
-- JSON details (all names are schema-constrained to ASCII
-- alphanumerics, so no control character can reach the output); it
-- ends with exactly one final newline.  The exact bytes are frozen by
-- the golden and literal expectations of the test suite.
--
-- == Failure classification
--
-- A normalized document produced by the public pipeline always
-- renders: this boundary deliberately has no user-error class.  The
-- only refusal is 'ContractRendererInvariantViolation' — a
-- referential inconsistency of the normalized model (a dangling
-- identifier, an enum value outside its enum, an endpoint binding
-- outside its relation, an initializer key outside its target entity,
-- a tenant-access endpoint outside its access relation, ordered
-- evidence naming an unranked enum, or a scope binding that
-- contradicts its authority) that no pipeline-produced document can
-- exhibit.  Such violations indicate frontend drift or a
-- normalizer\/renderer bug, never a problem with the user's document;
-- they aggregate across the whole model, deterministically, and the
-- renderer never throws and never prints a placeholder.
module Mithril.Core.Internal.Contract
  ( -- * Violations
    ContractRendererInvariantViolation (..)

    -- * The rendering pass
  , renderModelContract
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.Report (Collect, andThen, refuse)
import Mithril.Core.Internal.Resolved
  ( ActionId
  , AttributeId (..)
  , EndpointId (..)
  , EntityId
  , EnumId
  , EnumValueId (..)
  , ParameterId (..)
  , Ref (..)
  , RelationId
  )
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , sourcePathSegments
  )
import Mithril.Core.Internal.StaticType
  ( OrderedType (..)
  , PolicyType (..)
  , ValueType (..)
  , attributeStaticType
  , parameterStaticType
  , payloadStaticType
  )
import Mithril.Core.Internal.Syntax (AbsenceLevel (..), OneOrTwo (..))

--------------------------------------------------------------------
-- Violations
--------------------------------------------------------------------

-- | One contract-renderer invariant violation: a referential
-- inconsistency of the normalized model the renderer cannot present
-- faithfully.  This is evidence of frontend drift or a
-- normalizer\/renderer bug — an internal error of the @mithril@ tool,
-- never a problem with the user's document, which by construction has
-- no user-error class at this stage.
data ContractRendererInvariantViolation = ContractRendererInvariantViolation
  { contractRendererInvariantPath :: [Text]
    -- ^ Instance path of the inconsistent site, as raw (unescaped)
    -- segments; render with
    -- 'Mithril.Core.Validation.renderJsonPointer'.
  , contractRendererInvariantMessage :: Text
    -- ^ Description of the expectation that failed.
  }
  deriving (Eq, Ord, Show)

-- | A rendering step: aggregates invariant violations while building
-- contract text.  There is deliberately no user problem class.
type Render a = Collect ContractRendererInvariantViolation a

-- | Fail with one invariant violation at a source path.
refuseAt :: SourcePath -> Text -> Render a
refuseAt path message =
  refuse (ContractRendererInvariantViolation (sourcePathSegments path) message)

--------------------------------------------------------------------
-- The contract
--------------------------------------------------------------------

-- | Render a complete normalized model as the security contract (the
-- module header states the format and exactly what rendering does and
-- does not establish).  Pure and deterministic: the same model always
-- produces the same bytes or the same violations, and the successful
-- text ends with exactly one final newline.
renderModelContract :: Normalized.Model -> Render Text
renderModelContract model =
  assemble
    <$> sectionBody (entityBlock model) (Normalized.modelEntities model)
    <*> sectionBody (enumBlock model) (Normalized.modelEnums model)
    <*> sectionBody (relationBlock model) (Normalized.modelRelations model)
    <*> sectionBody (actionBlock model) (Normalized.modelActions model)
    <*> sectionBody (guaranteeBlock model) (Normalized.modelGuarantees model)
  where
    assemble entities enums relations actions guarantees =
      Text.unlines
        ( headerLines model
            <> sectionLines "Entities" entities
            <> sectionLines "Enums" enums
            <> sectionLines "Relations" relations
            <> sectionLines "Actions" actions
            <> sectionLines
              "Selected guarantees (unverified proof obligations)"
              guarantees
            <> sectionLines "Limitations and non-claims" limitationLines
        )

-- | The fixed header: the Core language identity and version are
-- constants of the renderer (the external @format@\/@formatVersion@
-- members are structural constants that carry no model content), and
-- the model name comes from the normalized model — never from raw
-- JSON and never from the input file name.
headerLines :: Normalized.Model -> [Text]
headerLines model =
  [ "Mithril Core v0 security contract"
  , "model: " <> sourcedValue (Normalized.modelName model)
  ]

-- | A section: one blank separator line, the title, and the body — or
-- the explicit @(none)@ marker, so an empty section is never silent.
sectionLines :: Text -> [Text] -> [Text]
sectionLines title body =
  "" : title : (if null body then ["  (none)"] else body)

-- | Render every declaration of a section in normalized declaration
-- order (never alphabetized).
sectionBody :: (declaration -> Render [Text]) -> [declaration] -> Render [Text]
sectionBody block declarations = concat <$> traverse block declarations

-- | The fixed limitations of this artifact.  These lines are frozen
-- non-claims: they state what producing the contract did not do.
-- Core v0 has no authored assumptions field, so no assumption is
-- invented here.
limitationLines :: [Text]
limitationLines =
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
-- Declaration lookups (identifier -> declaration metadata)
--------------------------------------------------------------------

-- The renderer follows resolved identifiers to the declarations they
-- name and prints the declarations' name metadata.  On a normalized
-- model produced by the public pipeline every lookup succeeds by
-- construction; a failing lookup is a forged or drifted model and is
-- refused as an invariant violation — never rendered as a
-- placeholder.

entityAt :: Normalized.Model -> SourcePath -> EntityId -> Render Normalized.Entity
entityAt model site target =
  case
    [ entity
    | entity <- Normalized.modelEntities model
    , Normalized.entityId entity == target
    ]
  of
    entity : _ -> pure entity
    [] -> refuseAt site "a resolved entity reference does not name an entity of the model"

entityNameAt :: Normalized.Model -> SourcePath -> EntityId -> Render Text
entityNameAt model site target =
  sourcedValue . Normalized.entityName <$> entityAt model site target

enumAt :: Normalized.Model -> SourcePath -> EnumId -> Render Normalized.EnumDefinition
enumAt model site target =
  case
    [ definition
    | definition <- Normalized.modelEnums model
    , Normalized.enumDefinitionId definition == target
    ]
  of
    definition : _ -> pure definition
    [] -> refuseAt site "a resolved enum reference does not name an enum of the model"

enumNameAt :: Normalized.Model -> SourcePath -> EnumId -> Render Text
enumNameAt model site target =
  sourcedValue . Normalized.enumDefinitionName <$> enumAt model site target

relationAt :: Normalized.Model -> SourcePath -> RelationId -> Render Normalized.Relation
relationAt model site target =
  case
    [ relation
    | relation <- Normalized.modelRelations model
    , Normalized.relationId relation == target
    ]
  of
    relation : _ -> pure relation
    [] -> refuseAt site "a resolved relation reference does not name a relation of the model"

relationNameAt :: Normalized.Model -> SourcePath -> RelationId -> Render Text
relationNameAt model site target =
  sourcedValue . Normalized.relationName <$> relationAt model site target

actionAt :: Normalized.Model -> SourcePath -> ActionId -> Render Normalized.Action
actionAt model site target =
  case
    [ action
    | action <- Normalized.modelActions model
    , Normalized.actionId action == target
    ]
  of
    action : _ -> pure action
    [] -> refuseAt site "a resolved action reference does not name an action of the model"

attributeNameAt :: Normalized.Model -> SourcePath -> AttributeId -> Render Text
attributeNameAt model site target =
  case target of
    AttributeId owner _ ->
      entityAt model site owner `andThen` \entity ->
        case
          [ attribute
          | attribute <- Normalized.entityAttributes entity
          , Normalized.attributeId attribute == target
          ]
        of
          attribute : _ -> pure (sourcedValue (Normalized.attributeName attribute))
          [] -> refuseAt site "a resolved attribute reference does not name an attribute of the model"

enumValueNameAt :: Normalized.Model -> SourcePath -> EnumValueId -> Render Text
enumValueNameAt model site target =
  case target of
    EnumValueId owner _ ->
      enumAt model site owner `andThen` \definition ->
        case
          [ member
          | member <- NonEmpty.toList (Normalized.enumDefinitionValues definition)
          , Normalized.enumMemberId member == target
          ]
        of
          member : _ -> pure (sourcedValue (Normalized.enumMemberName member))
          [] -> refuseAt site "a resolved enum value reference does not name a value of the model"

endpointAt :: Normalized.Model -> SourcePath -> EndpointId -> Render Normalized.Endpoint
endpointAt model site target =
  case target of
    EndpointId owner _ ->
      relationAt model site owner `andThen` \relation ->
        case
          [ endpoint
          | endpoint <- oneOrTwoList (Normalized.relationEndpoints relation)
          , Normalized.endpointId endpoint == target
          ]
        of
          endpoint : _ -> pure endpoint
          [] -> refuseAt site "a resolved endpoint reference does not name an endpoint of the model"

-- | The name of a parameter reference, which must belong to the
-- action environment its term was typed in — an @Argument@ naming a
-- foreign action's parameter would print a name that means nothing in
-- this action, so it is refused instead.
parameterNameAt
  :: Normalized.Model -> ActionId -> SourcePath -> ParameterId -> Render Text
parameterNameAt model envAction site target =
  case target of
    ParameterId owner _
      | owner /= envAction ->
          refuseAt
            site
            "an \"Argument\" term does not name a parameter of its action's environment"
      | otherwise ->
          actionAt model site owner `andThen` \action ->
            case
              [ parameter
              | parameter <- Normalized.actionParameters action
              , Normalized.parameterId parameter == target
              ]
            of
              parameter : _ -> pure (sourcedValue (Normalized.parameterName parameter))
              [] -> refuseAt site "a resolved parameter reference does not name a parameter of the model"

oneOrTwoList :: OneOrTwo a -> [a]
oneOrTwoList shape =
  case shape of
    One only -> [only]
    Two firstItem secondItem -> [firstItem, secondItem]

--------------------------------------------------------------------
-- Types
--------------------------------------------------------------------

-- | Render a static value type: @Bool@, @Unit@, @Enum[Name]@, or
-- @EntityRef[Name]@.  The named declarations are followed through
-- their identifiers; nothing is inferred.
renderValueType :: Normalized.Model -> SourcePath -> ValueType -> Render Text
renderValueType model site valueType =
  case valueType of
    BoolType -> pure "Bool"
    UnitType -> pure "Unit"
    EnumType target ->
      (\name -> "Enum[" <> name <> "]") <$> enumNameAt model site target
    EntityRefType target ->
      (\name -> "EntityRef[" <> name <> "]") <$> entityNameAt model site target

-- | Render a static policy type: a value type or @Optional[...]@ over
-- one.
renderPolicyType :: Normalized.Model -> SourcePath -> PolicyType -> Render Text
renderPolicyType model site policyType =
  case policyType of
    ValuePolicyType valueType -> renderValueType model site valueType
    OptionalPolicyType valueType ->
      (\inner -> "Optional[" <> inner <> "]")
        <$> renderValueType model site valueType

--------------------------------------------------------------------
-- Terms
--------------------------------------------------------------------

-- | Render a value term in the fully parenthesized
-- constructor-preserving syntax.  Structure and operand order are the
-- normalized model's, verbatim.  Every visited node — the root and
-- every recursively nested child alike — also has its stored static
-- annotation ('Normalized.valueTermType') validated through the same
-- reference-following authority that prints types
-- ('renderValueType'), so a dangling declared-type reference inside
-- any stored annotation fails closed even where the format prints no
-- annotation for the node; the annotation is consumed as stored,
-- never inferred, recomputed, or compared against a semantic type,
-- and the validation adds nothing to successful output.
renderValue
  :: Normalized.Model
  -> ActionId
  -> Normalized.ValueTerm availability
  -> Render Text
renderValue model envAction term =
  annotationValidated *> nodeText
  where
    annotationValidated =
      () <$ renderValueType
        model
        (Normalized.valueTermPath term)
        (Normalized.valueTermType term)
    nodeText = case Normalized.valueTermNode term of
      Normalized.BoolNode flag ->
        pure (if flag then "Bool[true]" else "Bool[false]")
      Normalized.UnitNode -> pure "Unit"
      Normalized.EnumNode enumRef valueRef ->
        case refTarget valueRef of
          EnumValueId owner _
            | owner /= refTarget enumRef ->
                refuseAt
                  (refPath valueRef)
                  "the value of an enum term does not belong to the term's enum"
            | otherwise ->
                (\enumName valueName ->
                   "Enum[" <> enumName <> "." <> valueName <> "]")
                  <$> enumNameAt model (refPath enumRef) (refTarget enumRef)
                  <*> enumValueNameAt model (refPath valueRef) (refTarget valueRef)
      Normalized.ArgumentNode parameterRef ->
        (\name -> "Argument[" <> name <> "]")
          <$> parameterNameAt
            model
            envAction
            (refPath parameterRef)
            (refTarget parameterRef)
      Normalized.ActorNode userEntity ->
        (\name -> "Actor[" <> name <> "]")
          <$> entityNameAt model (Normalized.valueTermPath term) userEntity
      Normalized.AttributeNode source attributeRef ->
        (\attributeName sourceText ->
           "Attribute[" <> attributeName <> "](" <> sourceText <> ")")
          <$> attributeNameAt model (refPath attributeRef) (refTarget attributeRef)
          <*> renderValue model envAction source

-- | Render a policy term; see 'renderValue' — including the
-- every-visited-node validation of the stored annotation, here
-- 'Normalized.policyTermType' through 'renderPolicyType'.
renderPolicy
  :: Normalized.Model
  -> ActionId
  -> Normalized.PolicyTerm availability
  -> Render Text
renderPolicy model envAction term =
  annotationValidated *> nodeText
  where
    annotationValidated =
      () <$ renderPolicyType model sitePath (Normalized.policyTermType term)
    nodeText = case Normalized.policyTermNode term of
      Normalized.ValuePolicyNode inner -> renderValue model envAction inner
      Normalized.LookupNode relationRef bindings ->
        (\relationName bindingTexts ->
           "Lookup["
             <> relationName
             <> "]("
             <> Text.intercalate ", " bindingTexts
             <> ")")
          <$> relationNameAt model (refPath relationRef) (refTarget relationRef)
          <*> traverse
            (renderBindingInline model envAction (refTarget relationRef) sitePath)
            (oneOrTwoList bindings)
      Normalized.NoneNode payload ->
        (\payloadText -> "None[" <> payloadText <> "]")
          <$> renderValueType model sitePath (payloadStaticType payload)
      Normalized.SomeNode inner ->
        (\innerText -> "Some(" <> innerText <> ")")
          <$> renderValue model envAction inner
      Normalized.IsSomeNode operand ->
        (\operandText -> "IsSome(" <> operandText <> ")")
          <$> renderPolicy model envAction operand
      Normalized.EqualNode left right -> binary "Equal" left right
      Normalized.LessOrEqualNode ordered left right ->
        (\evidenceText leftText rightText ->
           "LessOrEqual["
             <> evidenceText
             <> "]("
             <> leftText
             <> ", "
             <> rightText
             <> ")")
          <$> renderOrderedType model sitePath ordered
          <*> renderPolicy model envAction left
          <*> renderPolicy model envAction right
      Normalized.AndNode left right -> binary "And" left right
      Normalized.OrNode left right -> binary "Or" left right
      Normalized.NotNode operand ->
        (\operandText -> "Not(" <> operandText <> ")")
          <$> renderPolicy model envAction operand
    sitePath = Normalized.policyTermPath term
    binary name left right =
      (\leftText rightText ->
         name <> "(" <> leftText <> ", " <> rightText <> ")")
        <$> renderPolicy model envAction left
        <*> renderPolicy model envAction right

-- | Render the stored ordered reading of a @LessOrEqual@: which
-- enum's declared order ranks the operands, and whether the
-- comparison happens at the optional level, where absence ranks as
-- bottom.  The evidence is consumed, never re-derived from the
-- operand types; the named enum must carry a materialized ranking,
-- because the bracket asserts that an order applies.
renderOrderedType :: Normalized.Model -> SourcePath -> OrderedType -> Render Text
renderOrderedType model site ordered =
  case ordered of
    EnumOrderedType target ->
      ("order " <>) <$> rankedEnumName target
    OptionalEnumOrderedType target ->
      (\name -> "order optional " <> name <> ", absence as bottom")
        <$> rankedEnumName target
  where
    rankedEnumName target =
      enumAt model site target `andThen` \definition ->
        case Normalized.enumDefinitionOrder definition of
          Just _ -> pure (sourcedValue (Normalized.enumDefinitionName definition))
          Nothing ->
            refuseAt
              site
              "the ordered reading of a \"LessOrEqual\" names an enum without a materialized ranking"

-- | One endpoint binding inside a term: @name = term@.  The bound
-- endpoint must belong to the bound relation — printing another
-- relation's endpoint name would misdescribe the site.
renderBindingInline
  :: Normalized.Model
  -> ActionId
  -> RelationId
  -> SourcePath
  -> Normalized.EndpointBinding availability
  -> Render Text
renderBindingInline model envAction boundRelation site binding =
  (\endpointName termText -> endpointName <> " = " <> termText)
    <$> boundEndpointName model boundRelation site binding
    <*> renderValue model envAction (Normalized.endpointBindingTerm binding)

-- | The declared name of a binding's endpoint, refused when the
-- endpoint does not belong to the relation the site binds.
boundEndpointName
  :: Normalized.Model
  -> RelationId
  -> SourcePath
  -> Normalized.EndpointBinding availability
  -> Render Text
boundEndpointName model boundRelation site binding =
  case Normalized.endpointBindingEndpoint binding of
    target@(EndpointId owner _)
      | owner /= boundRelation ->
          refuseAt
            site
            "an endpoint binding does not name an endpoint of the bound relation"
      | otherwise ->
          sourcedValue . Normalized.endpointName <$> endpointAt model site target

--------------------------------------------------------------------
-- Labelled term sites
--------------------------------------------------------------------

-- | A labelled value-term line: @label term : type@, the type being
-- the stored static annotation of the term.
valueSite
  :: Normalized.Model
  -> ActionId
  -> Text
  -> Normalized.ValueTerm availability
  -> Render Text
valueSite model envAction label term =
  (\termText typeText -> label <> termText <> " : " <> typeText)
    <$> renderValue model envAction term
    <*> renderValueType
      model
      (Normalized.valueTermPath term)
      (Normalized.valueTermType term)

-- | A labelled policy-term line; see 'valueSite'.
policySite
  :: Normalized.Model
  -> ActionId
  -> Text
  -> Normalized.PolicyTerm availability
  -> Render Text
policySite model envAction label term =
  (\termText typeText -> label <> termText <> " : " <> typeText)
    <$> renderPolicy model envAction term
    <*> renderPolicyType
      model
      (Normalized.policyTermPath term)
      (Normalized.policyTermType term)

--------------------------------------------------------------------
-- Entities, enums, relations
--------------------------------------------------------------------

entityBlock :: Normalized.Model -> Normalized.Entity -> Render [Text]
entityBlock model entity =
  (("  entity " <> sourcedValue (Normalized.entityName entity)) :)
    <$> attributeLines
  where
    attributeLines =
      case Normalized.entityAttributes entity of
        [] -> pure ["    (no attributes)"]
        attributes -> traverse attributeLine attributes
    attributeLine attribute =
      (\typeText ->
         "    attribute "
           <> sourcedValue (Normalized.attributeName attribute)
           <> " : "
           <> typeText)
        <$> renderValueType
          model
          (Normalized.attributePath attribute)
          (attributeStaticType (Normalized.attributeType attribute))

enumBlock :: Normalized.Model -> Normalized.EnumDefinition -> Render [Text]
enumBlock model definition =
  (\orderLines ->
     ("  enum " <> sourcedValue (Normalized.enumDefinitionName definition))
       : valueLines
         <> orderLines)
    <$> orderLinesRendered
  where
    valueLines =
      [ "    value " <> sourcedValue (Normalized.enumMemberName member)
      | member <- NonEmpty.toList (Normalized.enumDefinitionValues definition)
      ]
    orderLinesRendered =
      case Normalized.enumDefinitionOrder definition of
        Nothing -> pure ["    (no declared order)"]
        Just order ->
          (\entries -> ["    order: " <> Text.intercalate ", " entries])
            <$> traverse
              rankedEntry
              (NonEmpty.toList (Normalized.enumOrderRanking order))
    -- The materialized rank is printed as stored; the ranked value
    -- must belong to this enum, or its name would misdescribe the
    -- ranking.
    rankedEntry ranked =
      let memberRef = Normalized.rankedValueMember ranked
       in case refTarget memberRef of
            EnumValueId owner _
              | owner /= Normalized.enumDefinitionId definition ->
                  refuseAt
                    (refPath memberRef)
                    "a ranked value of a declared enum order does not belong to the order's enum"
              | otherwise ->
                  (\valueName ->
                     valueName
                       <> " = "
                       <> Text.pack (show (Normalized.rankedValueRank ranked)))
                    <$> enumValueNameAt
                      model
                      (refPath memberRef)
                      (refTarget memberRef)

relationBlock :: Normalized.Model -> Normalized.Relation -> Render [Text]
relationBlock model relation =
  (\endpointLines payloadLine ->
     ("  relation " <> sourcedValue (Normalized.relationName relation))
       : endpointLines
         <> [payloadLine])
    <$> traverse endpointLine (oneOrTwoList (Normalized.relationEndpoints relation))
    <*> payloadLineRendered
  where
    endpointLine endpoint =
      (\entityText ->
         "    endpoint "
           <> sourcedValue (Normalized.endpointName endpoint)
           <> " : "
           <> entityText)
        <$> entityNameAt
          model
          (refPath (Normalized.endpointEntity endpoint))
          (refTarget (Normalized.endpointEntity endpoint))
    payloadLineRendered =
      ("    payload: " <>)
        <$> renderValueType
          model
          (Normalized.relationPath relation)
          (payloadStaticType (Normalized.relationPayload relation))

--------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------

actionBlock :: Normalized.Model -> Normalized.Action -> Render [Text]
actionBlock model action =
  (\parameterLines bodyLines ->
     ("  action " <> sourcedValue (Normalized.actionName action))
       : parameterLines
         <> bodyLines)
    <$> parameterLinesRendered
    <*> bodyLinesRendered
  where
    envAction = Normalized.actionId action
    parameterLinesRendered =
      case Normalized.actionParameters action of
        [] -> pure ["    (no parameters)"]
        parameters -> traverse parameterLine parameters
    parameterLine parameter =
      (\typeText ->
         "    parameter "
           <> sourcedValue (Normalized.parameterName parameter)
           <> " : "
           <> typeText)
        <$> renderValueType
          model
          (Normalized.parameterPath parameter)
          (parameterStaticType (Normalized.parameterType parameter))
    bodyLinesRendered =
      case Normalized.actionBody action of
        Normalized.AuthenticatedOnlyBody allow shape ->
          (\allowLine restLines ->
             [ "    principal mode: AuthenticatedOnly"
             , classificationLine shape
             , allowLine
             ]
               <> restLines)
            <$> policySite model envAction "    allow: " allow
            <*> shapeLines model envAction shape
        Normalized.AnyPrincipalBody allowPair shape ->
          (\anonymousLine authenticatedLine restLines ->
             [ "    principal mode: AnyPrincipal"
             , classificationLine shape
             , anonymousLine
             , authenticatedLine
             ]
               <> restLines)
            <$> policySite
              model
              envAction
              "    allow (anonymous): "
              (Normalized.anyPrincipalAnonymous allowPair)
            <*> policySite
              model
              envAction
              "    allow (authenticated): "
              (Normalized.anyPrincipalAuthenticated allowPair)
            <*> shapeLines model envAction shape

-- | The classification is encoded by the normalized shape, never a
-- separate field that could disagree with it.
classificationLine :: Normalized.ActionShape availability -> Text
classificationLine shape =
  case shape of
    Normalized.ReadShape {} -> "    classification: Read"
    Normalized.CreateShape {} -> "    classification: Mutation"
    Normalized.MutationShape {} -> "    classification: Mutation"

-- | The effect and result lines of an action shape.
shapeLines
  :: Normalized.Model
  -> ActionId
  -> Normalized.ActionShape availability
  -> Render [Text]
shapeLines model envAction shape =
  case shape of
    Normalized.ReadShape _ _ observed ->
      (\entityLine ->
         ["    effect: NoChange", "    result: Observe", entityLine])
        <$> valueSite model envAction "      entity: " observed
    Normalized.CreateShape effect _ ->
      (<> ["    result: Created"]) <$> createEntityLines model envAction effect
    Normalized.MutationShape effect _ ->
      (<> ["    result: Done"]) <$> doneEffectLines model envAction effect

-- | A @CreateEntity@ effect: the target entity and one line per
-- initializer, in the normalized (target-attribute declaration)
-- order.  Every initializer key must name an attribute of the target
-- entity.
createEntityLines
  :: Normalized.Model
  -> ActionId
  -> Normalized.CreateEntityEffect availability
  -> Render [Text]
createEntityLines model envAction effect =
  entityAt model (refPath entityRef) (refTarget entityRef)
    `andThen` \targetEntity ->
      let attributeIds =
            map Normalized.attributeId (Normalized.entityAttributes targetEntity)
          initializerLine initializer =
            let keyRef = Normalized.initializerKey initializer
                term = Normalized.initializerValue initializer
             in if refTarget keyRef `elem` attributeIds
                  then
                    (\attributeName termText typeText ->
                       "      initialize "
                         <> attributeName
                         <> " = "
                         <> termText
                         <> " : "
                         <> typeText)
                      <$> attributeNameAt model (refPath keyRef) (refTarget keyRef)
                      <*> renderValue model envAction term
                      <*> renderValueType
                        model
                        (Normalized.valueTermPath term)
                        (Normalized.valueTermType term)
                  else
                    refuseAt
                      (refPath keyRef)
                      "a \"CreateEntity\" initializer key does not name an attribute of the target entity"
       in (\initializerLines ->
             ("    effect: CreateEntity["
                <> sourcedValue (Normalized.entityName targetEntity)
                <> "]")
               : initializerLines)
            <$> traverse
              initializerLine
              (Normalized.createEntityEffectInitializers effect)
  where
    entityRef = Normalized.createEntityEffectEntity effect

-- | The four @Done@-result effects.
doneEffectLines
  :: Normalized.Model
  -> ActionId
  -> Normalized.DoneEffect availability
  -> Render [Text]
doneEffectLines model envAction effect =
  case effect of
    Normalized.NoChangeEffect _ -> pure ["    effect: NoChange"]
    Normalized.DeleteEntityEffect _ target ->
      (\targetLine -> ["    effect: DeleteEntity", targetLine])
        <$> valueSite model envAction "      target: " target
    Normalized.SetRelationEffect path relationRef bindings payload ->
      (\relationName bindingLines payloadLine ->
         ("    effect: SetRelation[" <> relationName <> "]")
           : bindingLines
             <> [payloadLine])
        <$> relationNameAt model (refPath relationRef) (refTarget relationRef)
        <*> traverse
          (effectBindingLine model envAction (refTarget relationRef) path)
          (oneOrTwoList bindings)
        <*> valueSite model envAction "      payload: " payload
    Normalized.RemoveRelationEffect path relationRef bindings ->
      (\relationName bindingLines ->
         ("    effect: RemoveRelation[" <> relationName <> "]") : bindingLines)
        <$> relationNameAt model (refPath relationRef) (refTarget relationRef)
        <*> traverse
          (effectBindingLine model envAction (refTarget relationRef) path)
          (oneOrTwoList bindings)

-- | One endpoint binding of a relation effect, as a labelled line
-- with the bound term's stored type.
effectBindingLine
  :: Normalized.Model
  -> ActionId
  -> RelationId
  -> SourcePath
  -> Normalized.EndpointBinding availability
  -> Render Text
effectBindingLine model envAction boundRelation site binding =
  (\endpointName termText typeText ->
     "      endpoint "
       <> endpointName
       <> " = "
       <> termText
       <> " : "
       <> typeText)
    <$> boundEndpointName model boundRelation site binding
    <*> renderValue model envAction term
    <*> renderValueType
      model
      (Normalized.valueTermPath term)
      (Normalized.valueTermType term)
  where
    term = Normalized.endpointBindingTerm binding

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

-- Every guarantee is labelled an unverified proof obligation: the
-- contract restates the selection and proves nothing.

guaranteeBlock :: Normalized.Model -> Normalized.Guarantee -> Render [Text]
guaranteeBlock model guarantee =
  case guarantee of
    Normalized.AuthenticatedMutationGuarantee _ ->
      pure ["  guarantee AuthenticatedMutation (unverified proof obligation)"]
    Normalized.TenantIsolationGuarantee _ access cases ->
      (\headLines caseLines ->
         "  guarantee TenantIsolation (unverified proof obligation)"
           : headLines
             <> concat caseLines)
        <$> accessLines model access
        <*> traverse (tenantCaseLines model) (NonEmpty.toList cases)
    Normalized.NoSelfPrivilegeEscalationGuarantee _ authority cases ->
      (\headLines caseLines ->
         "  guarantee NoSelfPrivilegeEscalation (unverified proof obligation)"
           : headLines
             <> concat caseLines)
        <$> authorityLines model authority
        <*> traverse
          (escalationCaseLines model authority)
          (NonEmpty.toList cases)

-- | The @TenantIsolation@ structural access relation: its relation
-- and its subject and tenant endpoints, printed through their stored
-- resolved identities.  Access endpoints must belong to the access
-- relation — printing another relation's endpoint name would
-- misdescribe the access — and nothing beyond that referential
-- consistency is judged here: no name resolution, no typing, no
-- policy evaluation, and no guarantee checking.
accessLines
  :: Normalized.Model -> Normalized.TenantIsolationAccess -> Render [Text]
accessLines model access =
  (\relationName subjectName tenantName ->
     [ "    access relation: " <> relationName
     , "    access subject endpoint: " <> subjectName
     , "    access tenant endpoint: " <> tenantName
     ])
    <$> relationNameAt model (refPath relationRef) (refTarget relationRef)
    <*> accessEndpointName
      model
      access
      (Normalized.tenantIsolationAccessSubjectEndpoint access)
    <*> accessEndpointName
      model
      access
      (Normalized.tenantIsolationAccessTenantEndpoint access)
  where
    relationRef = Normalized.tenantIsolationAccessRelation access

-- | The name of an access endpoint, which must belong to the access
-- relation.
accessEndpointName
  :: Normalized.Model
  -> Normalized.TenantIsolationAccess
  -> Ref EndpointId
  -> Render Text
accessEndpointName model access endpointRef =
  case refTarget endpointRef of
    target@(EndpointId owner _)
      | owner /= refTarget (Normalized.tenantIsolationAccessRelation access) ->
          refuseAt
            (refPath endpointRef)
            "an access endpoint reference does not name an endpoint of the access relation"
      | otherwise ->
          sourcedValue . Normalized.endpointName
            <$> endpointAt model (refPath endpointRef) target

-- | One @TenantIsolation@ case: the action it selects and its
-- actor-free tenant and protected terms, each with its stored type,
-- typed in the action's environment.
tenantCaseLines :: Normalized.Model -> Normalized.TenantIsolationCase -> Render [Text]
tenantCaseLines model tenantCase =
  actionAt model (refPath actionRef) (refTarget actionRef)
    `andThen` \caseAction ->
      let envAction = Normalized.actionId caseAction
       in (\tenantLine protectedLine ->
             [ "    case for action "
                 <> sourcedValue (Normalized.actionName caseAction)
             , tenantLine
             , protectedLine
             ])
            <$> valueSite
              model
              envAction
              "      tenant: "
              (Normalized.tenantIsolationCaseTenant tenantCase)
            <*> policySite
              model
              envAction
              "      protected: "
              (Normalized.tenantIsolationCaseProtected tenantCase)
  where
    actionRef = Normalized.tenantIsolationCaseAction tenantCase

-- | The @NoSelfPrivilegeEscalation@ authority: its relation, subject
-- endpoint, optional scope endpoint, absence level, and payload-order
-- enum.  Authority endpoints must belong to the authority's relation,
-- and the payload-order enum must carry a materialized ranking — the
-- line asserts that it ranks authority levels.
authorityLines :: Normalized.Model -> Normalized.Authority -> Render [Text]
authorityLines model authority =
  (\relationName subjectName scopeLine orderName ->
     [ "    authority relation: " <> relationName
     , "    authority subject endpoint: " <> subjectName
     , scopeLine
     , "    authority absence level: " <> absenceText
     , "    authority payload order: " <> orderName
     ])
    <$> relationNameAt model (refPath relationRef) (refTarget relationRef)
    <*> authorityEndpointName model authority (Normalized.authoritySubjectEndpoint authority)
    <*> scopeLineRendered
    <*> payloadOrderName
  where
    relationRef = Normalized.authorityRelation authority
    absenceText =
      case sourcedValue (Normalized.authorityAbsenceLevel authority) of
        AbsenceBottom -> "Bottom"
    scopeLineRendered =
      case Normalized.authorityScopeEndpoint authority of
        Nothing -> pure "    authority scope endpoint: (none)"
        Just scopeRef ->
          ("    authority scope endpoint: " <>)
            <$> authorityEndpointName model authority scopeRef
    payloadOrderName =
      let orderRef = Normalized.authorityPayloadOrder authority
       in enumAt model (refPath orderRef) (refTarget orderRef)
            `andThen` \definition ->
              case Normalized.enumDefinitionOrder definition of
                Just _ ->
                  pure (sourcedValue (Normalized.enumDefinitionName definition))
                Nothing ->
                  refuseAt
                    (refPath orderRef)
                    "the authority's payload order names an enum without a materialized ranking"

-- | The name of an authority endpoint, which must belong to the
-- authority's relation.
authorityEndpointName
  :: Normalized.Model
  -> Normalized.Authority
  -> Ref EndpointId
  -> Render Text
authorityEndpointName model authority endpointRef =
  case refTarget endpointRef of
    target@(EndpointId owner _)
      | owner /= refTarget (Normalized.authorityRelation authority) ->
          refuseAt
            (refPath endpointRef)
            "an authority endpoint reference does not name an endpoint of the authority's relation"
      | otherwise ->
          sourcedValue . Normalized.endpointName
            <$> endpointAt model (refPath endpointRef) target

-- | One @NoSelfPrivilegeEscalation@ case: the action it selects and
-- its scope binding, which must correspond one-to-one with the
-- authority's scope endpoint.
escalationCaseLines
  :: Normalized.Model
  -> Normalized.Authority
  -> Normalized.EscalationCase
  -> Render [Text]
escalationCaseLines model authority escalationCase =
  actionAt model (refPath actionRef) (refTarget actionRef)
    `andThen` \caseAction ->
      let envAction = Normalized.actionId caseAction
       in (\scopeLine ->
             [ "    case for action "
                 <> sourcedValue (Normalized.actionName caseAction)
             , scopeLine
             ])
            <$> scopeLineRendered envAction
  where
    actionRef = Normalized.escalationCaseAction escalationCase
    casePath = Normalized.escalationCasePath escalationCase
    scopeLineRendered envAction =
      case ( Normalized.authorityScopeEndpoint authority
           , Normalized.escalationCaseScope escalationCase
           ) of
        (Nothing, Nothing) -> pure "      scope: (none)"
        (Just scopeRef, Just binding)
          | Normalized.scopeBindingEndpoint binding /= refTarget scopeRef ->
              refuseAt
                casePath
                "a case scope binding does not name the authority's scope endpoint"
          | otherwise ->
              let term = Normalized.scopeBindingTerm binding
               in (\endpointName termText typeText ->
                     "      scope "
                       <> endpointName
                       <> " = "
                       <> termText
                       <> " : "
                       <> typeText)
                    <$> ( sourcedValue . Normalized.endpointName
                            <$> endpointAt
                              model
                              casePath
                              (Normalized.scopeBindingEndpoint binding)
                        )
                    <*> renderValue model envAction term
                    <*> renderValueType
                      model
                      (Normalized.valueTermPath term)
                      (Normalized.valueTermType term)
        (Nothing, Just _) ->
          refuseAt
            casePath
            "this case binds a scope term, but the authority declares no scope endpoint"
        (Just _, Nothing) ->
          refuseAt
            casePath
            "this case binds no scope term, but the authority declares a scope endpoint"
