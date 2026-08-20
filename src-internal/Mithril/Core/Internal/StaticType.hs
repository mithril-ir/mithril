-- | __Internal module — never expose.__
--
-- The Core v0 static type language: the vocabulary in which the
-- static typechecker ("Mithril.Core.Internal.Typecheck") states its
-- judgment over the resolved representation, and in which the
-- normalized representation ("Mithril.Core.Internal.Normalized")
-- carries the determined type of every normalized term.  It lives in
-- the package-private sublibrary so that both users — the typechecker
-- in the public library and the normalized model here — share one
-- definition, and so the package's own white-box tests can state
-- expected types literally; external code cannot import it.
--
-- Besides the type language itself, this module is the one home of
-- the projections from the declared type families of the resolved
-- representation into that language — 'attributeStaticType',
-- 'parameterStaticType', and 'payloadStaticType' — and of the ordered
-- reading of a comparison operand type ('OrderedType',
-- 'orderedPolicyType').  The typechecker's judgment and the
-- normalized representation both consume exactly these definitions;
-- neither restates a case of them.  Whether an ordered-shaped enum
-- actually declares an order is a fact about the model, not about the
-- type, so that half of the @LessOrEqual@ judgment lives with the
-- typechecker's signature queries
-- ('Mithril.Core.Internal.Typecheck.orderedVerdict'), which consume
-- 'orderedPolicyType' rather than re-classifying.
--
-- Types reference declarations by their resolved namespace-specific
-- identifiers ("Mithril.Core.Internal.Resolved"), never by name: a
-- @'EnumType'@ or @'EntityRefType'@ names its declaration positionally,
-- so two types are equal exactly when they denote the same declared
-- enum or entity of one model.  A value of these types states a static
-- type only — it is not evaluation, not normalization by itself, and
-- not a semantic or security property.
module Mithril.Core.Internal.StaticType
  ( -- * The type language
    ValueType (..)
  , PolicyType (..)

    -- * The declared-type projections
  , attributeStaticType
  , parameterStaticType
  , payloadStaticType

    -- * Ordered comparison operands
  , OrderedType (..)
  , orderedTypeEnum
  , orderedPolicyType
  ) where

import Mithril.Core.Internal.Resolved
  ( AttributeType (..)
  , EntityId
  , EnumId
  , ParameterType (..)
  , PayloadType (..)
  , Ref (refTarget)
  )

-- | The Core v0 value types: the types of value terms and of
-- attribute, parameter, and payload declarations — @Bool@, @Unit@,
-- @Enum E@, and @EntityRef E@.
data ValueType
  = BoolType
  | UnitType
  | EnumType EnumId
  | EntityRefType EntityId
  deriving (Eq, Ord, Show)

-- | The Core v0 policy types: every value type plus the optional
-- types that model relation-payload presence.  Optionals nest exactly
-- one level by construction — @Some@ lifts a value term, so no
-- optional ever wraps an optional.
data PolicyType
  = ValuePolicyType ValueType
  | OptionalPolicyType ValueType
  deriving (Eq, Ord, Show)

-- | The static type a declared attribute type denotes.  This is the
-- one statement of the projection: the typechecker types attribute
-- projections and @CreateEntity@ initializers with it, and backends
-- reading the normalized model consume it (re-exported there) instead
-- of reinterpreting the declared family themselves.
attributeStaticType :: AttributeType -> ValueType
attributeStaticType declared =
  case declared of
    BoolAttributeType _ -> BoolType
    EnumAttributeType _ ref -> EnumType (refTarget ref)
    EntityRefAttributeType _ ref -> EntityRefType (refTarget ref)

-- | The static type a declared parameter type denotes; see
-- 'attributeStaticType'.
parameterStaticType :: ParameterType -> ValueType
parameterStaticType declared =
  case declared of
    BoolParameterType _ -> BoolType
    UnitParameterType _ -> UnitType
    EnumParameterType _ ref -> EnumType (refTarget ref)
    EntityRefParameterType _ ref -> EntityRefType (refTarget ref)

-- | The static type a declared relation payload type denotes; see
-- 'attributeStaticType'.
payloadStaticType :: PayloadType -> ValueType
payloadStaticType declared =
  case declared of
    UnitPayloadType _ -> UnitType
    EnumPayloadType _ ref -> EnumType (refTarget ref)

-- | The ordered reading of a @LessOrEqual@: which enum's declared
-- order ranks the operands, and whether the comparison happens at the
-- optional level, where absence ranks as bottom.  In the normalized
-- representation the named enum always carries a materialized
-- ranking, so the ordering a backend must apply is explicit and
-- cannot be re-derived incorrectly.
data OrderedType
  = -- | Both operands have type @Enum E@.
    EnumOrderedType EnumId
  | -- | Both operands have type @Optional (Enum E)@; absence is
    -- below every ranked value.
    OptionalEnumOrderedType EnumId
  deriving (Eq, Ord, Show)

-- | The enum whose declared order an ordered reading ranks by.
orderedTypeEnum :: OrderedType -> EnumId
orderedTypeEnum orderedType =
  case orderedType of
    EnumOrderedType enumTarget -> enumTarget
    OptionalEnumOrderedType enumTarget -> enumTarget

-- | The ordered reading a policy type admits by its shape, if any:
-- exactly the enum and optional-enum types.  This is the one
-- statement of the shape half of the @LessOrEqual@ operand judgment;
-- whether the named enum declares an order is a model fact the caller
-- must still establish
-- ('Mithril.Core.Internal.Typecheck.orderedVerdict' does both).
orderedPolicyType :: PolicyType -> Maybe OrderedType
orderedPolicyType policyType =
  case policyType of
    ValuePolicyType (EnumType enumTarget) ->
      Just (EnumOrderedType enumTarget)
    OptionalPolicyType (EnumType enumTarget) ->
      Just (OptionalEnumOrderedType enumTarget)
    _ -> Nothing
