# Mithril compiler architecture

- **Status:** accepted
- **Date:** 2026-08-13

This document is authoritative for the Mithril compiler pipeline and for artifact-ownership boundaries: which artifacts are authored, which are derived, and which are trusted. It does not replace [`core/schema.json`](../core/schema.json), which remains the normative authority for the external JSON shape of a Core v0 document.

The architecture below is agreed, not built. No part of the pipeline is implemented yet; [Current implementation status](#current-implementation-status) states exactly what exists today.

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
- GHC, Cabal, dependency, packaging, and distribution choices are not made by this document and remain open until the toolchain is bootstrapped by an explicit task.

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

- the Haskell frontend and emitters, including the contract renderer;
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

As of 2026-08-13, no part of the pipeline above is implemented.

Exists today (all authored by hand):

- [`core/schema.json`](../core/schema.json) — the normative Core v0 external JSON shape;
- [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json) — a handwritten, unverified example model;
- the experimental Agda kernel spike under [`agda/`](../agda/README.md), including the hand-transcribed `Mithril.Acme` slice: one checked NoSelfPrivilegeEscalation case for the Acme `Membership.changeRole` action, with a checked unsafe-variant counterexample;
- this document.

Does not exist yet:

- any Haskell code: no CLI, parser, resolver, typechecker, normalizer, contract renderer, or emitter, and no Haskell scaffold, package configuration, or toolchain;
- any automated JSON-to-Agda connection — the `Mithril.Acme` slice is hand-transcribed, not derived from the JSON example;
- any contract rendering, Wasp generation, or other target generation;
- any derived artifact, generation metadata, or manifest.

## Explicit non-claims

This document makes design commitments, not correctness claims:

- It does not claim that any stage of the pipeline is implemented. None is.
- Selecting Haskell does not create a Haskell toolchain, scaffold, or package; none exists, and none may be added except by an explicit task.
- Determinism and reproducibility are design intent, not demonstrated properties of any existing tool — and determinism, once achieved, is still not correctness.
- Generated code will not be called verified merely because it was generated; a verified status requires the gates in [Verification gates](#verification-gates).
- Neither [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json) nor the complete Acme model is verified. The one existing proof slice is hand-transcribed and covers a single action and a single selected guarantee case.
- No semantic-preservation result between Core and any target exists, and this document promises none; executable-correspondence claims are made per adapter or not at all.
- Mithril does not claim, and will not claim, general application security. The non-guarantees in the [README](../README.md#what-mithril-will-not-guarantee) and the claim-scoping rules in [`SECURITY.md`](../SECURITY.md) apply unchanged.
- The LLM translation step is untrusted and outside every verification claim; contract review mitigates, but cannot prove, fidelity to the human's original intent.
