# Mithril compiler architecture

- **Status:** accepted
- **Date:** 2026-08-13

This document is authoritative for the Mithril compiler pipeline and for artifact-ownership boundaries: which artifacts are authored, which are derived, and which are trusted. It does not replace [`core/schema.json`](../core/schema.json), which remains the normative authority for the external JSON shape of a Core v0 document.

The architecture below is agreed and almost entirely unbuilt. Exactly two frontend boundaries exist — deterministic JSON parsing plus Core v0 structural validation, and complete Core v0 name resolution, exposed together as `mithril validate FILE`; [Current implementation status](#current-implementation-status) states exactly what exists today.

## Purpose

Mithril's planned toolchain will turn one authored access-control model — a Mithril Core v0 JSON document — into three coordinated derived artifacts: a human-readable security contract for review, an application-specific Agda model whose selected proof obligations the Agda toolchain checks, and executable enforcement for a target framework, with [Wasp](https://wasp.sh/) first. This architecture is agreed now, before implementation begins, so that by construction the contract a human reviews, the model Agda checks, and the code that executes all derive deterministically from the same typed normalized reading of the same document — never from independent interpretations of it.

## Pipeline

```text
natural-language intent
        |
        | optional, untrusted human or LLM translation
        v
authored Mithril JSON
        |
        v
Haskell frontend
  parse + Draft 2020-12 structural validation
        |
        v
name resolution + static typing
        |
        v
typed normalized Core
   /          |             \
  v           v              v
contract   Agda backend   target emitter
             |              |
             v              v
        Agda checking    Wasp first
```

Everything above `authored Mithril JSON` is untrusted translation of human intent; a human, an LLM, or both may be involved. Everything below it is intended to be deterministic and reproducible: the same authored document must always yield the same typed normalized Core, the same contract, the same generated Agda, and the same target output.

### Frontend stages

The frontend is one pipeline whose stages are conceptually `Raw -> Resolved -> Typed -> Normalized`:

| Stage | Result | Establishes |
|---|---|---|
| parse + structural validation | `Raw` | The input is JSON conforming to [`core/schema.json`](../core/schema.json) (JSON Schema draft 2020-12). Structural validity only. |
| name resolution | `Resolved` | Declaration-name uniqueness and resolution of every reference to an existing declaration. |
| static typing | `Typed` | Static types of terms, policies, effects, and results; enum-order validation; endpoint compatibility; the similar semantic checks the schema defers. |
| normalization | `Normalized` | The typed normalized Core: the single canonical form every backend consumes. |

## Component responsibilities

One deterministic host tool, implemented in Haskell, will contain the CLI, the frontend stages, the contract renderer, and the backend emitters.

| Component | Responsibility |
|---|---|
| [`core/schema.json`](../core/schema.json) | Normative external JSON shape of a Core v0 document; structural authority only. Authored and versioned, not part of the host tool. |
| Haskell frontend | Parsing, draft 2020-12 structural validation, name resolution, static typing, normalization. The sole producer of typed normalized Core. |
| contract renderer | Deterministic rendering of the typed normalized Core as a human-readable security contract for review. |
| Agda backend | Deterministic generation of the application-specific Agda model and proof obligations from the typed normalized Core, targeting the authored generic Agda kernel. Checking is performed by the Agda toolchain across a process boundary. |
| target emitter | Deterministic generation of target-specific enforcement from the typed normalized Core, through a target adapter. Wasp is the first target. |

### One frontend, one normalized Core

There is one Mithril JSON parser/frontend — not one parser per backend. JSON Schema validation establishes structural validity only; name uniqueness, reference resolution, static typing, enum-order validation, endpoint compatibility, and similar semantic checks belong to the Haskell frontend. Contract generation, Agda generation, and executable enforcement must all consume the same typed normalized Core. Independent interpretations of the JSON for Agda and for Wasp are forbidden: a backend that re-parses or re-interprets the authored JSON bypasses the semantic stages and reintroduces exactly the divergence this architecture exists to prevent.

### Haskell boundary

Haskell is the accepted implementation language for the deterministic host tool: the CLI, the frontend stages, the contract renderer, and the backend emitters. The scope of that decision is deliberately narrow:

- It does not make Haskell the proof backend. Agda remains a separate formal backend/checker, reached through generated files and a process boundary; Mithril will not import or depend on Agda compiler internals as a Haskell library.
- Advanced Haskell types should enforce concrete pipeline invariants — for example, that emitters and the contract renderer accept only the `Normalized` stage — not recreate a second proof assistant inside the host tool.
- This document makes no toolchain choices itself. Explicit tasks have since fixed GHC 9.12.4, cabal-install 3.18.1.0, and the GHC2021 language edition, and selected the structural-validation dependencies: Aeson for JSON parsing, the native Haskell `jsonschema` package, pinned exactly to 0.3.0.1, as the provisional JSON Schema backend, and `regex-tdfa` — the backend's own regex engine — as a direct dependency of the schema-profile gate. The backend is trusted only for an explicitly gated schema profile (exact draft 2020-12 `$schema` URI, a closed keyword inventory, local unescaped `#` references only, annotation-only `$ref` siblings; no external references or anchors, no `unevaluated*` or dynamic references, and regex semantics inherited from the backend rather than guaranteed ECMA-262 — the gate compiles every `pattern` with that same engine at load time, so an uncompilable pattern is a schema-load failure rather than a validation-time exception) — schema loading fails closed outside that profile, and no complete Draft 2020-12 implementation is claimed. The canonical `core/schema.json` — which remains the single authoritative source for the external Core v0 JSON grammar — is compiled into the host tool at build time (embedded via Template Haskell, with the file registered as a build dependency so edits trigger recompilation) and is the only schema the public validation API can use: no runtime file lookup or environment override, in particular the Cabal `mithril_ir_datadir` package-data variable, can substitute the grammar that confers structural validity. This is provenance by construction, not a cryptographic-integrity or formal-verification claim. A later explicit task implemented the name-resolution stage and added its one direct dependency, `containers` (`>= 0.7 && < 0.8`, resolving to the GHC boot library containers-0.7, BSD-3-Clause), for the resolver's deterministic ordered maps and sets. Packaging and distribution remain open.

### Schema and resolver evolution

The frontend's one interpretation of the current Core v0 schema is complete — the internal schema decoder that turns structurally valid JSON into the explicit surface syntax, the decoded and resolved representation types that mirror every construct, and the `Mithril.Core.Resolution` pass over them — but keeping schema and frontend evolution aligned is a manually reviewed contract. Template Haskell's `addDependentFile` registration and the resulting recompilation detect that the bytes of `core/schema.json` changed; they do not establish decoder, representation, or resolver completeness. A schema change is therefore not complete merely because structural validation and compilation pass.

Any change to `core/schema.json` that affects declaration namespaces; reference-bearing fields; term, policy, effect, result, or guarantee constructors; enum-value uniqueness or order assumptions; the distinguished `User` entity requirement; or any structural invariant on which the frontend relies for totality or no-cascade behavior must include an explicit audit of the schema decoder and the representation's construct coverage as well as `Mithril.Core.Resolution`, plus the relevant targeted regression tests, in the same change. The audit must identify every added, removed, or changed constructor and reference location and demonstrate that the decoder and representation carry it and that resolution either traverses it or deliberately does not treat it as a name. Add positive, unknown-reference, duplicate/ambiguity, no-cascade, and invariant-drift regressions wherever the schema change makes them relevant. This audit is mandatory review-and-test discipline, not a currently automated completeness check; do not introduce a second copy of the schema or claim that recompilation automates it.

## LLM boundary

- An LLM is optional. A human may author or edit Mithril JSON directly.
- An LLM may propose changes only up to the authored Core document. No LLM participates in JSON-to-Agda generation, contract rendering, normalization, or target code generation.
- Everything downstream of the authored Core document is intended to be deterministic and reproducible.
- The LLM is untrusted. Human review of the generated readable contract mitigates mistranslation of intent, but it cannot prove the human's original intent: a deterministic pipeline faithfully applied to a mis-stated model still enforces the wrong policy.

## Authored, derived, and trusted artifacts

### Authored and versioned

Authored artifacts are written by humans (or proposed by an LLM and accepted by a human), live in version control, and are the only place corrections are made:

- Mithril JSON models, written by a human or proposed by an LLM — today [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json);
- [`core/schema.json`](../core/schema.json);
- the generic Agda kernel/semantics modules — today the spike under [`agda/`](../agda/README.md);
- the Haskell frontend and emitter implementation, once it exists;
- target runtime support, templates, and adapters, once they exist;
- ordinary application UI and business logic outside the Mithril-generated boundary.

### Derived

Derived artifacts are produced deterministically by the host tool for a particular build:

- the typed normalized Core for that build;
- the human-readable security contract;
- the application-specific Agda model and proof obligations, and proof terms where the backend supports producing them;
- target-specific generated enforcement;
- generation metadata or manifests, when implemented.

**Derived files must never be hand-edited.** If an output is wrong, the authored input or the generator is corrected and the artifact regenerated ([`AGENTS.md`](../AGENTS.md), hard rule 5).

No derived artifact exists today: the repository has no automated pipeline, and nothing in it is generated. In particular, the `Mithril.Acme` proof slice is hand-transcribed authored Agda ([`agda/README.md`](../agda/README.md)); it is not derived from [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json), and no tool checks the transcription against the JSON.

### Trusted computing base

Determinism is not itself correctness: a deterministic pipeline reproducibly delivers whatever its trusted components produce, including their bugs. For the MVP, the trusted computing base includes, as applicable to the deployment in question:

- the Haskell frontend and emitters, including the contract renderer — today that means the implemented parse + structural-validation + name-resolution boundaries, including Aeson (JSON parsing), the exactly pinned `jsonschema 0.3.0.1` package (MPL-2.0), which performs structural validation for the gated Core v0 schema profile and is trusted for nothing beyond it, `regex-tdfa` (BSD-3-Clause), the regex engine beneath that backend, which the profile gate also uses directly to compile every schema `pattern` at load time, and `containers` (BSD-3-Clause), the GHC boot library providing the resolver's deterministic maps and sets;
- the generic Agda model that generated obligations target;
- the Agda toolchain;
- the target adapter and runtime;
- Wasp, Node, Prisma, and PostgreSQL for the Wasp target;
- the relevant platform components beneath them.

A defect in any of these can invalidate a verification claim without any change to the authored model. [`SECURITY.md`](../SECURITY.md) governs how verification claims are scoped to documented properties and documented assumptions.

### Verification gates

Generated code must not be called verified merely because it was generated, and a deterministic pipeline confers no verified status by itself. A verified status for a given build requires the relevant gates to pass:

1. structural validation against `core/schema.json` and the frontend's semantic checks;
2. human review of the rendered security contract — the mitigation for mistranslated intent;
3. successful Agda checking of the generated proof obligations for the selected guarantees;
4. for executable claims, the target adapter's documented correspondence between abstract Core semantics and the generated enforcement (see [Future backend model](#future-backend-model)).

Even then, the claim covers exactly the selected properties under the stated trusted-computing-base assumptions — never general application security, and never semantic-preservation properties that have not themselves been proved.

## Wasp v1 boundary

[Wasp](https://wasp.sh/) is the first executable target, not Mithril's product boundary and not a permanent dependency of Core:

- Wasp remains involved throughout application development and compilation. It is the full-stack framework the application actually uses, not a one-time scaffolder Mithril runs once and abandons.
- Mithril v1 should emit normal Wasp inputs — declarations and code a standard, unmodified Wasp compiler accepts. Modifying the Wasp compiler is out of scope.
- Mithril is not a replacement full-stack framework. Humans or coding agents continue to write the UI and ordinary business logic.
- Within its supported scope, Mithril is intended to generate the complete security-sensitive operation/enforcement boundary — not optional authorization helpers that application code can forget to call.
- The planned restricted Acme MVP — a deliberately minimized end-to-end demonstration over the Acme example — may generate a complete minimal backend. That is a property of the small demo, not a general claim: Mithril does not generate every part of real applications.
- Exact generated filenames and the final adapter API are deferred to emitter design; this document deliberately freezes neither.

## Future backend model

Future execution environments require target-specific emitters/adapters, not new Mithril parsers. Every target consumes the same typed normalized Core from the same frontend.

Adapters are framework/execution-environment specific, not simply programming-language specific: a language name is not an adapter — a concrete framework and execution environment is. Each adapter must define:

| Adapter obligation | Question it answers |
|---|---|
| authenticated-principal input | How does the authenticated principal enter generated enforcement? |
| data-access boundary | Through which layer does generated enforcement read and write data? |
| atomicity assumptions | Which transactional guarantees does the environment provide, and which does generated code rely on? |
| supported operations | Which Core operations can this target execute faithfully? |
| bypass prevention | How is application code kept from reaching data or operations around the generated enforcement? |

A backend cannot receive a verification claim merely because the abstract Core verified. Correspondence between the verified abstract semantics and the target's executable enforcement remains necessary, per adapter — it is claimed explicitly or not at all.

## Current implementation status

As of 2026-08-14, exactly two frontend boundaries of the pipeline above are implemented: deterministic JSON parsing plus Core v0 structural validation, and complete Core v0 name resolution, exposed together as `mithril validate FILE`. Everything after them remains unbuilt.

Exists today (all authored by hand):

- [`core/schema.json`](../core/schema.json) — the normative Core v0 external JSON shape, compiled into the tool at build time (never installed or read as runtime package data);
- [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json) — a handwritten, unverified example model, which passes structural validation and name resolution;
- the experimental Agda kernel spike under [`agda/`](../agda/README.md), including the hand-transcribed `Mithril.Acme` slice: one checked NoSelfPrivilegeEscalation case for the Acme `Membership.changeRole` action, with a checked unsafe-variant counterexample;
- the Haskell host tool: Cabal package `mithril-ir` building the `mithril` CLI — help and version output plus `mithril validate FILE` (raw bytes → JSON parsing → Core v0 structural validation → complete name resolution → resolved opaque document carrying the explicit internal decoded and name-resolved Core representation, with stage-indexed types so later stages cannot accept merely parsed input as validated, nor merely validated input as resolved) — with unit tests, process-level CLI regression tests over the built executable, and downstream plus in-package API-boundary compile-fail probes over these boundaries, fixed to GHC 9.12.4, cabal-install 3.18.1.0, and GHC2021, plus the pinned Haskell CI workflow;
- this document.

The name-resolution stage establishes exactly two kinds of fact. First, declaration-name uniqueness independently per namespace: entities, enums, relations, and actions globally; attributes within one entity, endpoints within one relation, parameters within one action (the same text may name declarations in different namespaces or under different owners). Second, resolution of every Core v0 name reference in its correct namespace: enum and entity references in declared types, relation endpoint entities, relation payload enums, enum-order members against the enum's own values, every term constructor (including `Enum` values against their enum, action-local `Argument` references, `Lookup` relations, and `None` payload enums), effect targets and `CreateEntity` initializer keys, result terms, and every guarantee reference — case actions with their terms resolved in the referenced action's parameter environment, and the NoSelfPrivilegeEscalation authority relation, its subject and scope endpoints, and its payload-order enum. The only typing-shaped judgment in the stage is the narrow declared-type lookup that selects the entity-local namespace of an `Attribute` projection (`Actor` denotes the distinguished `User` entity; an `Argument` or nested `Attribute` whose declared type is `EntityRef` denotes that entity; a source known not to denote an entity reference is a resolution failure). `Resolved` is an opaque stage attestation about names — not typed normalized Core: term typing, operator and comparison operand compatibility, enum-order completeness and permutation validity, endpoint arity and type compatibility at lookup and effect sites, payload agreement, initializer completeness and value typing, guarantee well-typedness and truth, policy evaluation, and normalization all remain for the unimplemented typechecker and normalizer, so a document can resolve successfully and still fail the future typechecker. Resolution diagnostics are deterministic — JSON-pointer locations, sorted, deduplicated, with dependent errors suppressed rather than cascaded — and shapes the resolver cannot interpret after successful structural validation are classified separately as internal resolver-invariant failures (tool exit status 2), never as user name errors.

The representation decision recorded as deliberately temporary at the previous milestone is now closed. A `Resolved` document no longer retains the structurally validated JSON value: the frontend decodes it, in one interpretation shared with the resolver, into an explicit internal decoded and name-resolved Core representation. Every Core v0 construct of `core/schema.json` is an explicit node; every resolved reference — declared-type enums and entities, endpoint entities, payload enums, enum-order members, enum values, action arguments, the distinguished `Actor` reference to the unique `User` entity, attribute projections, lookup and relation-effect targets, `CreateEntity` targets and initializer keys, guarantee case actions and their action-scoped terms, and the `NoSelfPrivilegeEscalation` authority relation, endpoints, and payload-order enum — carries a namespace-specific internal identifier (owner-local identifiers embed their owner) rather than a textual name, with declaration names kept only as diagnostic metadata; and every node and reference retains its originating JSON path, so the future typechecker can diagnose at the authored location without rereading raw JSON. Structurally established facts are encoded in the representation's types: the actor-free term, effect, and result families of `AnyPrincipal` actions are distinct type-indexed shapes that cannot contain an `Actor`, the two principal modes carry their distinct allow shapes, and only the structurally permitted classification/effect/result combinations are representable. Generic Aeson `Value` ends at the internal decode boundary — it is not the representation later stages consume — and the typechecker, normalizer, Agda emitter, and backend adapters must consume this representation rather than reinterpreting raw JSON or rebuilding name resolution independently (the per-backend half of this rule is already fixed under [One frontend, one normalized Core](#one-frontend-one-normalized-core)). The representation is internal to the host tool — it lives in a package-private sublibrary (an internal testability and encapsulation mechanism, not a packaging or distribution decision), so external code cannot import it, construct its nodes, mint or coerce its identifiers, or extract a raw JSON value from a resolved document, which the downstream compile-fail probes pin. The identifier namespaces are distinct data types, so even in-package compiler code cannot coerce one namespace into another — pinned by in-package non-coercion probes whose own control imports the real identifier definitions — while the package's own test suite uses the private sublibrary to white-box-inspect the real resolved model the production pipeline constructs: positional identifiers, owner-encoded local identifiers, resolved references, retained source paths, and cross-run determinism of the complete model. It is not typed normalized Core: it remains untyped, unnormalized, and unverified, and proves no property.

Known limitations of the implemented boundaries (deliberate, unresolved): duplicate JSON object members are not rejected (Aeson member semantics — a provisional gap, not a desired contract), and no input-size or resource limits are enforced. The validation backend is trusted only within the gated schema profile described under [Haskell boundary](#haskell-boundary).

Does not exist yet:

- the remaining semantic frontend stages: no Mithril typechecker and no normalizer — a resolved document is untyped and unnormalized, and no typed normalized Core exists (the explicit resolved representation above is the typechecker's intended input, not its output);
- any automated JSON-to-Agda connection — the `Mithril.Acme` slice is hand-transcribed, not derived from the JSON example;
- any contract rendering, Wasp generation, or other target generation;
- any derived artifact, generation metadata, or manifest.

## Explicit non-claims

This document makes design commitments, not correctness claims:

- It does not claim that any pipeline stage beyond parsing, structural validation, and name resolution is implemented. None is.
- A structurally valid document is not typed normalized Core. Structural validation establishes JSON shape conformance to the gated schema profile only; it is not name resolution, not typing, not normalization, not semantic well-formedness, not guarantee truth, and not verification of the Acme model or any application.
- A resolved document is likewise not typed normalized Core. Name resolution establishes declaration-name uniqueness and reference existence only; deterministic name resolution is not static typing, not semantic well-formedness, not guarantee truth, and not formal verification of anything.
- The structural-validation backend (`jsonschema 0.3.0.1`) is provisional and gated: only the supported schema profile is accepted, and no complete Draft 2020-12 implementation is claimed. Duplicate JSON member rejection and input/resource limits remain unresolved gaps of the implemented boundary. Packaging, distribution, generated filenames, manifest format, and the adapter API all remain open.
- Determinism and reproducibility are design intent, not demonstrated properties of any existing tool — and determinism, once achieved, is still not correctness.
- Generated code will not be called verified merely because it was generated; a verified status requires the gates in [Verification gates](#verification-gates).
- Neither [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json) nor the complete Acme model is verified. The one existing proof slice is hand-transcribed and covers a single action and a single selected guarantee case.
- No semantic-preservation result between Core and any target exists, and this document promises none; executable-correspondence claims are made per adapter or not at all.
- Mithril does not claim, and will not claim, general application security. The non-guarantees in the [README](../README.md#what-mithril-will-not-guarantee) and the claim-scoping rules in [`SECURITY.md`](../SECURITY.md) apply unchanged.
- The LLM translation step is untrusted and outside every verification claim; contract review mitigates, but cannot prove, fidelity to the human's original intent.
