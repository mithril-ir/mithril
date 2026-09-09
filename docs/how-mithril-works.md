# How Mithril works

This is an accessible but technically serious tour of Mithril for
someone who knows programming but not necessarily Haskell, Agda, type
theory, or compilers. It explains what each piece is, what it
establishes, and — just as important — what it does not.

The exact scope ledger lives in [current-scope.md](current-scope.md).
The authoritative pipeline specification is
[compiler-architecture.md](compiler-architecture.md).

## Is Mithril a compiler, a DSL, or an IR?

All three names appear in the documentation, and they refer to
different parts:

- **Mithril Core** is a small authorization DSL: entities, enums,
  relations, actions with allow policies and effects, and guarantee
  selections. It is represented externally as JSON and used as an IR —
  a document you author (or an untrusted LLM proposes) rather than a
  language you type programs in.
- **The Haskell program** (`mithril`, Cabal package `mithril-ir`) is
  the compiler/toolchain: it reads a Core document and produces the
  derived artifacts.
- Mithril as a whole is best described as *an experimental
  verification-oriented compiler toolchain for a small authorization
  DSL/IR*.

The design commitment: a human describes access-control intent, that
intent is captured as one authored Core JSON document, and everything
downstream derives from that document deterministically. An LLM may
propose the authored JSON, but no LLM participates downstream in the
deterministic compiler path.

## Repository map

| Path | Contents |
|---|---|
| `core/schema.json` | The normative JSON Schema (draft 2020-12) for the external shape of a Core v0 document. |
| `examples/acme/` | The handwritten canonical Acme example model (human-facing authored example). |
| `src/`, `src-internal/`, `app/` | The Haskell host tool: CLI, frontend, contract renderer, verifier, Wasp emitter. `src-internal/` is a package-private sublibrary holding the internal representations. |
| `agda/Mithril/` | The handwritten embedded Agda kernel; five of its modules are the trusted kernel embedded into the tool (see [`agda/README.md`](../agda/README.md)). |
| `test/fixtures/` | Authored regression inputs and committed golden outputs (contracts, generated Agda modules, generated Wasp trees). |
| `test/api-probes/` | Compile-fail probes that pin the public API boundary. |
| `test/wasp-integration/` | The separate real Wasp/PostgreSQL integration harness. |
| `docs/` | This document, the scope ledger, and the compiler architecture. |

Two conventions worth knowing: `examples/` contains human-facing
authored examples, while `test/fixtures/` contains authored regression
inputs and committed golden outputs — golden outputs are never edited
by hand. Local experiments belong in `/tmp`, a Git-ignored path, or a
separate clone, never inside the repository tree.

## The frontend

There is exactly one frontend, and every backend consumes its output:

```text
parse -> structural validation -> resolution -> typecheck -> normalization
```

| Stage | Establishes |
|---|---|
| parse | The input is well-formed JSON (no trailing garbage). |
| structural validation | The JSON conforms to `core/schema.json`, which is compiled into the tool at build time — no runtime file or environment lookup can substitute the grammar. |
| resolution | Declaration names are unique per namespace and every name reference resolves to an existing declaration. |
| typecheck | Every term, policy, effect, result, and guarantee satisfies the Core v0 static-typing judgments. |
| normalization | The well-typed document becomes the *typed normalized Core*: terms stamped with their static types, enum orders materialized as explicit rankings, endpoint bindings made explicit, `CreateEntity` initializers in declaration order. |

Normalization is structural canonicalization, not policy evaluation: no
boolean simplification, no constant folding, no operand reordering, and
no claim that two differently authored but equivalent documents
normalize to the same model. It is also not a semantic diff.

The result is carried as an internal Haskell representation that
external code cannot construct or forge (more on that below). Contract
rendering, Agda generation, and Wasp generation all consume this same
typed normalized Core — none of them re-reads the JSON.

## What `core/schema.json` does and does not establish

The schema defines the structural JSON grammar of a Core v0 document:
required fields, closed constructor sets, which shapes may appear
where. Passing it establishes JSON shape conformance only. It is not
semantic correctness — name resolution, typing, and every deeper check
belong to the frontend stages — and it is certainly not proof. Any
standard draft 2020-12 validator can check the same structural
conformance.

## The contract renderer

`mithril contract FILE` renders the typed normalized Core as a
line-oriented, human-readable security contract: the entities, enums
(with materialized ranks), relations, actions (parameters, principal
mode, policies, effects, results), and the selected guarantees —
explicitly labelled *unverified proof obligations* — followed by a
fixed limitations section.

The contract is the human-review gate of the pipeline: it exists so a
person can read what was actually authored, in particular when an LLM
proposed the JSON. It is a deterministic review artifact, not a proof.
Rendering evaluates no policy, compares no two documents, and
establishes nothing.

## NSPE: the one verified property family

