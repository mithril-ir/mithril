{-# LANGUAGE OverloadedStrings #-}

-- | The second deterministic frontend boundary for Mithril Core v0:
-- complete name resolution.
--
-- > structurally-valid opaque document
-- >   -> complete name resolution          ('resolveCoreDocument')
-- >   -> resolved opaque document
--
-- 'resolveCoreDocument' consumes the structurally valid document
-- produced by "Mithril.Core.Validation" and checks every Core v0 name
-- site.  It establishes exactly two kinds of fact:
--
-- 1. /Declaration-name uniqueness/, independently per namespace: the
--    four global namespaces (entities, enums, relations, actions) and
--    the owner-local namespaces (attributes within one entity,
--    endpoints within one relation, parameters within one action).
--    The same text may name declarations in different namespaces or
--    under different owners.
--
-- 2. /Reference resolution/: every name reference resolves to an
--    existing declaration in its correct namespace — enum and entity
--    references in declared types, relation endpoint entities,
--    relation payload enums, enum-order members against the enum's
--    own values, every term constructor (@Enum@, @Argument@,
--    @Attribute@, @Lookup@, @None@ payload enums, and all nested
--    terms), effect targets and @CreateEntity@ initializer keys,
--    result terms, and every guarantee reference (case actions and
--    their action-scoped terms, and the @NoSelfPrivilegeEscalation@
--    authority relation, endpoints, and payload-order enum).
--
-- The only typing-like work in this stage is the narrow declared-type
-- lookup needed to select the entity-local namespace of an
-- @Attribute@ projection: @Actor@ denotes the distinguished @User@
-- entity, an @Argument@ denotes an entity when its declared parameter
-- type is @EntityRef@, and a nested @Attribute@ denotes an entity
-- when its resolved attribute declaration has @EntityRef@ type.  A
-- source that is known /not/ to denote an entity reference is a
-- resolution failure; nothing else about types is checked.
--
-- Everything else remains for the (unimplemented) static typechecker
-- and later stages: general term typing, operator operand
-- compatibility, equality and ordered-comparison compatibility,
-- enum-order completeness and permutation validity, whether a
-- @payloadOrder@ enum is ordered or agrees with the authority
-- relation, relation endpoint arity and endpoint type compatibility
-- at lookup and effect sites, effect value typing, @CreateEntity@
-- initializer completeness and value typing, result typing, guarantee
-- well-typedness and truth, policy evaluation, and normalization.  A
-- structurally valid document can therefore resolve successfully and
-- still fail the future typechecker.  A @'CoreDocument' 'Resolved'@
-- is an attestation about names only — /not/ typed normalized Core,
-- and no semantic or security property.
--
-- == Failure classification
--
-- Name problems in the user's document are 'ResolutionViolation's,
-- reported with raw path segments (render with
-- 'Mithril.Core.Validation.renderJsonPointer'), aggregated across
-- independent sites, deduplicated, and deterministically ordered.  A
-- dependent site whose prerequisite name is unknown or ambiguous is
-- suppressed rather than reported, so one root problem does not
-- cascade.
--
-- Shapes that structural validation cannot produce indicate
-- schema\/resolver drift or a resolver bug, never a user error.  They
-- are 'ResolverInvariantViolation's, kept separate from semantic
-- violations, and they dominate: if any invariant violation is
-- observed, the resolver no longer trusts its interpretation of the
-- document and reports 'ResolverInvariantViolations' even when
-- ordinary name problems were also seen.  The resolver never throws
-- for either failure kind.
module Mithril.Core.Resolution
  ( -- * Pipeline stage
    Resolved

    -- * Failures and violations
  , ResolutionFailure (..)
  , ResolutionViolation (..)
  , ResolverInvariantViolation (..)

    -- * Name resolution
  , resolveCoreDocument

    -- * Violation normalization
  , normalizeResolutionViolations
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text

import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Resolved
  , StructurallyValid
  )
import Mithril.Core.Validation (renderJsonPointer)

-- | One name-resolution violation in the user's document: a duplicate
-- declaration name or an unresolvable name reference.
data ResolutionViolation = ResolutionViolation
  { resolutionViolationPath :: [Text]
    -- ^ Instance path of the failing name site, as raw (unescaped)
    -- segments; render with 'renderJsonPointer'.
  , resolutionViolationMessage :: Text
    -- ^ Description of the violation, with every referenced name
    -- quoted.
  }
  deriving (Eq, Ord, Show)

-- | One resolver-invariant violation: a shape the resolver cannot
-- interpret even though the document passed structural validation.
-- This is evidence of schema\/resolver drift or a resolver bug — an
-- internal error of the @mithril@ tool, never a problem with the
-- user's document.
data ResolverInvariantViolation = ResolverInvariantViolation
  { resolverInvariantPath :: [Text]
    -- ^ Instance path of the uninterpretable shape, as raw segments;
    -- render with 'renderJsonPointer'.
  , resolverInvariantMessage :: Text
    -- ^ Description of the expectation that failed.
  }
  deriving (Eq, Ord, Show)

-- | Why 'resolveCoreDocument' refused the stage transition.
data ResolutionFailure
  = -- | The document has name problems.  The violations are sorted
    -- and deduplicated ('normalizeResolutionViolations').
    ResolutionViolations (NonEmpty ResolutionViolation)
  | -- | The resolver hit shapes it cannot interpret.  This
    -- classification dominates: it is reported even if ordinary name
    -- problems were also observed, because the resolver can no longer
    -- trust its interpretation of the document.  The violations are
    -- sorted and deduplicated.
    ResolverInvariantViolations (NonEmpty ResolverInvariantViolation)
  deriving (Eq, Show)

-- | Resolve every Core v0 name site of a structurally valid document.
--
-- Pure and deterministic: the same document always produces the same
-- result, with violations aggregated across independent sites, sorted,
-- and deduplicated.  On success the document — its JSON value
-- unchanged — is attested as 'Resolved'; this function is the only
-- public producer of a @'CoreDocument' 'Resolved'@.
resolveCoreDocument
  :: CoreDocument StructurallyValid
  -> Either ResolutionFailure (CoreDocument Resolved)
resolveCoreDocument (CoreDocument documentValue) =
  case NonEmpty.nonEmpty (normalizeInvariantViolations invariants) of
    Just someInvariants -> Left (ResolverInvariantViolations someInvariants)
    Nothing ->
      case NonEmpty.nonEmpty (normalizeResolutionViolations violations) of
        Just someViolations -> Left (ResolutionViolations someViolations)
        Nothing -> Right (CoreDocument documentValue)
  where
    (violations, invariants) = resolveDocumentValue documentValue

-- | Deterministically sort resolution violations (by path, then
-- message) and remove duplicates.  This is the exact normalization
-- applied by 'resolveCoreDocument' before violations are returned.
normalizeResolutionViolations :: [ResolutionViolation] -> [ResolutionViolation]
normalizeResolutionViolations = map NonEmpty.head . NonEmpty.group . sort

-- | The same normalization for invariant violations.
normalizeInvariantViolations
  :: [ResolverInvariantViolation] -> [ResolverInvariantViolation]
normalizeInvariantViolations = map NonEmpty.head . NonEmpty.group . sort

--------------------------------------------------------------------
-- Internal: report accumulation
--------------------------------------------------------------------

-- | Accumulated reports of one walk: semantic violations and
-- invariant violations, in traversal order (normalized at the end).
type Reports = ([ResolutionViolation], [ResolverInvariantViolation])

-- | One semantic violation as a report.
violationAt :: [Text] -> Text -> Reports
violationAt path message = ([ResolutionViolation path message], [])

-- | One invariant violation as a report.
invariantAt :: [Text] -> Text -> Reports
invariantAt path message = ([], [ResolverInvariantViolation path message])

-- | Quote a document-supplied name for a diagnostic.  'show' on
-- 'Text' renders a double-quoted string literal with any unusual
-- character escaped, so no name can smuggle line breaks or terminal
-- controls into a message.
quoted :: Text -> Text
quoted = Text.pack . show

-- | Array index as a raw path segment.
showIndex :: Int -> Text
showIndex = Text.pack . show

--------------------------------------------------------------------
-- Internal: total shape access (failures are invariant violations)
--------------------------------------------------------------------

-- | The JSON type of a value, for invariant messages.
jsonTypeName :: Value -> Text
jsonTypeName value =
  case value of
    Object _ -> "an object"
    Array _ -> "an array"
    String _ -> "a string"
    Number _ -> "a number"
    Bool _ -> "a boolean"
    Null -> "null"

requireObject :: [Text] -> Value -> Either Reports (KeyMap.KeyMap Value)
requireObject path value =
  case value of
    Object members -> Right members
    _ ->
      Left
        ( invariantAt
            path
            ("expected a JSON object, found " <> jsonTypeName value)
        )

requireArray :: [Text] -> Value -> Either Reports [(Int, Value)]
requireArray path value =
  case value of
    Array items -> Right (zip [0 ..] (foldr (:) [] items))
    _ ->
      Left
        ( invariantAt
            path
            ("expected a JSON array, found " <> jsonTypeName value)
        )

requireText :: [Text] -> Value -> Either Reports Text
requireText path value =
  case value of
    String text -> Right text
    _ ->
      Left
        ( invariantAt
            path
            ("expected a JSON string, found " <> jsonTypeName value)
        )

requireMember
  :: [Text] -> KeyMap.KeyMap Value -> Text -> Either Reports Value
requireMember path members name =
  case KeyMap.lookup (Key.fromText name) members of
    Just value -> Right value
    Nothing ->
      Left
        ( invariantAt
            (path <> [name])
            ("required member " <> quoted name <> " is missing")
        )

-- | A required member that must be a string.
textMember :: [Text] -> KeyMap.KeyMap Value -> Text -> Either Reports Text
textMember path members name =
  requireMember path members name >>= requireText (path <> [name])

-- | Continue with an object, or report the shape invariant.
withObject_ :: [Text] -> Value -> (KeyMap.KeyMap Value -> Reports) -> Reports
withObject_ path value continue = either id continue (requireObject path value)

-- | Continue with a required member, or report the shape invariant.
withMember_
  :: [Text] -> KeyMap.KeyMap Value -> Text -> (Value -> Reports) -> Reports
withMember_ path members name continue =
  either id continue (requireMember path members name)

-- | Continue with a required string member, or report the invariant.
withTextMember
  :: [Text] -> KeyMap.KeyMap Value -> Text -> (Text -> Reports) -> Reports
withTextMember path members name continue =
  either id continue (textMember path members name)

-- | Continue with a required array member (items indexed), or report
-- the invariant.
withArrayMember
  :: [Text]
  -> KeyMap.KeyMap Value
  -> Text
  -> ([(Int, Value)] -> Reports)
  -> Reports
withArrayMember path members name continue =
  withMember_ path members name $ \value ->
    either id continue (requireArray (path <> [name]) value)

--------------------------------------------------------------------
-- Internal: namespaces
--------------------------------------------------------------------

-- | One deterministic namespace: the first declaration per name plus
-- the set of names declared more than once.
data Namespace a = Namespace
  { namespaceEntries :: Map Text a
  , namespaceAmbiguous :: Set Text
  }

emptyNamespace :: Namespace a
emptyNamespace = Namespace Map.empty Set.empty

-- | The three possible outcomes of a name lookup.  'NameAmbiguous'
-- means the name is declared more than once: the duplicate is already
-- reported at its declaration site, so dependent checks are
-- suppressed rather than resolved against an arbitrary pick.
data NameLookup a = NameMissing | NameAmbiguous | NameFound a

lookupName :: Namespace a -> Text -> NameLookup a
lookupName namespace name
  | Set.member name (namespaceAmbiguous namespace) = NameAmbiguous
  | otherwise =
      maybe NameMissing NameFound (Map.lookup name (namespaceEntries namespace))

-- | Build a namespace from declarations in document order.  The first
-- declaration of a name wins deterministically; every later
-- declaration of the same name is reported at its own name field,
-- with a message identifying the first declaration.
buildNamespace
  :: (Text -> Text -> Text)
  -- ^ Duplicate message: the name and the rendered pointer of the
  -- first declaration's name field.
  -> [(Text, [Text], a)]
  -- ^ (name, path of the name field, payload) in declaration order.
  -> (Reports, Namespace a)
buildNamespace duplicateMessage = go mempty Map.empty emptyNamespace
  where
    go reports firsts namespace entries =
      case entries of
        [] -> (reports, namespace)
        (name, namePath, payload) : rest ->
          case Map.lookup name firsts of
            Nothing ->
              go
                reports
                (Map.insert name namePath firsts)
                namespace
                  { namespaceEntries =
                      Map.insert name payload (namespaceEntries namespace)
                  }
                rest
            Just firstPath ->
              go
                ( reports
                    <> violationAt
                      namePath
                      (duplicateMessage name (renderJsonPointer firstPath))
                )
                firsts
                namespace
                  { namespaceAmbiguous =
                      Set.insert name (namespaceAmbiguous namespace)
                  }
                rest

--------------------------------------------------------------------
-- Internal: declaration indexes
--------------------------------------------------------------------

-- | A declared Core v0 type, as far as name resolution needs it.
data DeclaredType
  = DeclaredBool
  | DeclaredUnit
  | DeclaredEnum Text
  | DeclaredEntityRef Text

-- | An entity declaration: its attribute namespace.  A 'Nothing'
-- payload marks an attribute whose type could not be interpreted (an
-- invariant violation was reported for it).
newtype EntityInfo = EntityInfo
  { entityAttributes :: Namespace (Maybe DeclaredType)
  }

-- | An enum declaration: its value namespace.  Value uniqueness is
-- already structural (@uniqueItems@), so no duplicate tracking is
-- needed here.
newtype EnumInfo = EnumInfo
  { enumValues :: Set Text
  }

-- | A relation declaration: its endpoint namespace.
newtype RelationInfo = RelationInfo
  { relationEndpoints :: Namespace ()
  }

-- | An action declaration: its name (for diagnostics) and parameter
-- namespace.
data ActionInfo = ActionInfo
  { actionName :: Text
  , actionParameters :: Namespace (Maybe DeclaredType)
  }

-- | The four global namespaces of a Core v0 document.
data Indexes = Indexes
  { entityIndex :: Namespace EntityInfo
  , enumIndex :: Namespace EnumInfo
  , relationIndex :: Namespace RelationInfo
  , actionIndex :: Namespace ActionInfo
  }

-- | Parse a declared type's shape.  Reference existence is checked
-- separately by 'walkDeclaredType'; this only interprets the
-- constructor, reporting an invariant violation (and 'Nothing') for
-- shapes structural validation cannot produce.
parseDeclaredType :: [Text] -> Value -> (Reports, Maybe DeclaredType)
parseDeclaredType path value =
  case requireObject path value of
    Left broken -> (broken, Nothing)
    Right members ->
      case textMember path members "kind" of
        Left broken -> (broken, Nothing)
        Right kind ->
          case kind of
            "Bool" -> (mempty, Just DeclaredBool)
            "Unit" -> (mempty, Just DeclaredUnit)
            "Enum" ->
              case textMember path members "enum" of
                Left broken -> (broken, Nothing)
                Right enumName -> (mempty, Just (DeclaredEnum enumName))
            "EntityRef" ->
              case textMember path members "entity" of
                Left broken -> (broken, Nothing)
                Right entityName -> (mempty, Just (DeclaredEntityRef entityName))
            _ ->
              ( invariantAt
                  (path <> ["kind"])
                  ("unexpected type constructor " <> quoted kind)
              , Nothing
              )

-- | Walk a type position: interpret its shape and check its enum or
-- entity reference, reporting an unknown reference at the @enum@ or
-- @entity@ member.
walkDeclaredType :: Indexes -> [Text] -> Value -> Reports
walkDeclaredType indexes path value =
  shapeReports <> referenceReports
  where
    (shapeReports, declaredType) = parseDeclaredType path value
    referenceReports =
      case declaredType of
        Just (DeclaredEnum enumName) ->
          checkEnumReference indexes (path <> ["enum"]) enumName
        Just (DeclaredEntityRef entityName) ->
          checkEntityReference indexes (path <> ["entity"]) entityName
        _ -> mempty

-- | Report an unknown enum reference.  An ambiguous (duplicated) name
-- is already reported at its declaration sites and produces nothing
-- here.
checkEnumReference :: Indexes -> [Text] -> Text -> Reports
checkEnumReference indexes path name =
  case lookupName (enumIndex indexes) name of
    NameMissing -> violationAt path ("unknown enum " <> quoted name)
    _ -> mempty

-- | Report an unknown entity reference; see 'checkEnumReference'.
checkEntityReference :: Indexes -> [Text] -> Text -> Reports
checkEntityReference indexes path name =
  case lookupName (entityIndex indexes) name of
    NameMissing -> violationAt path ("unknown entity " <> quoted name)
    _ -> mempty

-- | Report an unknown relation reference; see 'checkEnumReference'.
checkRelationReference :: Indexes -> [Text] -> Text -> Reports
checkRelationReference indexes path name =
  case lookupName (relationIndex indexes) name of
    NameMissing -> violationAt path ("unknown relation " <> quoted name)
    _ -> mempty

--------------------------------------------------------------------
-- Internal: building the indexes (pass 1)
--------------------------------------------------------------------

-- | Build the entity namespace, reporting duplicate entity names,
-- duplicate attribute names within each entity, and shape invariants.
buildEntities :: [(Int, Value)] -> (Reports, Namespace EntityInfo)
buildEntities items =
  let outcomes = map parseEntity items
      itemReports = mconcat (map fst outcomes)
      entries = [entry | (_, Just entry) <- outcomes]
      (duplicateReports, namespace) =
        buildNamespace
          ( \name firstPointer ->
              "duplicate entity name "
                <> quoted name
                <> " (first declared at "
                <> firstPointer
                <> ")"
          )
          entries
   in (itemReports <> duplicateReports, namespace)

parseEntity :: (Int, Value) -> (Reports, Maybe (Text, [Text], EntityInfo))
parseEntity (index, value) =
  case requireObject path value of
    Left broken -> (broken, Nothing)
    Right members ->
      case textMember path members "name" of
        Left broken -> (broken, Nothing)
        Right name ->
          let (attributeReports, attributeNamespace) =
                case requireMember path members "attributes"
                  >>= requireArray (path <> ["attributes"]) of
                  Left broken -> (broken, emptyNamespace)
                  Right attributeItems ->
                    buildAttributes path name attributeItems
           in ( attributeReports
              , Just (name, path <> ["name"], EntityInfo attributeNamespace)
              )
  where
    path = ["schema", "entities", showIndex index]

buildAttributes
  :: [Text] -> Text -> [(Int, Value)] -> (Reports, Namespace (Maybe DeclaredType))
buildAttributes ownerPath ownerName items =
  let outcomes = map parseAttribute items
      itemReports = mconcat (map fst outcomes)
      entries = [entry | (_, Just entry) <- outcomes]
      (duplicateReports, namespace) =
        buildNamespace
          ( \name firstPointer ->
              "duplicate attribute name "
                <> quoted name
                <> " in entity "
                <> quoted ownerName
                <> " (first declared at "
                <> firstPointer
                <> ")"
          )
          entries
   in (itemReports <> duplicateReports, namespace)
  where
    parseAttribute (index, value) =
      let path = ownerPath <> ["attributes", showIndex index]
       in case requireObject path value of
            Left broken -> (broken, Nothing)
            Right members ->
              case textMember path members "name" of
                Left broken -> (broken, Nothing)
                Right name ->
                  let (typeReports, declaredType) =
                        case requireMember path members "type" of
                          Left broken -> (broken, Nothing)
                          Right typeValue ->
                            parseDeclaredType (path <> ["type"]) typeValue
                   in (typeReports, Just (name, path <> ["name"], declaredType))

-- | Build the enum namespace, reporting duplicate enum names, shape
-- invariants, and unknown members of each enum's optional @order@
-- against that enum's own values.  Only member existence is checked:
-- whether an order is a complete permutation of the values remains a
-- static-typing check.
buildEnums :: [(Int, Value)] -> (Reports, Namespace EnumInfo)
buildEnums items =
  let outcomes = map parseEnum items
      itemReports = mconcat (map fst outcomes)
      entries = [entry | (_, Just entry) <- outcomes]
      (duplicateReports, namespace) =
        buildNamespace
          ( \name firstPointer ->
              "duplicate enum name "
                <> quoted name
                <> " (first declared at "
                <> firstPointer
                <> ")"
          )
          entries
   in (itemReports <> duplicateReports, namespace)

parseEnum :: (Int, Value) -> (Reports, Maybe (Text, [Text], EnumInfo))
parseEnum (index, value) =
  case requireObject path value of
    Left broken -> (broken, Nothing)
    Right members ->
      case textMember path members "name" of
        Left broken -> (broken, Nothing)
        Right name ->
          let (valueReports, values) =
                case requireMember path members "values"
                  >>= requireArray (path <> ["values"]) of
                  Left broken -> (broken, Set.empty)
                  Right valueItems -> collectEnumValues valueItems
              orderReports =
                case KeyMap.lookup "order" members of
                  Nothing -> mempty
                  Just orderValue ->
                    checkEnumOrder name values orderValue
           in ( valueReports <> orderReports
              , Just (name, path <> ["name"], EnumInfo values)
              )
  where
    path = ["schema", "enums", showIndex index]
    collectEnumValues valueItems =
      mconcat
        [ case requireText (path <> ["values", showIndex valueIndex]) item of
            Left broken -> (broken, Set.empty)
            Right valueName -> (mempty, Set.singleton valueName)
        | (valueIndex, item) <- valueItems
        ]
    checkEnumOrder name values orderValue =
      case requireArray (path <> ["order"]) orderValue of
        Left broken -> broken
        Right orderItems ->
          mconcat
            [ case requireText itemPath item of
                Left broken -> broken
                Right memberName
                  | Set.member memberName values -> mempty
                  | otherwise ->
                      violationAt
                        itemPath
                        ( "unknown value "
                            <> quoted memberName
                            <> " in enum "
                            <> quoted name
                        )
            | (orderIndex, item) <- orderItems
            , let itemPath = path <> ["order", showIndex orderIndex]
            ]

-- | Build the relation namespace, reporting duplicate relation names,
-- duplicate endpoint names within each relation, and shape
-- invariants.  Endpoint entity references and payload enums are
-- checked by 'checkSchemaDeclarations'.
buildRelations :: [(Int, Value)] -> (Reports, Namespace RelationInfo)
buildRelations items =
  let outcomes = map parseRelation items
      itemReports = mconcat (map fst outcomes)
      entries = [entry | (_, Just entry) <- outcomes]
      (duplicateReports, namespace) =
        buildNamespace
          ( \name firstPointer ->
              "duplicate relation name "
                <> quoted name
                <> " (first declared at "
                <> firstPointer
                <> ")"
          )
          entries
   in (itemReports <> duplicateReports, namespace)

parseRelation :: (Int, Value) -> (Reports, Maybe (Text, [Text], RelationInfo))
parseRelation (index, value) =
  case requireObject path value of
    Left broken -> (broken, Nothing)
    Right members ->
      case textMember path members "name" of
        Left broken -> (broken, Nothing)
        Right name ->
          let (endpointReports, endpointNamespace) =
                case requireMember path members "endpoints"
                  >>= requireArray (path <> ["endpoints"]) of
                  Left broken -> (broken, emptyNamespace)
                  Right endpointItems ->
                    buildEndpoints path name endpointItems
           in ( endpointReports
              , Just (name, path <> ["name"], RelationInfo endpointNamespace)
              )
  where
    path = ["schema", "relations", showIndex index]

buildEndpoints :: [Text] -> Text -> [(Int, Value)] -> (Reports, Namespace ())
buildEndpoints ownerPath ownerName items =
  let outcomes = map parseEndpoint items
      itemReports = mconcat (map fst outcomes)
      entries = [entry | (_, Just entry) <- outcomes]
      (duplicateReports, namespace) =
        buildNamespace
          ( \name firstPointer ->
              "duplicate endpoint name "
                <> quoted name
                <> " in relation "
                <> quoted ownerName
                <> " (first declared at "
                <> firstPointer
                <> ")"
          )
          entries
   in (itemReports <> duplicateReports, namespace)
  where
    parseEndpoint (index, value) =
      let path = ownerPath <> ["endpoints", showIndex index]
       in case requireObject path value of
            Left broken -> (broken, Nothing)
            Right members ->
              case textMember path members "name" of
                Left broken -> (broken, Nothing)
                Right name -> (mempty, Just (name, path <> ["name"], ()))

-- | Build the action namespace and the positional action list for the
-- body walk, reporting duplicate action names, duplicate parameter
-- names within each action, and shape invariants.  Parameter type
-- references are checked positionally by 'walkAction'.
buildActions
  :: [(Int, Value)]
  -> (Reports, Namespace ActionInfo, [(Int, Value, Maybe ActionInfo)])
buildActions items =
  let outcomes = map parseAction items
      itemReports = mconcat [reports | (reports, _, _) <- outcomes]
      entries = [entry | (_, Just entry, _) <- outcomes]
      positional = [position | (_, _, position) <- outcomes]
      (duplicateReports, namespace) =
        buildNamespace
          ( \name firstPointer ->
              "duplicate action name "
                <> quoted name
                <> " (first declared at "
                <> firstPointer
                <> ")"
          )
          entries
   in (itemReports <> duplicateReports, namespace, positional)
  where
    parseAction (index, value) =
      let path = ["actions", showIndex index]
       in case requireObject path value of
            Left broken -> (broken, Nothing, (index, value, Nothing))
            Right members ->
              case textMember path members "name" of
                Left broken -> (broken, Nothing, (index, value, Nothing))
                Right name ->
                  let (parameterReports, parameterNamespace) =
                        case requireMember path members "parameters"
                          >>= requireArray (path <> ["parameters"]) of
                          Left broken -> (broken, emptyNamespace)
                          Right parameterItems ->
                            buildParameters path name parameterItems
                      info = ActionInfo name parameterNamespace
                   in ( parameterReports
                      , Just (name, path <> ["name"], info)
                      , (index, value, Just info)
                      )

buildParameters
  :: [Text] -> Text -> [(Int, Value)] -> (Reports, Namespace (Maybe DeclaredType))
buildParameters ownerPath ownerName items =
  let outcomes = map parseParameter items
      itemReports = mconcat (map fst outcomes)
      entries = [entry | (_, Just entry) <- outcomes]
      (duplicateReports, namespace) =
        buildNamespace
          ( \name firstPointer ->
              "duplicate parameter name "
                <> quoted name
                <> " in action "
                <> quoted ownerName
                <> " (first declared at "
                <> firstPointer
                <> ")"
          )
          entries
   in (itemReports <> duplicateReports, namespace)
  where
    parseParameter (index, value) =
      let path = ownerPath <> ["parameters", showIndex index]
       in case requireObject path value of
            Left broken -> (broken, Nothing)
            Right members ->
              case textMember path members "name" of
                Left broken -> (broken, Nothing)
                Right name ->
                  let (typeReports, declaredType) =
                        case requireMember path members "type" of
                          Left broken -> (broken, Nothing)
                          Right typeValue ->
                            parseDeclaredType (path <> ["type"]) typeValue
                   in (typeReports, Just (name, path <> ["name"], declaredType))

--------------------------------------------------------------------
-- Internal: schema declaration references (pass 2)
--------------------------------------------------------------------

-- | Check every reference inside the schema declarations against the
-- complete indexes: attribute types, endpoint entities, and payload
-- enums.  Runs positionally, so every occurrence of a duplicated
-- declaration is checked against its own body.
checkSchemaDeclarations :: Indexes -> Value -> Reports
checkSchemaDeclarations indexes schemaValue =
  withObject_ ["schema"] schemaValue $ \schemaMembers ->
    withArrayMember ["schema"] schemaMembers "entities" (mconcat . map entityReferences)
      <> withArrayMember
        ["schema"]
        schemaMembers
        "relations"
        (mconcat . map relationReferences)
  where
    entityReferences (index, value) =
      let path = ["schema", "entities", showIndex index]
       in withObject_ path value $ \members ->
            withArrayMember path members "attributes" $ \attributeItems ->
              mconcat
                [ withObject_ attributePath attributeValue $ \attributeMembers ->
                    withMember_ attributePath attributeMembers "type" $
                      walkDeclaredType indexes (attributePath <> ["type"])
                | (attributeIndex, attributeValue) <- attributeItems
                , let attributePath =
                        path <> ["attributes", showIndex attributeIndex]
                ]
    relationReferences (index, value) =
      let path = ["schema", "relations", showIndex index]
       in withObject_ path value $ \members ->
            withArrayMember path members "endpoints" (mconcat . map (endpointReferences path))
              <> withMember_ path members "payload" (walkDeclaredType indexes (path <> ["payload"]))
    endpointReferences relationPath (index, value) =
      let path = relationPath <> ["endpoints", showIndex index]
       in withObject_ path value $ \members ->
            withTextMember path members "entity" $
              checkEntityReference indexes (path <> ["entity"])

--------------------------------------------------------------------
-- Internal: terms
--------------------------------------------------------------------

-- | The context a term is resolved in: the global indexes plus the
-- action-local parameter environment.  'Nothing' parameters mean the
-- environment could not be determined (the enclosing guarantee case
-- names an unknown or duplicated action, or the action's shape was
-- uninterpretable): @Argument@ checks are suppressed rather than
-- guessed, while every environment-independent check still runs.
data TermContext = TermContext
  { contextIndexes :: Indexes
  , contextParameters :: Maybe ActionInfo
  }

-- | What a value term denotes, as far as attribute-namespace
-- selection needs to know.  This is deliberately the only
-- typing-shaped judgment in this stage.
data SourceDenotation
  = -- | The term denotes a reference to the named entity.
    DenotesEntity Text
  | -- | The term is known not to denote an entity reference.
    DenotesNonEntity
  | -- | The denotation could not be determined because a prerequisite
    -- name is unknown, ambiguous, or uninterpretable; dependent
    -- checks are suppressed.
    DenotesUnknown

-- | The denotation of a declared type.
typeDenotation :: Maybe DeclaredType -> SourceDenotation
typeDenotation declaredType =
  case declaredType of
    Just (DeclaredEntityRef entityName) -> DenotesEntity entityName
    Just DeclaredBool -> DenotesNonEntity
    Just DeclaredUnit -> DenotesNonEntity
    Just (DeclaredEnum _) -> DenotesNonEntity
    Nothing -> DenotesUnknown

-- | The value-term constructors (the family allowed as an @Attribute@
-- source and in every value position).
valueTermKinds :: [Text]
valueTermKinds = ["Bool", "Unit", "Enum", "Argument", "Actor", "Attribute"]

-- | Walk a value term, returning its reports and its denotation.
walkValueTerm :: TermContext -> [Text] -> Value -> (Reports, SourceDenotation)
walkValueTerm context path value =
  case requireObject path value of
    Left broken -> (broken, DenotesUnknown)
    Right members ->
      case textMember path members "kind" of
        Left broken -> (broken, DenotesUnknown)
        Right kind -> walkValueTermKind context path members kind

-- | Walk a value term whose members and constructor are known.
walkValueTermKind
  :: TermContext
  -> [Text]
  -> KeyMap.KeyMap Value
  -> Text
  -> (Reports, SourceDenotation)
walkValueTermKind context path members kind =
  case kind of
    "Bool" -> (mempty, DenotesNonEntity)
    "Unit" -> (mempty, DenotesNonEntity)
    "Enum" -> (enumTermReports context path members, DenotesNonEntity)
    "Argument" -> argumentTerm
    "Actor" -> (mempty, DenotesEntity distinguishedUserEntity)
    "Attribute" -> attributeTerm
    _ ->
      ( invariantAt
          (path <> ["kind"])
          ("unexpected value-term constructor " <> quoted kind)
      , DenotesUnknown
      )
  where
    indexes = contextIndexes context
    argumentTerm =
      case textMember path members "name" of
        Left broken -> (broken, DenotesUnknown)
        Right parameterName ->
          case contextParameters context of
            Nothing -> (mempty, DenotesUnknown)
            Just action ->
              case lookupName (actionParameters action) parameterName of
                NameMissing ->
                  ( violationAt
                      (path <> ["name"])
                      ( "unknown parameter "
                          <> quoted parameterName
                          <> " in action "
                          <> quoted (actionName action)
                      )
                  , DenotesUnknown
                  )
                NameAmbiguous -> (mempty, DenotesUnknown)
                NameFound declaredType -> (mempty, typeDenotation declaredType)
    attributeTerm =
      let (sourceReports, sourceDenotation) =
            case requireMember path members "source" of
              Left broken -> (broken, DenotesUnknown)
              Right sourceValue ->
                walkValueTerm context (path <> ["source"]) sourceValue
          (memberReports, resultDenotation) =
            case textMember path members "attribute" of
              Left broken -> (broken, DenotesUnknown)
              Right attributeName ->
                resolveAttributeMember indexes path attributeName sourceDenotation
       in (sourceReports <> memberReports, resultDenotation)

-- | Resolve an @Attribute@ member name against the namespace selected
-- by its source's denotation.
resolveAttributeMember
  :: Indexes -> [Text] -> Text -> SourceDenotation -> (Reports, SourceDenotation)
resolveAttributeMember indexes path attributeName sourceDenotation =
  case sourceDenotation of
    DenotesUnknown -> (mempty, DenotesUnknown)
    DenotesNonEntity ->
      ( violationAt
          (path <> ["attribute"])
          ( "cannot select an attribute namespace for "
              <> quoted attributeName
              <> ": the source term does not denote an entity reference"
          )
      , DenotesUnknown
      )
    DenotesEntity entityName ->
      case lookupName (entityIndex indexes) entityName of
        -- An unknown or duplicated source entity is already reported
        -- at its declaration site; do not cascade here.
        NameMissing -> (mempty, DenotesUnknown)
        NameAmbiguous -> (mempty, DenotesUnknown)
        NameFound entity ->
          case lookupName (entityAttributes entity) attributeName of
            NameMissing ->
              ( violationAt
                  (path <> ["attribute"])
                  ( "unknown attribute "
                      <> quoted attributeName
                      <> " in entity "
                      <> quoted entityName
                  )
              , DenotesUnknown
              )
            NameAmbiguous -> (mempty, DenotesUnknown)
            NameFound declaredType -> (mempty, typeDenotation declaredType)

-- | The @Enum@ term: the enum reference, then — only when the enum is
-- unique and known — its value against that enum's own values.
enumTermReports :: TermContext -> [Text] -> KeyMap.KeyMap Value -> Reports
enumTermReports context path members =
  case textMember path members "enum" of
    Left broken -> broken
    Right enumName ->
      case lookupName (enumIndex (contextIndexes context)) enumName of
        NameMissing ->
          violationAt (path <> ["enum"]) ("unknown enum " <> quoted enumName)
        NameAmbiguous -> mempty
        NameFound info ->
          withTextMember path members "value" $ \valueName ->
            if Set.member valueName (enumValues info)
              then mempty
              else
                violationAt
                  (path <> ["value"])
                  ( "unknown value "
                      <> quoted valueName
                      <> " in enum "
                      <> quoted enumName
                  )

-- | The distinguished entity the @Actor@ term denotes; its presence
-- is structurally required, and 'resolveDocumentValue' reports an
-- invariant violation when it is absent.
distinguishedUserEntity :: Text
distinguishedUserEntity = "User"

-- | Walk a policy term: every value-term constructor plus the lookup,
-- option, comparison, and boolean constructors.  The schema already
-- fixes where the Actor-free families apply; this walk adds no second
-- interpretation of that distinction.
walkPolicyTerm :: TermContext -> [Text] -> Value -> Reports
walkPolicyTerm context path value =
  case requireObject path value of
    Left broken -> broken
    Right members ->
      case textMember path members "kind" of
        Left broken -> broken
        Right kind
          | kind `elem` valueTermKinds ->
              fst (walkValueTermKind context path members kind)
          | otherwise -> policyOnlyTerm members kind
  where
    indexes = contextIndexes context
    valueAt segment termValue =
      fst (walkValueTerm context (path <> [segment]) termValue)
    policyAt segment = walkPolicyTerm context (path <> [segment])
    bothOperands members =
      withMember_ path members "left" (policyAt "left")
        <> withMember_ path members "right" (policyAt "right")
    policyOnlyTerm members kind =
      case kind of
        "Lookup" ->
          withTextMember
            path
            members
            "relation"
            (checkRelationReference indexes (path <> ["relation"]))
            <> withArrayMember path members "endpoints" (mconcat . map endpointTerm)
        "None" ->
          withMember_
            path
            members
            "payloadType"
            (walkDeclaredType indexes (path <> ["payloadType"]))
        "Some" -> withMember_ path members "value" (valueAt "value")
        "IsSome" -> withMember_ path members "value" (policyAt "value")
        "Equal" -> bothOperands members
        "LessOrEqual" -> bothOperands members
        "And" -> bothOperands members
        "Or" -> bothOperands members
        "Not" -> withMember_ path members "value" (policyAt "value")
        _ ->
          invariantAt
            (path <> ["kind"])
            ("unexpected policy-term constructor " <> quoted kind)
    endpointTerm (index, termValue) =
      fst
        ( walkValueTerm
            context
            (path <> ["endpoints", showIndex index])
            termValue
        )

--------------------------------------------------------------------
-- Internal: actions (pass 3)
--------------------------------------------------------------------

-- | Walk one action positionally: parameter type references, the
-- allow policy (both branches for @AnyPrincipal@), the effect, and
-- the result, all in the action's own parameter environment.
walkAction :: Indexes -> (Int, Value, Maybe ActionInfo) -> Reports
walkAction indexes (index, value, ownInfo) =
  withObject_ path value $ \members ->
    parameterTypes members
      <> allowPolicy members
      <> withMember_ path members "effect" (walkEffect context (path <> ["effect"]))
      <> withMember_ path members "result" (walkResult context (path <> ["result"]))
  where
    path = ["actions", showIndex index]
    context = TermContext indexes ownInfo
    parameterTypes members =
      withArrayMember path members "parameters" $ \parameterItems ->
        mconcat
          [ withObject_ parameterPath parameterValue $ \parameterMembers ->
              withMember_ parameterPath parameterMembers "type" $
                walkDeclaredType indexes (parameterPath <> ["type"])
          | (parameterIndex, parameterValue) <- parameterItems
          , let parameterPath = path <> ["parameters", showIndex parameterIndex]
          ]
    allowPolicy members =
      withTextMember path members "principalMode" $ \mode ->
        case mode of
          "AuthenticatedOnly" ->
            withMember_
              path
              members
              "allow"
              (walkPolicyTerm context (path <> ["allow"]))
          "AnyPrincipal" ->
            withMember_ path members "allow" $ \allowValue ->
              withObject_ allowPath allowValue $ \allowMembers ->
                withMember_
                  allowPath
                  allowMembers
                  "anonymous"
                  (walkPolicyTerm context (allowPath <> ["anonymous"]))
                  <> withMember_
                    allowPath
                    allowMembers
                    "authenticated"
                    (walkPolicyTerm context (allowPath <> ["authenticated"]))
          _ ->
            invariantAt
              (path <> ["principalMode"])
              ("unexpected principal mode " <> quoted mode)
      where
        allowPath = path <> ["allow"]

-- | Walk an effect.  Only names are resolved: initializer
-- completeness, endpoint arity and types, payload types, and mutation
-- semantics all remain for later stages.
walkEffect :: TermContext -> [Text] -> Value -> Reports
walkEffect context path value =
  withObject_ path value $ \members ->
    case textMember path members "kind" of
      Left broken -> broken
      Right kind ->
        case kind of
          "NoChange" -> mempty
          "CreateEntity" -> createEntity members
          "DeleteEntity" ->
            withMember_ path members "target" (valueAt "target")
          "SetRelation" ->
            relationEffect members
              <> withMember_ path members "payload" (valueAt "payload")
          "RemoveRelation" -> relationEffect members
          _ ->
            invariantAt
              (path <> ["kind"])
              ("unexpected effect constructor " <> quoted kind)
  where
    indexes = contextIndexes context
    valueAt segment termValue =
      fst (walkValueTerm context (path <> [segment]) termValue)
    relationEffect members =
      withTextMember
        path
        members
        "relation"
        (checkRelationReference indexes (path <> ["relation"]))
        <> withArrayMember path members "endpoints" (mconcat . map endpointTerm)
    endpointTerm (index, termValue) =
      fst
        ( walkValueTerm
            context
            (path <> ["endpoints", showIndex index])
            termValue
        )
    createEntity members =
      case textMember path members "entity" of
        Left broken -> broken <> initializers members Nothing
        Right entityName ->
          checkEntityReference indexes (path <> ["entity"]) entityName
            <> initializers members (initializerOwner entityName)
    initializerOwner entityName =
      case lookupName (entityIndex indexes) entityName of
        -- Unknown or duplicated target entity: the root problem is
        -- reported once, and the initializer keys — which cannot be
        -- resolved without a unique target — are suppressed.  The
        -- initializer value terms are still walked.
        NameFound entity -> Just (entityName, entity)
        NameMissing -> Nothing
        NameAmbiguous -> Nothing
    initializers members owner =
      withMember_ path members "attributes" $ \attributesValue ->
        withObject_ (path <> ["attributes"]) attributesValue $ \attributeMembers ->
          mconcat
            [ initializerKey owner keyName keyPath
                <> fst (walkValueTerm context keyPath termValue)
            | (key, termValue) <- KeyMap.toList attributeMembers
            , let keyName = Key.toText key
                  keyPath = path <> ["attributes", keyName]
            ]
    initializerKey owner keyName keyPath =
      case owner of
        Nothing -> mempty
        Just (entityName, entity) ->
          case lookupName (entityAttributes entity) keyName of
            NameMissing ->
              violationAt
                keyPath
                ( "unknown attribute "
                    <> quoted keyName
                    <> " in entity "
                    <> quoted entityName
                )
            _ -> mempty

-- | Walk a result.  Whether an @Observe@ term denotes an entity is a
-- static-typing question, not checked here.
walkResult :: TermContext -> [Text] -> Value -> Reports
walkResult context path value =
  withObject_ path value $ \members ->
    case textMember path members "kind" of
      Left broken -> broken
      Right kind ->
        case kind of
          "Observe" ->
            withMember_ path members "entity" $ \termValue ->
              fst (walkValueTerm context (path <> ["entity"]) termValue)
          "Created" -> mempty
          "Done" -> mempty
          _ ->
            invariantAt
              (path <> ["kind"])
              ("unexpected result constructor " <> quoted kind)

--------------------------------------------------------------------
-- Internal: guarantees (pass 4)
--------------------------------------------------------------------

-- | Walk one guarantee.  @AuthenticatedMutation@ carries no
-- declaration-name reference beyond its structural target selector;
-- the other two families resolve their case actions, resolve their
-- terms in the referenced action's parameter environment, and — for
-- @NoSelfPrivilegeEscalation@ — resolve the authority relation, its
-- endpoints, and the payload-order enum.
walkGuarantee :: Indexes -> (Int, Value) -> Reports
walkGuarantee indexes (index, value) =
  withObject_ path value $ \members ->
    case textMember path members "kind" of
      Left broken -> broken
      Right kind ->
        case kind of
          "AuthenticatedMutation" -> mempty
          "TenantIsolation" ->
            withArrayMember path members "cases" (mconcat . map tenantIsolationCase)
          "NoSelfPrivilegeEscalation" ->
            withMember_ path members "authority" (authority (path <> ["authority"]))
              <> withArrayMember path members "cases" (mconcat . map escalationCase)
          _ ->
            invariantAt
              (path <> ["kind"])
              ("unexpected guarantee constructor " <> quoted kind)
  where
    path = ["guarantees", showIndex index]
    tenantIsolationCase (caseIndex, caseValue) =
      let casePath = path <> ["cases", showIndex caseIndex]
       in withObject_ casePath caseValue $ \caseMembers ->
            let (actionReports, context) =
                  caseActionContext indexes casePath caseMembers
             in actionReports
                  <> withMember_ casePath caseMembers "tenant" (\termValue ->
                       fst (walkValueTerm context (casePath <> ["tenant"]) termValue))
                  <> withMember_
                    casePath
                    caseMembers
                    "protected"
                    (walkPolicyTerm context (casePath <> ["protected"]))
                  <> withMember_
                    casePath
                    caseMembers
                    "tenantAccess"
                    (walkPolicyTerm context (casePath <> ["tenantAccess"]))
    escalationCase (caseIndex, caseValue) =
      let casePath = path <> ["cases", showIndex caseIndex]
       in withObject_ casePath caseValue $ \caseMembers ->
            let (actionReports, context) =
                  caseActionContext indexes casePath caseMembers
             in actionReports
                  <> withArrayMember casePath caseMembers "scope" (\scopeItems ->
                       mconcat
                         [ fst
                             ( walkValueTerm
                                 context
                                 (casePath <> ["scope", showIndex scopeIndex])
                                 termValue
                             )
                         | (scopeIndex, termValue) <- scopeItems
                         ])
    authority authorityPath authorityValue =
      withObject_ authorityPath authorityValue $ \authorityMembers ->
        authorityRelation authorityPath authorityMembers
          <> withTextMember
            authorityPath
            authorityMembers
            "payloadOrder"
            (checkEnumReference indexes (authorityPath <> ["payloadOrder"]))
    authorityRelation authorityPath authorityMembers =
      case textMember authorityPath authorityMembers "relation" of
        Left broken -> broken
        Right relationName ->
          let endpointOwner =
                case lookupName (relationIndex indexes) relationName of
                  -- An unknown or duplicated authority relation is
                  -- reported once (below, or at its declaration
                  -- sites); its endpoint names cannot be resolved and
                  -- are suppressed.
                  NameFound relation -> Just relation
                  NameMissing -> Nothing
                  NameAmbiguous -> Nothing
              endpointCheck endpointPath endpointName =
                case endpointOwner of
                  Nothing -> mempty
                  Just relation ->
                    case lookupName (relationEndpoints relation) endpointName of
                      NameMissing ->
                        violationAt
                          endpointPath
                          ( "unknown endpoint "
                              <> quoted endpointName
                              <> " in relation "
                              <> quoted relationName
                          )
                      _ -> mempty
           in checkRelationReference
                indexes
                (authorityPath <> ["relation"])
                relationName
                <> withTextMember
                  authorityPath
                  authorityMembers
                  "subjectEndpoint"
                  (endpointCheck (authorityPath <> ["subjectEndpoint"]))
                <> withArrayMember
                  authorityPath
                  authorityMembers
                  "scopeEndpoints"
                  ( \endpointItems ->
                      mconcat
                        [ either id (endpointCheck endpointPath) (requireText endpointPath item)
                        | (endpointIndex, item) <- endpointItems
                        , let endpointPath =
                                authorityPath
                                  <> ["scopeEndpoints", showIndex endpointIndex]
                        ]
                  )

-- | Resolve a guarantee case's @action@ reference and produce the
-- term context its terms are resolved in.  An unknown action is
-- reported once at the reference; an unknown or duplicated action
-- yields a suppressed parameter environment, so the case's terms
-- produce no dependent parameter errors.
caseActionContext
  :: Indexes -> [Text] -> KeyMap.KeyMap Value -> (Reports, TermContext)
caseActionContext indexes casePath caseMembers =
  case textMember casePath caseMembers "action" of
    Left broken -> (broken, TermContext indexes Nothing)
    Right name ->
      case lookupName (actionIndex indexes) name of
        NameMissing ->
          ( violationAt
              (casePath <> ["action"])
              ("unknown action " <> quoted name)
          , TermContext indexes Nothing
          )
        NameAmbiguous -> (mempty, TermContext indexes Nothing)
        NameFound info -> (mempty, TermContext indexes (Just info))

--------------------------------------------------------------------
-- Internal: the document walk
--------------------------------------------------------------------

-- | Resolve every name site of the document value, producing raw
-- (unnormalized) reports.
resolveDocumentValue :: Value -> Reports
resolveDocumentValue documentValue =
  case requireObject [] documentValue of
    Left broken -> broken
    Right rootMembers ->
      let schemaPart = requireMember [] rootMembers "schema"
          actionsPart =
            requireMember [] rootMembers "actions"
              >>= requireArray ["actions"]
          guaranteesPart =
            requireMember [] rootMembers "guarantees"
              >>= requireArray ["guarantees"]

          (schemaReports, schemaNamespaces) =
            case schemaPart of
              Left broken -> (broken, emptySchemaNamespaces)
              Right schemaValue -> buildSchemaNamespaces schemaValue

          (actionReports, actionNamespace, positionalActions) =
            case actionsPart of
              Left broken -> (broken, emptyNamespace, [])
              Right actionItems -> buildActions actionItems

          (entityNamespace, enumNamespace, relationNamespace) =
            schemaNamespaces
          indexes =
            Indexes
              { entityIndex = entityNamespace
              , enumIndex = enumNamespace
              , relationIndex = relationNamespace
              , actionIndex = actionNamespace
              }

          -- The schema structurally requires an entity named User
          -- ('contains'); its absence after successful structural
          -- validation is drift, and Actor terms silently denote it.
          userEntityReports =
            case schemaPart of
              Left _ -> mempty
              Right _ ->
                case lookupName entityNamespace distinguishedUserEntity of
                  NameMissing ->
                    invariantAt
                      ["schema", "entities"]
                      ( "no entity named "
                          <> quoted distinguishedUserEntity
                          <> " is declared after structural validation"
                      )
                  _ -> mempty

          declarationReports =
            case schemaPart of
              Left _ -> mempty
              Right schemaValue -> checkSchemaDeclarations indexes schemaValue

          actionBodyReports =
            mconcat (map (walkAction indexes) positionalActions)

          guaranteeReports =
            case guaranteesPart of
              Left broken -> broken
              Right guaranteeItems ->
                mconcat (map (walkGuarantee indexes) guaranteeItems)
       in schemaReports
            <> actionReports
            <> userEntityReports
            <> declarationReports
            <> actionBodyReports
            <> guaranteeReports

emptySchemaNamespaces
  :: (Namespace EntityInfo, Namespace EnumInfo, Namespace RelationInfo)
emptySchemaNamespaces = (emptyNamespace, emptyNamespace, emptyNamespace)

-- | Build the three schema namespaces from the raw @schema@ value.
buildSchemaNamespaces
  :: Value
  -> (Reports, (Namespace EntityInfo, Namespace EnumInfo, Namespace RelationInfo))
buildSchemaNamespaces schemaValue =
  case requireObject ["schema"] schemaValue of
    Left broken -> (broken, emptySchemaNamespaces)
    Right schemaMembers ->
      let (entityReports, entityNamespace) =
            buildPart schemaMembers "entities" buildEntities
          (enumReports, enumNamespace) =
            buildPart schemaMembers "enums" buildEnums
          (relationReports, relationNamespace) =
            buildPart schemaMembers "relations" buildRelations
       in ( entityReports <> enumReports <> relationReports
          , (entityNamespace, enumNamespace, relationNamespace)
          )
  where
    buildPart schemaMembers name build =
      case requireMember ["schema"] schemaMembers name
        >>= requireArray ["schema", name] of
        Left broken -> (broken, emptyNamespace)
        Right items -> build items
