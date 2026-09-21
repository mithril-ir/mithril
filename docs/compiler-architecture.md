# Mithril compiler architecture

This document is authoritative for the Mithril compiler pipeline and for artifact-ownership boundaries: which artifacts are authored, which are derived, and which are trusted. It does not replace [`core/schema.json`](../core/schema.json), which remains the normative authority for the external JSON shape of a Core v0 document.

Related documents: [how-mithril-works.md](how-mithril-works.md) is the accessible (non-normative) explanation of the pieces specified here, and [current-scope.md](current-scope.md) is the concise ledger of the exact current scope, result meanings, trusted components, and non-claims. Where this document names an exact supported shape, exit code, or non-claim, that ledger is canonical.

The implemented slice of this architecture is: the four frontend boundaries (`mithril validate FILE`); the contract renderer (`mithril contract FILE`); one deliberately narrow verifier slice (`mithril verify FILE`), which connects exactly one selected NoSelfPrivilegeEscalation obligation, whose every case matches one of two exact structural rules, to an Agda-checked proof through deterministic generation and a process boundary; and one confined Wasp target adapter (`mithril wasp generate|check`), which lowers exactly the singleton rule-1 form of that verified obligation (Wasp Confinement Profile v0) and exactly its ordered rule-1, rule-2 case pair (Wasp Confinement Profile v1) into closed, checked Wasp 0.25.0/PostgreSQL application profiles. Everything else after the frontend (general Agda generation and checking, general target emission, and every other form of verification) is unbuilt. [Implementation status](#implementation-status) states what exists.

## Purpose

Mithril's toolchain is designed to turn one authored access-control model (a Mithril Core v0 JSON document) into three coordinated derived artifacts: a deterministic text security contract for review, an application-specific Agda model whose selected proof obligations the Agda toolchain checks, and executable enforcement for a target framework, with [Wasp](https://wasp.sh/) first. The contract a human reviews, the model Agda checks, and the code that executes all derive deterministically from the same typed normalized reading of the same document, never from independent interpretations of it. This shared-source arrangement does not by itself prove semantic correspondence between Core and either backend.

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

One deterministic host tool, implemented in Haskell, contains the CLI, the frontend stages, the contract renderer, and the backend emitters.

| Component | Responsibility |
|---|---|
| [`core/schema.json`](../core/schema.json) | Normative external JSON shape of a Core v0 document; structural authority only. Authored and versioned, not part of the host tool. |
| Haskell frontend | Parsing, draft 2020-12 structural validation, name resolution, static typing, normalization. The sole producer of typed normalized Core. |
| contract renderer | Deterministic rendering of the typed normalized Core as a line-oriented text security contract for review. Its human-facing presentation is provisional. |
| Agda backend | Deterministic generation of the application-specific Agda model and proof obligations from the typed normalized Core, targeting the authored generic Agda kernel. Checking is performed by the Agda toolchain across a process boundary. |
| target emitter | Deterministic generation of target-specific enforcement from the typed normalized Core, through a target adapter. Wasp is the first target, implemented as the Wasp Confinement Profiles v0 and v1 of the one verified obligation (`mithril wasp generate|check`). |

### One frontend, one normalized Core

There is one Mithril JSON parser/frontend, not one parser per backend. JSON Schema validation establishes structural validity only; name uniqueness, reference resolution, static typing, enum-order validation, endpoint compatibility, and similar semantic checks belong to the Haskell frontend. Contract generation, Agda generation, and executable enforcement must all consume the same typed normalized Core. Independent interpretations of the JSON for Agda and for Wasp are forbidden: a backend that re-parses or re-interprets the authored JSON bypasses the semantic stages and reintroduces exactly the divergence this architecture exists to prevent.

### Haskell boundary

Haskell is the implementation language of the deterministic host tool: the CLI, the frontend stages, the contract renderer, and the backend emitters. The scope of that decision is deliberately narrow:

- It does not make Haskell the proof backend. Agda remains a separate formal backend/checker, reached through generated files and a process boundary; Mithril does not import or depend on Agda compiler internals as a Haskell library.
- Advanced Haskell types enforce concrete pipeline invariants (for example, that emitters and the contract renderer accept only the `Normalized` stage); they do not recreate a second proof assistant inside the host tool.
- The toolchain is GHC 9.12.4, cabal-install 3.18.1.0, and the GHC2021 language edition. Packaging and distribution remain open.

The direct dependencies are part of the trusted computing base, each for a stated role:

- Aeson parses JSON.
- The native Haskell `jsonschema` package, pinned exactly to 0.3.0.1, is the provisional JSON Schema backend, and `regex-tdfa`, its regex engine, is a direct dependency of the schema-profile gate. The backend is trusted only for an explicitly gated schema profile: the exact draft 2020-12 `$schema` URI, a closed keyword inventory, local unescaped `#` references only, annotation-only `$ref` siblings; no external references or anchors, no `unevaluated*` or dynamic references; regex semantics inherited from the backend rather than guaranteed ECMA-262. The gate compiles every `pattern` with that same engine at load time, so an uncompilable pattern is a schema-load failure rather than a validation-time exception. Schema loading fails closed outside that profile, and no complete Draft 2020-12 implementation is claimed.
- `containers`, a GHC boot library, provides the resolver's deterministic ordered maps and sets. The GHC boot libraries `directory`, `filepath`, and `process` sit behind the verifier's isolated-workspace and process boundary. `unix` provides the no-follow filesystem metadata and link counts behind the Wasp filesystem boundary.

The canonical `core/schema.json`, the single authoritative source for the external Core v0 JSON grammar, is compiled into the host tool at build time (embedded via Template Haskell, with the file registered as a build dependency so edits trigger recompilation) and is the only schema the public validation API can use: no runtime file lookup or environment override, in particular the Cabal `mithril_ir_datadir` package-data variable, can substitute the grammar that confers structural validity. The trusted Agda kernel modules are embedded the same way, so no runtime lookup can substitute the kernel the verifier materializes. This is provenance by construction, not a cryptographic-integrity or formal-verification claim.

### Schema and resolver evolution

The frontend's one interpretation of the current Core v0 schema is complete: the internal schema decoder that turns structurally valid JSON into the explicit surface syntax, the decoded and resolved representation types that mirror every construct, the `Mithril.Core.Resolution` pass over them, the static-typing pass (`Mithril.Core.Internal.Typecheck`, exposed through `Mithril.Core.Typing`), the normalization pass (`Mithril.Core.Internal.Normalize`, exposed through `Mithril.Core.Normalization`) with the explicit normalized representation it constructs, and the contract-rendering pass (`Mithril.Core.Internal.Contract`, exposed through `Mithril.Core.Contract`). Keeping schema and frontend evolution aligned is nevertheless a manually reviewed contract. Template Haskell's `addDependentFile` registration and the resulting recompilation detect that the bytes of `core/schema.json` changed; they do not establish decoder, representation, resolver, typechecker, normalizer, or renderer completeness. A schema change is therefore not complete merely because structural validation and compilation pass.

Any change to `core/schema.json` that affects declaration namespaces; reference-bearing fields; term, policy, effect, result, or guarantee constructors; enum-value uniqueness or order assumptions; the distinguished `User` entity requirement; or any structural invariant on which the frontend relies for totality or no-cascade behavior must include, in the same change, an explicit audit that identifies every added, removed, or changed constructor and reference location and demonstrates that:

- the schema decoder and the representation carry it;
- resolution either traverses it or deliberately does not treat it as a name;
- the typechecker either assigns it a typing judgment or deliberately has nothing to check for it (the typechecker's module documentation and the typing test module's audit table record that decision per construct);
- the normalizer and the normalized representation carry it into the typed normalized model;
- the contract renderer gives it an explicit rendering branch (the contract test module's consumption matrix and the frozen golden contracts pin every current family's exact site counts, so a new family cannot pass unexercised; updating them is part of the audit);
- positive, unknown-reference, duplicate/ambiguity, well-typed/ill-typed, no-cascade, and invariant-drift regressions are added wherever the schema change makes them relevant.

This audit is mandatory review-and-test discipline, not an automated completeness check; do not introduce a second copy of the schema or claim that recompilation automates it.

## Internal representations and stage discipline

The frontend's internal representations and stage indexes are part of the architecture, because they are what keeps every backend on the one interpretation of the document:

- **Explicit representations, not JSON.** Generic Aeson `Value` ends at the internal decode boundary. A `Resolved` document carries an explicit decoded and name-resolved Core model in which every Core v0 construct of `core/schema.json` is an explicit node, every resolved reference carries a namespace-specific internal identifier (owner-local identifiers embed their owner) rather than a textual name, declaration names are diagnostic metadata only, and every node retains its originating JSON path, so later stages diagnose at the authored location without rereading JSON. The typed normalized Core is a distinct model built from the typed document, not the resolved model under another stage tag. Structurally established facts are encoded in the types: the actor-free term, effect, and result families of `AnyPrincipal` actions cannot contain an `Actor`, the two principal modes carry their distinct allow shapes, and only the structurally permitted classification/effect/result combinations are representable.
- **Stage indexes gate every boundary.** Documents are opaque values indexed by stage, so a later stage cannot accept merely parsed input as validated, merely validated input as resolved, merely resolved input as typed, or merely typed input as normalized; the contract renderer, the verifier, and the Wasp emitter accept only `Normalized`. Each stage attests exactly its own fact: `Resolved` attests names only, `Typed` attests static well-typedness only, and `Normalized` attests deterministic structural normalization only. None of them is policy evaluation, guarantee truth, or verification.
- **One statement of each judgment.** The typechecker owns the Core v0 typing judgment and exposes a shared type-query facility that the normalizer reuses; the normalizer restates no inference rule, and no backend reruns type inference. The shared NoSelfPrivilegeEscalation support gate (`Mithril.Core.Internal.NspeSupportPlan`) is the single statement of the supported-shape classification, consumed unchanged by the Agda generator and the Wasp emitter, so both refuse the same documents for the same reasons.
- **The distinguished `User` entity is selected once.** The resolver designates it by its schema-designated name in the same entity-namespace lookup that resolves every `Actor` term and records the identity in the resolved model; the typechecker validates that stored identity against the declaration it names and carries it in its signature; the normalizer propagates it (`modelUserEntity`). Backends check subject and `Actor` evidence against that independently carried identity rather than re-deriving it from an authored name, a declaration position, or the evidence under check. This is what makes coherently redirected subject evidence detectable as an invariant violation instead of a consistent-looking obligation.
- **Encapsulation.** The representations, the support gate, the verifier's generator and orchestration, the Wasp emitter, the confinement checker, and the Wasp filesystem boundary live in a package-private sublibrary, an internal testability and encapsulation mechanism rather than a packaging decision. External code cannot import them, construct nodes, mint or coerce identifiers, extract a raw JSON value from a document, or coerce one stage into another, and the identifier namespaces are distinct data types, so even in-package code cannot coerce one namespace into another. The downstream and in-package compile-fail probes pin this boundary, while the package's own test suite uses the sublibrary to white-box-inspect the real models the production pipeline constructs.
- **Failure classification.** Problems in the user's document (parse, structural, name, and type errors) are reported deterministically at JSON-pointer locations, sorted and deduplicated, with dependent errors suppressed rather than cascaded, and exit with status 1. Shapes a stage cannot interpret after the previous stage succeeded indicate frontend drift or a bug, never a user error: they are internal invariant violations, kept apart from user errors, dominating them, and exiting with status 2. Normalization and contract rendering have no user-error class at all.
- **Determinism.** Every derived artifact depends only on the document's content, never on its filesystem path, time, or environment. Determinism is not correctness.

The exact judgments, diagnostics, and invariants of each stage are documented in the corresponding modules (`Mithril.Core.Resolution`, `Mithril.Core.Internal.Typecheck`, `Mithril.Core.Internal.Normalized`, `Mithril.Core.Internal.Contract`, `Mithril.Core.Verification`, `Mithril.Core.Wasp`).

## LLM boundary

- An LLM is optional. A human may author or edit Mithril JSON directly.
- An LLM may propose changes only up to the authored Core document. No LLM participates in JSON-to-Agda generation, contract rendering, normalization, or target code generation.
- Everything downstream of the authored Core document is deterministic and reproducible.
- The LLM is untrusted. Human review of the generated text contract mitigates mistranslation of intent, but it cannot prove the human's original intent: a deterministic pipeline faithfully applied to a mis-stated model still enforces the wrong policy.

## Authored, derived, and trusted artifacts

### Authored and versioned

Authored artifacts are written by humans (or proposed by an LLM and accepted by a human), live in version control, and are the only place corrections are made:

- Mithril JSON models, written by a human or proposed by an LLM: the handwritten example [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json) and the regression fixtures under `test/fixtures/`;
- [`core/schema.json`](../core/schema.json);
- the generic Agda kernel/semantics modules: the five embedded fixed-schema kernel modules under [`agda/`](../agda/README.md), beside which the `Mithril.Spike` and `Mithril.Acme` experiments are authored but stay outside the verifier kernel;
- the Haskell host tool implementation: the frontend, contract renderer, single-obligation verifier slice, the confined Wasp emitter and confinement checker, and the general target emitters once they exist;
- target runtime support, templates, and adapters: the templates of the two Wasp Confinement Profiles inside the emitter (a trusted component, with the confinement checker and filesystem installation shared by both profiles), and the general adapters once they exist;
- ordinary application UI and business logic outside the Mithril-generated boundary.

### Derived

Derived artifacts are produced deterministically by the host tool for a particular build:

- the typed normalized Core for that build;
- the text security contract for human review, rendered on demand by `mithril contract FILE`;
- the application-specific Agda model and proof obligations, and proof terms where the backend supports producing them: the verifier's obligation module, generated on demand by `mithril verify FILE` into a fresh isolated temporary workspace;
- target-specific generated enforcement: the Wasp Confinement Profile v0 or v1 bundle of the verified obligation, installed as a complete root by `mithril wasp generate CORE_FILE WASP_ROOT` and checked by `mithril wasp check`;
- separate generation-metadata or provenance manifests: the Wasp bundle's deterministic `mithril.manifest.json` (the generated Agda obligation module carries its own Agda-checked in-module theorem manifest instead).

**Derived files must never be hand-edited.** If an output is wrong, the authored input or the generator is corrected and the artifact regenerated ([`AGENTS.md`](../AGENTS.md), hard rule 7). No derived artifact is stored in the repository as a build product. The byte-frozen copies under `test/fixtures/` (the golden contracts, `nspe.generated.agda`, `nspe-self-update.generated.agda`, and the generated Wasp fixtures `wasp-acme` and `wasp-acme-self-update`) are committed test expectations that pin the exact outputs; correcting one means correcting the authored model or the generator and regenerating. Nothing else is generated: the `Mithril.Acme` proof slice is hand-transcribed authored Agda ([`agda/README.md`](../agda/README.md)), not derived from the JSON example; no tool checks that transcription against the JSON, and generated modules never import it. Generated modules target the trusted kernel modules the host tool embeds at compile time.

### Trusted computing base

Determinism is not itself correctness: a deterministic pipeline reproducibly delivers whatever its trusted components produce, including their bugs. The trusted computing base includes, as applicable to the deployment in question:

- the Haskell frontend and emitters, including the contract renderer and the verifier's support gate, generator, and checker boundary, together with the direct dependencies listed under [Haskell boundary](#haskell-boundary), each trusted for exactly the role stated there;
- the generic Agda model that generated obligations target: the five embedded kernel modules (`Mithril.Base`, `Core`, `Policy`, `Effect`, `Guarantee`) and the two support rules themselves;
- the Agda toolchain: the verifier requires exactly Agda 2.8.0 and treats every other version as a tool failure;
- the target adapter and runtime: the Wasp emitter's templates and lowering and the confinement checker;
- Wasp 0.25.0, Node, Prisma, and PostgreSQL for the Wasp target;
- the relevant platform components beneath them.

A defect in any of these can invalidate a verification claim without any change to the authored model. [`SECURITY.md`](../SECURITY.md) governs how verification claims are scoped to documented properties and documented assumptions, and [current-scope.md](current-scope.md#trusted-components) keeps the canonical list.

### Verification gates

Generated code must not be called verified merely because it was generated, and a deterministic pipeline confers no verified status by itself. A verified status for a given build requires the relevant gates to pass:

1. structural validation against `core/schema.json` and the frontend's semantic checks;
2. human review of the rendered security contract, the mitigation for mistranslated intent;
3. successful Agda checking of the generated proof obligations for the selected guarantees;
4. for executable claims, the target adapter's documented correspondence between abstract Core semantics and the generated enforcement (see [Future backend model](#future-backend-model)).

Even then, the claim covers exactly the selected properties under the stated trusted-computing-base assumptions. It never covers general application security or semantic-preservation properties that have not themselves been proved.

## Wasp target boundary

[Wasp](https://wasp.sh/) is the first executable target, not Mithril's product boundary and not a permanent dependency of Core:

- Wasp remains involved throughout application development and compilation. It is the full-stack framework the application actually uses, not a one-time scaffolder Mithril runs once and abandons.
- The implemented profiles emit normal Wasp inputs that a standard, unmodified Wasp compiler accepts. Future Wasp emitters must do the same; modifying the Wasp compiler is out of scope.
- Mithril is not a replacement full-stack framework. Humans or coding agents continue to write the UI and ordinary business logic.
- Within the two implemented profiles, Mithril generates the complete security-sensitive operation and enforcement boundary, not optional authorization helpers that application code can forget to call. Future target work must preserve that boundary within its documented scope.
- The two implemented profiles are deliberately minimized end-to-end demonstrations and generate complete minimal backends. This is a property of the small demonstrators, not a general claim: Mithril does not generate every part of real applications.
- Exact generated filenames and the final adapter API for any backend beyond the two implemented profiles remain deferred. The Wasp Confinement Profiles v0 and v1 freeze exactly their common fourteen managed paths, their manifests, and their public boundary for those two plan shapes and nothing more; general or additional adapter formats remain open.

### The Wasp Confinement Profiles v0 and v1

`mithril wasp generate CORE_FILE WASP_ROOT` and `mithril wasp check CORE_FILE WASP_ROOT` (`Mithril.Command.Wasp`, over the public `Mithril.Core.Wasp.renderWaspBundle` boundary, which accepts exactly a normalized document) run the complete validate pipeline, require the production verifier to report the document VERIFIED, and dispatch over the ordered rule tags of the shared support plan. The dispatcher reads the tagged case collection, never re-deriving a rule and never inspecting the normalized model: exactly `[rule 1]` selects Profile v0, exactly `[rule 1, rule 2]` in authored order selects Profile v1, and every other sequence is refused with deterministic source-anchored reasons (exit 3) before any lowering and therefore before any destination is resolved, inspected, staged, backed up, or written. Arbitrary multi-case lowering is not implemented, so a VERIFIED document may still be Wasp-UNSUPPORTED; [current-scope.md](current-scope.md#wasp-profile-dispatch-exact) is the canonical dispatch table.

**Lowering.** The emitter has no lowering rule of its own: it consumes the shared plan (`Mithril.Core.Internal.NspeSupportPlan`, the single statement of the supported-shape classification with its identity preflight, per-case rule tags, and resolved metadata) and lowers it into a normal Wasp 0.25.0 application on PostgreSQL. Every Prisma model, enum, value, and field name, every TypeScript identifier, every Wasp operation and route, and every managed path is a fixed target name derived from the role a declaration plays in the supported shape or, for enum values, from the canonical declaration position of the value's identity, never an authored name. Consequently no authored name can collide with a Prisma scalar type, a Wasp auth model, a TypeScript keyword, or another target name; the fourteen-file inventory is the same for every supported document and for both profiles; and renaming a declaration or an action changes only metadata. Authored names survive only as escaped comment and string metadata and in the manifest's explicit authored-to-target mapping. The ranking facts the emitter uses are read from the shared plan, the only ranking authority; the emitter scans, classifies, and defaults nothing. The selected profile is an explicit identity carried by the bundle, its summary, its ownership marker, its manifest, and the CLI report, never inferred from an operation count. The pure renderer establishes supported-shape lowering only; VERIFIED provenance belongs to the CLI generation path, which requires the verifier's VERIFIED before rendering and states so in its report.

**What the profile owns.** The generated profile owns every server-capable or security-sensitive input of the application: the Wasp specification (username-and-password auth, one route and page, exactly the profile's authenticated Actions), the Prisma schema (the subject and scope entities, the authority relation with a composite identity over its endpoint fields and the authority enum as its payload column), the one generated TypeScript operation file exporting every Action of the profile, the dependency, TypeScript, and Vite configuration, the root-marker and ignore files, the profile's fixed-bytes ownership marker, a minimal static client shell, and the deterministic manifest (format version 0 for Profile v0; format version 1 for Profile v1, with the explicit profile and the complete ordered case-to-operation mapping). The bytes depend on the document's content and the selected profile alone; the paths depend on nothing. `Mithril.Core.Internal.Wasp` documents the exact inventory.

The adapter obligations of the [Future backend model](#future-backend-model) are met as follows for these two slices, and only for them:

| Adapter obligation | Wasp Confinement Profiles v0 and v1 |
|---|---|
| authenticated-principal input | Wasp's own username-and-password authentication and bearer session; every Action requires Wasp authentication and uses `context.user.id` as its only identity (401 otherwise). For the rule-2 Action the authenticated user is also the subject of the write, and no caller-supplied subject argument exists. |
| data-access boundary | The Prisma runtime supplied by Wasp, reached only through `prisma` from `wasp/server` inside the generated operation file; every authorization read and the `SetRelation` update of an Action happen inside one Prisma interactive transaction (no authorization/write TOCTOU). |
| atomicity assumptions | PostgreSQL `Serializable` isolation for that transaction, with a fixed three-attempt retry of Prisma `P2034` serialization conflicts (409 afterwards). Concurrent conflicting requests, of one Action and of the rule-1 and rule-2 Actions against each other, admit only outcomes consistent with a serial execution, which the integration battery pins. |
| supported operations | Exactly the two supported plan shapes, after the CLI path has required the document VERIFIED. The rule-1 Action validates its arguments (400), requires the actor's materialized rank to reach the privilege floor, the actor to differ from the subject, and the subject's tuple to exist (one uniform 403 for every denial, leaking no existence information), then updates the payload. The rule-2 Action (Profile v1) takes exactly the scope and payload arguments (400), reads the actor's own tuple with the shared absent rank when it is missing, authorizes exactly when `payloadRank <= actorRank` (no separate membership condition; one uniform 403 for every denial), then updates exactly that tuple. The finite role ranking is the materialized enum ranking of the normalized Core and nothing else. Every other case sequence is verified by the Agda backend but not lowered. |
| bypass prevention | The closed profile and `mithril wasp check`: the regenerated closed path inventory plus exact bytes of the selected profile is the authority (a valid root of the other profile is not confined, its marker named); the checker validates the snapshot itself (no duplicate, aliased, absolute, or dot-relative entry), walks the complete source root without following symbolic links, rejects hard-linked files, and rejects every missing, altered, or unexpected input, with a denylist scan that only labels bypasses (a second spec or server file, another operation, API, CRUD, job, seed, server setup, or middleware path, `prisma` outside the generated operation file, another database library, raw SQL, dynamic code, dependency or provider drift, links and path escapes, migrations and build outputs). This is source-root confinement, not a runtime sandbox. |

**Confinement claim.** The claim is exactly that the source root the checker walked was, at the time of checking or generation, a valid clean source snapshot: the regenerated closed path inventory with byte-identical, privately linked managed files and nothing else. The validation is path-based, not descriptor-relative, and the private 0700 staging and root directories keep other unprivileged users out and nothing more. Outside the claim, unless separately prevented: malicious concurrent same-user mutation after the final check, privileged users and malicious same-user processes in general, malicious changes to the checker or the CI that runs it, compromise of the Wasp, Node, Prisma, or PostgreSQL dependencies, external processes holding the database credentials, and any tampering after `wasp build`. Wasp 0.25.0, Node, Prisma, PostgreSQL, the templates, and the lowering are trusted; no semantic-preservation theorem between the Core semantics and the generated TypeScript exists, so a rendered bundle is trusted correspondence evidence, not a proof; and the profiles are deliberately closed demonstrators, not a general Wasp backend, not arbitrary multi-case lowering, not a whole-product generator, not a complete verifier, and not a runtime sandbox.

**Installation.** `generate` installs the bundle as a complete root, never file by file. An absent or empty destination is initialized. A nonempty destination is replaced as a whole only when it carries one of the two byte-exact ownership markers (replacement ownership recognizes exactly these two literal markers over the common inventory and parses nothing, so an owned root of either profile transitions to the requested profile as a whole, with every stale byte of the previous profile removed) and nothing outside the fixed inventory; altered or missing managed files are recovered by the replacement. An unmarked nonempty root, a root with an altered or unknown marker, or any unmanaged path refuses the command without mutation. The new bundle is written to a sibling staging directory created atomically with the private permission bits 0700 (the installed root is that same directory and keeps the mode whatever the umask), checked there, and swapped into place by whole-directory renames after the destination and its ancestors are revalidated and the backup path is confirmed absent a second time, with the previous root moved to a sibling backup that is restored if the swap fails and removed only after the new root is installed. Every failure therefore leaves the complete old or the complete new root, and any directory left behind is named. Root paths are accepted lexically (an empty, `.`, or `..` component, including a trailing separator, is refused, never normalized; `/` alone is the filesystem root and refused as such), joined to the working directory, and every ancestor and the root itself are inspected with no-follow metadata (the `unix` package; Linux is the exercised platform): an ancestor or root that is a symbolic link or not a directory refuses the command, and so does an existing entry of any kind at the backup sibling path `WASP_ROOT.mithril-wasp-backup`, which is never removed, replaced, or followed. `Mithril.Core.Internal.WaspFilesystem` states the exact sequence.

**Wasp never runs in the repository.** Installation, build, migration, and environment outputs (`node_modules`, `.wasp`, `package-lock.json`, migrations, environment files) are outside every profile and never become authored repository inputs; Wasp runs only in the integration harness's private working directories. The committed fixtures `test/fixtures/wasp-acme` (Profile v0) and `test/fixtures/wasp-acme-self-update` (Profile v1) are the golden outputs of the generator, pinned byte-for-byte by the test suite and CI. The separate Wasp 0.25.0 / PostgreSQL integration battery (`test/wasp-integration/`, with its own stub-driven self-tests) generates both profiles into private roots, compares them with the committed fixtures, installs, compiles, and builds each freshly generated root (and every committed rename variant under `test/fixtures/wasp-renames`), and exercises the generated Actions through Wasp's real HTTP and authentication path in a separate pinned CI job: the authentication, argument-validation, and authorization answers with the authority relation unchanged on every denial, the allowed paths, the serialization-conflict retry and fault answers, and barrier-proven concurrency admitting only serial outcomes within each Action and across the rule-1 and rule-2 Actions. The battery's direct database access and the temporary triggers it installs outside the confined root are test-only machinery outside the confinement claim.

## Future backend model

Future execution environments require target-specific emitters/adapters, not new Mithril parsers. Every target consumes the same typed normalized Core from the same frontend.

Adapters are framework/execution-environment specific, not simply programming-language specific: a language name is not an adapter; a concrete framework and execution environment is. Each adapter must define:

| Adapter obligation | Question it answers |
|---|---|
| authenticated-principal input | How does the authenticated principal enter generated enforcement? |
| data-access boundary | Through which layer does generated enforcement read and write data? |
| atomicity assumptions | Which transactional guarantees does the environment provide, and which does generated code rely on? |
| supported operations | Which Core operations can this target execute faithfully? |
| bypass prevention | How is application code kept from reaching data or operations around the generated enforcement? |

A backend cannot receive a verification claim merely because the abstract Core verified. Correspondence between the verified abstract semantics and the target's executable enforcement remains necessary, per adapter; it is claimed explicitly or not at all.

## Implementation status

The implemented boundaries are the four frontend stages (`mithril validate FILE`), the contract renderer (`mithril contract FILE`), the single-obligation verifier slice (`mithril verify FILE`), and the confined Wasp target adapter with its two closed profiles (`mithril wasp generate|check`). [current-scope.md](current-scope.md) is the exact ledger of commands, supported shapes, result meanings, exit codes, trusted components, and non-claims; this section records only how the architecture's boundaries look as built.

Authored and version-controlled components:

- [`core/schema.json`](../core/schema.json): the normative Core v0 external JSON shape, compiled into the tool at build time (never installed or read as runtime package data);
- [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json): a handwritten, unverified example model, which passes structural validation, name resolution, static typing, and normalization but selects guarantees the verifier does not support;
- the five embedded fixed-schema Agda kernel modules under [`agda/`](../agda/README.md), together with the experiments outside that kernel: `Mithril.Spike` and the hand-transcribed `Mithril.Acme` slice (one checked NoSelfPrivilegeEscalation case for the Acme `Membership.changeRole` action, with a checked unsafe-variant counterexample);
- the Haskell host tool: the Cabal package `mithril-ir` building the `mithril` CLI, with unit tests (including the byte-frozen golden contracts, generated Agda modules, and Wasp bundles), process-level CLI regression tests over the built executable, downstream and in-package API-boundary compile-fail probes, and the pinned Haskell CI workflow;
- this document.

The verifier slice, as built: `Mithril.Core.Verification.verifyCoreDocument` accepts exactly a normalized document (pinned by a downstream compile-fail probe) and decides, first and purely, whether it lies inside the support rule of [current-scope.md](current-scope.md#supported-verifier-slice-exact), with the subject entity anchored to the normalized model's independently carried distinguished-`User` identity, so subject, parameter-type, and `Actor` evidence redirected coherently to another entity is a verifier-invariant violation (never UNSUPPORTED, never VERIFIED, no checker launched, no Wasp lowering). For a supported document it deterministically generates one Agda obligation module from the normalized evidence (fixed module and theorem names; document names appear only escaped inside line comments; one complete proof group per case, each with an Agda-checked theorem manifest, so the checker's acceptance itself proves that every required theorem of every case exists at exactly its required type and no source text is ever searched for theorem names), checks the plan-derived required-theorem inventory, materializes the module together with the embedded kernel modules into a fresh isolated temporary workspace (never the repository, the working directory, or an environment-selected location; cleaned on every path, with no stale interfaces), and invokes exactly Agda 2.8.0 with `--safe --no-libraries --ignore-interfaces` across a process boundary; no Agda compiler internals are imported, and no kernel module, postulate, or unsafe feature is involved. VERIFIED means every required theorem of every selected case was accepted, and the result and report record every case with its position, rule, action, and checked theorems; UNSUPPORTED is decided by the pure gate before any checker runs, with non-empty deterministic reasons (a document selecting no guarantees is unsupported, never vacuously verified); every checker problem after gate acceptance is a tool failure (exit 2), never a semantic verdict; and no `VIOLATED` outcome exists. Input failures keep `validate`'s diagnostics and exit classification byte-identically.

Not implemented:

- any complete verifier: no policy evaluation, no semantic diff, no general proof search or proof checking from Core, no TenantIsolation or AuthenticatedMutation verification, no counterexample or witness generation, no refusal or warning about unselected authority writers, and no verification of any obligation shape beyond the two supported NoSelfPrivilegeEscalation case rules; every other normalized document's guarantees are selected proof obligations, established by nothing, and the rendered contract does not change that;
- any general JSON-to-Agda generation: the generator emits exactly the one supported obligation module, and the `Mithril.Acme` slice remains hand-transcribed, not derived from the JSON example;
- any Wasp generation beyond the two confined profiles, including arbitrary multi-case lowering; no other target generation, correspondence or semantic-preservation proof, confinement beyond the source-snapshot profile check, runtime enforcement, or runtime sandbox;
- any separate generation-metadata artifact beyond the Wasp bundles' `mithril.manifest.json`: the rendered contract, the generated obligation module, and the Wasp bundle are the only derived artifacts.

Known limitations of the implemented boundaries (deliberate, unresolved): duplicate JSON object members are not rejected (Aeson member semantics, a provisional gap, not a desired contract), and no input-size or resource limits are enforced. The validation backend is trusted only within the gated schema profile described under [Haskell boundary](#haskell-boundary). [current-scope.md](current-scope.md#known-unresolved-boundaries) keeps the canonical list.

## Explicit non-claims

This document makes design commitments, not correctness claims. [current-scope.md](current-scope.md#explicit-non-claims) is the canonical non-claim ledger; at the architecture level:

- It claims implementation only for the four frontend boundaries, the contract renderer, the single-obligation verifier slice, and the two confined Wasp profiles of that same obligation. There is no general Agda backend, general target emitter, or complete verifier, including no policy evaluator, semantic diff, general proof search, runtime sandbox, or runtime enforcement beyond the closed demonstrators. A verified outcome covers exactly the selected cases of one supported obligation of one document under the stated trusted components; an unsupported outcome, including the canonical Acme document's and the dangerous counterexample's, establishes nothing, and no violation outcome exists.
- A structurally valid document is not typed normalized Core. Structural validation establishes JSON shape conformance to the gated schema profile only; it is not name resolution, not typing, not normalization, not semantic well-formedness, not guarantee truth, and not verification of the Acme model or any application.
- A resolved document is likewise not typed normalized Core. Name resolution establishes declaration-name uniqueness and reference existence only; it is not static typing, not semantic well-formedness, not guarantee truth, and not formal verification of anything.
- A typed document is still not typed *normalized* Core, and static typing is not semantics. The typechecker establishes exactly the static judgments documented in `Mithril.Core.Internal.Typecheck`; it evaluates no policy, normalizes nothing, establishes no guarantee, and verifies nothing; selecting a guarantee in a well-typed document still only selects a proof obligation.
- A normalized document is typed normalized Core and nothing more. Normalization is deterministic structural canonicalization of one authored document: it performs no boolean simplification, constant folding, operand reordering, policy evaluation, proof checking, or semantic optimization, and it claims no alpha-equivalence or canonical equality between differently authored documents; two documents that mean the same thing may normalize to different models. Producing typed normalized Core evaluates no policy, establishes no guarantee, and verifies nothing; its consumers are the contract renderer, the single-obligation verifier slice, and the confined Wasp emitter, and no complete verifier, semantic diff, general target backend, or second adapter consumes it.
- A rendered security contract is a deterministic restatement of one normalized document and nothing more. It exists so a human can review what was authored; it is not a semantic diff of two documents or revisions, not policy evaluation, not proof generation or checking, and not enforcement, and rendering it establishes nothing; the guarantees it lists are printed as, and remain, unverified proof obligations. Core v0 has no authored assumptions field, and the contract invents none.
- The structural-validation backend (`jsonschema 0.3.0.1`) is provisional and gated: only the supported schema profile is accepted, and no complete Draft 2020-12 implementation is claimed. Duplicate JSON member rejection and input/resource limits remain unresolved gaps of the implemented boundary. Packaging and distribution remain open. The Wasp Confinement Profiles v0 and v1 freeze, for their two slices and pinned by tests, their common fourteen generated filenames, their profile-internal `mithril.manifest.json` (format versions 0 and 1), their adapter surface (`Mithril.Core.Wasp`), and their managed inventory; the general adapter API, the generated layout of any wider backend, and any future general artifact or sidecar manifest format (a different thing from that profile-internal manifest) remain open, as does every other adapter and profile evolution.
- Byte-determinism of the implemented stages is demonstrated, not merely intended: the contract renderer, the verifier's generated Agda modules (the singleton rule-1 and the two-case goldens), and the Profile-v0 and Profile-v1 Wasp bundles are pinned byte-for-byte by golden fixtures and by fixture-equality and regeneration tests for supported inputs. Reproducibility of anything not yet built remains design intent; determinism is still not correctness.
- Generated code is not called verified merely because it was generated; a verified status requires the gates in [Verification gates](#verification-gates).
- Neither [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json) nor the complete Acme model is verified. The hand-transcribed `Mithril.Acme` proof slice covers a single action and a single selected guarantee case and is not the connected generated slice; the verifier separately generates and checks its own artifact for exactly one supported obligation of a supported document, and the canonical Acme document is not such a document.
- No semantic-preservation result between Core and any target exists, and this document promises none: the implemented Wasp profiles document their correspondence per the adapter table (trusted correspondence evidence) and prove nothing about it; executable-correspondence claims are made per adapter or not at all. The Wasp confinement claim covers exactly the source snapshot the checker walked at the time of checking or generation (hard-linked inputs rejected): Wasp, Node, Prisma, PostgreSQL, the templates, and the lowering are trusted, and malicious concurrent same-user mutation after the final check, malicious checker or CI changes, dependency compromise, external processes holding database credentials, and tampering after the Wasp build are not confined. The pure Wasp renderer establishes supported-shape lowering, not VERIFIED provenance; only the CLI generation path, which requires the production verifier's VERIFIED before rendering, states it.
- Mithril does not claim, and will not claim, general application security. The non-guarantees in the [README](../README.md#trust-and-limitations) and the claim-scoping rules in [`SECURITY.md`](../SECURITY.md) apply unchanged.
- The LLM translation step is untrusted and outside every verification claim; contract review mitigates, but cannot prove, fidelity to the human's original intent.