NSPE means **No Self Privilege Escalation**: no principal can use the
modeled operations to raise their own authority. Concretely, the
supported obligation is about an *authority relation* — for example, a
`Membership` relation from users to organizations carrying an ordered
role enum (`Member < Admin`).

The verifier currently recognizes exactly two structural proof rules:

- **Rule 1 — change-other**: an authenticated admin may change *another*
  user's role. The policy shape requires the actor to hold the top
  authority value, to be distinct from the subject, and the subject to
  already be a member. Because the actor never writes their own tuple,
  their own authority cannot increase.
- **Rule 2 — bounded-self-update**: an authenticated user may write
  *their own* tuple, but only to a payload bounded by their pre-state
  authority (`new role <= current role`). Self-demotion is possible;
  self-promotion is not.

The exact policy and effect shapes are in
[current-scope.md](current-scope.md#supported-verifier-slice-exact) —
they are matched structurally and exactly, so a semantically equivalent
but differently written policy is `UNSUPPORTED`. That is deliberate:
unsupported forms fail closed rather than being approximated.

## What `NspeSupportPlan` is

When the support gate accepts a document, it records *why* in
`NspeSupportPlan`, an internal Haskell IR: the validated authority
facts (relation, endpoints, the materialized two-value ranking with its
bottom, top, and absent rank) plus one rule-tagged plan per case, in
authored order. It is a *support witness* — the single statement of the
classification, consumed unchanged by both the Agda generator and the
Wasp emitter, so the two backends can never disagree about what was
accepted. It is not generated Haskell code, and it is not itself a
proof; the proof happens in Agda.

## What Haskell's type system establishes vs. what Agda proves

These are two different kinds of assurance:

- **Haskell's type system** enforces *pipeline invariants*. Documents
  carry an opaque stage index (`Parsed`, `StructurallyValid`,
  `Resolved`, `Typed`, `Normalized`), and the contract renderer,
  verifier, and Wasp emitter accept only `Normalized`. External code
  cannot construct a normalized document, coerce between stages, or
  import the internal representations — compile-fail probes under
  `test/api-probes/` pin all of this. This guarantees the pipeline
  cannot be bypassed *within Haskell's type discipline*; it proves
  nothing about authorization.
- **Agda proves the security theorems.** For a supported document, the
  tool generates a document-specific Agda module stating the NSPE
  theorems for each case against the generic kernel, and the Agda
  type checker verifies those proofs. That check — not the Haskell
  types, not the tests — is what `VERIFIED` reports.

## The kernel and the generated module

The handwritten Agda kernel (`agda/Mithril/`: `Base`, `Core`, `Policy`,
`Effect`, `Guarantee`) defines generic semantics and lemmas: states,
policies, effects, and what "no self privilege escalation" means. It is
authored, reviewed, and trusted.

The Haskell tool embeds the exact kernel sources at compile time and,
for a supported document, deterministically generates a
document-specific module, `Mithril/Generated.agda`, with one proof
group per case (for Rule 1: case-scope, actor-distinctness,
actor-authority-unchanged, and no-self-escalation theorems; for Rule 2:
case-scope, policy-bounds-payload, actor-authority-written, and
no-self-escalation theorems). No general proof search is implemented —
the generator instantiates the known proof shape for the two known
rules, and nothing else.

## The Agda checker boundary

The generated module and the kernel sources are materialized into a
fresh isolated temporary workspace and checked by the *external* Agda
2.8.0 executable with `--safe --no-libraries --ignore-interfaces`,
across a process boundary. The Haskell tool does not import Agda
compiler internals. Exactly version 2.8.0 is required; any other
version, a launch failure, or a nonzero check after the gate accepted
the document is a *tool failure* (exit 2), never a semantic outcome.

One honest limitation: no semantic-preservation theorem currently
proves that the Haskell frontend's reading of a Core document
corresponds to the generated Agda model. The generator, the embedded
kernel, and the support rules are trusted components of the `VERIFIED`
claim.

## What `VERIFIED` and `UNSUPPORTED` mean

- `VERIFIED` (exit 0): every required theorem of every selected case of
  the document's one selected obligation was accepted by Agda. Nothing
  else — no other guarantee, no other action, no unselected authority
  writer, and nothing about a running application.
- `UNSUPPORTED` (exit 3): the document lies outside the implemented
  support rules, with deterministic reasons anchored at the offending
  sites, decided before any checker runs. `UNSUPPORTED` is **not** a
  safety or violation verdict. The fixture
  `test/fixtures/acme-nspe-dangerous.mir.json` is a genuine
  self-promotion counterexample, and it is reported `UNSUPPORTED` — not
  "violated", because no general `VIOLATED` result or counterexample
  engine exists. A document selecting no guarantees is likewise
  unsupported, never vacuously verified.

## What golden tests establish

The test suite freezes the exact bytes of the rendered contracts, the
generated Agda modules, and the generated Wasp trees (the "golden"
files under `test/fixtures/`). Golden files protect deterministic
output and expose drift: if the generator changes, the diff is visible
and must be reviewed. They are not proofs — a golden file pins *what*
the tool produces, not that what it produces is correct.

## The Wasp profiles

[Wasp](https://wasp.sh/) is the first executable target. Two confined
profiles exist, dispatched over the verified case sequence:

- **Profile v0** accepts exactly `[Rule 1]` and generates one
  authenticated Action.
- **Profile v1** accepts exactly `[Rule 1, Rule 2]` in authored order
  and generates two authenticated Actions.

Every other verified case sequence is refused before any destination
access. Each profile is a closed 14-file demonstrator application: a
normal Wasp 0.25.0 application on PostgreSQL whose every
server-capable and security-sensitive input is a managed file
regenerated from the typed normalized Core and compared byte-for-byte.
The generated Actions require Wasp authentication, use
`context.user.id` as the only identity, run their authorization reads
and the single relation update inside one Prisma interactive
transaction at `Serializable` isolation, deny with one uniform 403, and
use no raw SQL.

## Closed-app confinement

`mithril wasp check` walks the complete source root (without following
symbolic links, rejecting hard links) and rejects every missing,
altered, or unexpected file. The authority is the regenerated closed
path inventory plus exact bytes; a denylist scan only labels *why* an
already-rejected file is dangerous. `mithril wasp generate` installs
the bundle as a complete root with staging, backup, and rollback, and
finishes with the same check.

What this buys: at the time of checking or generation, the source tree
is exactly the generated application — no smuggled second Action, no
extra server code, no dependency drift. What it does not buy: runtime
protection. Mutation after the check, tampering after `wasp build`,
compromised dependencies, and processes holding the database
credentials are all outside the claim (the full boundary is in
[current-scope.md](current-scope.md#wasp-profile-dispatch-exact)).

## The bypass problem, and the honest future path

Why closed applications at all? Because generating correct handlers
alone cannot establish whole-application security: an operation-level
claim ("this Action enforces this policy") is defeated by any manually
written server code that reads or writes the same tables around the
handler. A verified front door means little next to an unverified side
door.

The current profiles resolve this by owning the whole (deliberately
tiny) application, so the operation-level claim and the
whole-application claim coincide — at the cost of composability. The
current Wasp backend is not composable with arbitrary manually edited
pages or server code.

A future *composable adapter* — one that confines only the
security-sensitive boundary while letting humans write UI and ordinary
business logic around it — is plausible and is the intended direction
(see the [Wasp v1 boundary](compiler-architecture.md#wasp-v1-boundary)
and [future backend model](compiler-architecture.md#future-backend-model)
sections of the architecture). It is not implemented, and no partial
version of it exists.

Also honest: no semantic-preservation theorem proves that the generated
TypeScript corresponds to the Core semantics the Agda proof was about.
The correspondence is documented per the adapter obligations table and
trusted, not proved.

## Trusted computing base

Determinism is not correctness: a deterministic pipeline reproducibly
delivers whatever its trusted components produce, including their bugs.
The `VERIFIED` and `CONFINED` claims rest on the Haskell tool and its
pinned dependencies, the embedded Agda kernel and the two support
rules, the external Agda 2.8.0 toolchain, and — for the Wasp slice —
Wasp, Node, Prisma, PostgreSQL, the templates, and the lowering. The
full list is in
[current-scope.md](current-scope.md#trusted-components).

## Glossary

| Term | Meaning |
|---|---|
| Mithril Core | The small authorization DSL, authored as JSON and used as an IR. |
| Typed normalized Core | The internal canonical form of a validated document; the single input of every backend. |
| Contract | The deterministic human-readable restatement of a normalized document. A review artifact, not a proof. |
| NSPE | No Self Privilege Escalation, the one currently verified property family. |
| Rule 1 / Rule 2 | The two exact structural NSPE proof rules: change-other and bounded-self-update. |
| `NspeSupportPlan` | The internal Haskell support witness recording why a document was accepted; consumed by both backends. |
| Support gate | The pure structural check deciding supported vs. `UNSUPPORTED`, before any checker runs. |
| Kernel | The handwritten, trusted generic Agda modules embedded into the tool. |
| `Mithril/Generated.agda` | The deterministically generated document-specific Agda obligation module. |
| `VERIFIED` | Agda accepted every required theorem of every selected case. Exit 0. |
| `UNSUPPORTED` | Outside the implemented support rules. Not a safety or violation verdict. Exit 3. |
| Golden file | A committed byte-frozen expected output that pins determinism and exposes drift; not a proof. |
| Wasp Confinement Profile v0 / v1 | The two closed 14-file demonstrator applications, for `[Rule 1]` and `[Rule 1, Rule 2]`. |
| `CONFINED` | The checked source root is byte-identical to the regenerated closed profile. Exit 0. |
| Trusted computing base | The components a claim silently relies on; a defect there invalidates the claim. |
