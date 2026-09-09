# Mithril: current scope

This document is the single concise source for what Mithril implements
today, what exactly is verified, what is trusted, and what is explicitly
not claimed. Other documents link here instead of repeating this ledger.

For the accessible explanation of these pieces, read
[how-mithril-works.md](how-mithril-works.md). For the authoritative
pipeline and artifact-ownership specification, read
[compiler-architecture.md](compiler-architecture.md).

Status date: 2026-09-03. Mithril is experimental. It is not a complete
verifier, not a general web framework, and not a finished security
product.

## Implemented functionality

| Command | What it does |
|---|---|
| `mithril validate FILE` | The complete deterministic frontend: JSON parsing, structural validation against the compiled-in `core/schema.json`, complete Core v0 name resolution, complete Core v0 static typing, deterministic normalization into the internal typed normalized Core. |
| `mithril contract FILE` | The same pipeline, then a deterministic, line-oriented, human-readable security contract rendered from the typed normalized Core. A review artifact, not a proof. |
| `mithril verify FILE` | The same pipeline, then the one implemented verifier slice: for a supported document, deterministic generation of a document-specific Agda obligation module, checked by exactly Agda 2.8.0 in safe mode against trusted kernel modules embedded at compile time. |
| `mithril wasp generate CORE_FILE WASP_ROOT` | The same pipeline plus the verify gate (VERIFIED required), then lowering of the verified obligation into a closed 14-file Wasp 0.25.0/PostgreSQL application installed as a complete root, finished with the confinement check. |
| `mithril wasp check CORE_FILE WASP_ROOT` | Regenerates the same bundle without writing and checks that `WASP_ROOT` is exactly the closed profile: every managed file byte-identical, nothing missing, nothing extra. |

Contract rendering, Agda generation, and Wasp generation all consume the
same typed normalized Core produced by the single frontend. No backend
re-interprets the authored JSON.

An LLM may propose authored Core JSON; no LLM participates anywhere in
the deterministic compiler path (frontend, contract, Agda generation, or
Wasp generation).

## Supported verifier slice (exact)

The verifier recognizes exactly two structural NSPE
(No Self Privilege Escalation) proof rules. A document is supported when
it selects exactly one NoSelfPrivilegeEscalation guarantee whose
authority is a binary relation with a `User` subject endpoint, a
distinct-entity scope endpoint, and a two-value declared-order payload
enum with absence as bottom, and whose non-empty case collection
consists entirely of cases each matching exactly one of these rules,
classified independently and in authored order:

- **Rule 1 — change-other**: an `AuthenticatedOnly` action with exactly
  the subject/scope/payload parameter list, a `SetRelation` effect
  binding subject, scope, and payload to exactly those parameters, a
  case scope of exactly the scope parameter, and the allow policy
  exactly

  ```text
  And(LessOrEqual(Some(top authority value), Lookup(authority, [Actor, scope])),
      And(Not(Equal(Actor, subject)),
          IsSome(Lookup(authority, [subject, scope]))))
  ```

- **Rule 2 — bounded-self-update**: an `AuthenticatedOnly` action with
  exactly the scope/payload parameter list, a `SetRelation` effect
  binding the subject endpoint to exactly `Actor`, the scope endpoint to
  the scope parameter, and the payload to the payload parameter, a case
  scope of exactly the scope parameter, and the allow policy exactly

  ```text
  LessOrEqual(Some(payload), Lookup(authority, [Actor, scope]))
  ```

  with no further conjunct (an explicit `IsSome` is redundant under
  absence as bottom and is deliberately not accepted).

The support gate inspects the normalized document structurally — stored
identities and evidence, never raw JSON bytes, file names, hashes, or
policy evaluation. Semantically equivalent but differently authored
policy shapes are deliberately `UNSUPPORTED`: unsupported forms fail
closed.

`NspeSupportPlan` (`Mithril.Core.Internal.NspeSupportPlan`) is the
internal Haskell IR that records this classification as a support
witness — the shared authority, ranking, and identity facts plus the
rule-tagged case plans. It is stated once and consumed unchanged by both
the Agda generator and the Wasp emitter. It is not generated Haskell and
is not itself a proof.

### Verification fixtures

| Fixture | Result |
|---|---|
| [`test/fixtures/acme-nspe.mir.json`](../test/fixtures/acme-nspe.mir.json) | `VERIFIED` (exit 0) — one Rule-1 case. |
| [`test/fixtures/acme-nspe-self-update.mir.json`](../test/fixtures/acme-nspe-self-update.mir.json) | `VERIFIED` (exit 0) — a Rule-1 case plus a Rule-2 case. |
| [`test/fixtures/acme-nspe-dangerous.mir.json`](../test/fixtures/acme-nspe-dangerous.mir.json) | `UNSUPPORTED` (exit 3) — deliberately. A genuine self-promotion counterexample, but `UNSUPPORTED` is a support decision, not a violation verdict. |
| [`test/fixtures/acme-nspe-unsafe.mir.json`](../test/fixtures/acme-nspe-unsafe.mir.json) | `UNSUPPORTED` (exit 3) — the guard-free unsafe variant. |
| [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json) | `UNSUPPORTED` (exit 3) — the canonical broad example validates but selects three guarantees; TenantIsolation and AuthenticatedMutation verification is not implemented. |

A `VERIFIED` outcome means exactly: every selected case of the one
selected obligation of this document was checked by Agda. It establishes
nothing about any other guarantee, action, unselected authority writer,
or the application built from the document.

## Wasp profile dispatch (exact)

The Wasp commands dispatch over the ordered rule tags of the shared
support plan, after verification and before any destination access:

| Ordered rule tags | Outcome |
|---|---|
| `[Rule 1]` | Wasp Confinement Profile v0. |
| `[Rule 1, Rule 2]` (authored order) | Wasp Confinement Profile v1. |
| any other sequence (a singleton Rule-2 case, two Rule-1 cases, the reversed pair, three or more cases) | Refused (exit 3) with source-anchored reasons, before any destination is resolved, inspected, staged, backed up, or written. |

VERIFIED-but-Wasp-UNSUPPORTED is a valid outcome: arbitrary multi-case
lowering is not implemented.

Both profiles generate the same closed 14-file demonstrator application
(one authenticated Action for v0, two for v1, over the same managed
paths). Every identifier, filename, and route is a fixed role-derived
target name (`MithrilSubject`, `MithrilScope`, `MithrilAuthority`,
`MithrilPayload`, `mithrilCaseAction`, `mithrilSelfUpdateAction`,
`Value0`, `Value1`), never an authored name. `mithril wasp check`
rejects missing, altered, and extra files.

The current Wasp backend is **not composable** with arbitrary manually
edited pages or server code: the profile owns every server-capable input
of the application, and anything outside the fixed inventory fails the
confinement check. A future composable adapter is plausible, but it is
not implemented. Generating correct handlers alone cannot establish
whole-application security, because manually written server code could
bypass them — that is why the current profiles are closed.

The confinement claim is exactly: the source root the checker walked
was, at the time of checking or generation, a valid clean source
snapshot (the regenerated closed path inventory with byte-identical,
privately linked managed files and nothing else; symbolic links are not
followed and hard-linked files are rejected). Outside the claim, unless
separately prevented: malicious concurrent same-user mutation after the
final check, privileged users and malicious same-user processes in
general, malicious changes to the checker or the CI that runs it,
compromise of the Wasp, Node, Prisma, or PostgreSQL dependencies,
external processes holding the database credentials, and any tampering
after `wasp build`. Source-root confinement is not a runtime sandbox.

## CLI results and exit classification

| Exit | Meaning |
|---|---|
| 0 | Success: valid, contract rendered, `VERIFIED`, `GENERATED`, or `CONFINED`. |
| 1 | Invalid input (parse, structural, name, or type errors) or an unusable Wasp root path. |
| 2 | Internal or tool failure — including every Agda checker problem (missing or wrong-version Agda, launch or workspace failure, a nonzero check after gate acceptance). Never a semantic verdict. |
| 3 | `UNSUPPORTED`: the document (or, for the Wasp commands, the verified case sequence) lies outside the implemented support rules. Not a safety verdict, not a violation verdict. |
| 4 | Wasp root not confined, or not replaceable (unmarked nonempty root or unmanaged path), reported without mutation. |

Result vocabulary:

- `VERIFIED` — every required theorem of every selected case was
  accepted by Agda 2.8.0.
- `UNSUPPORTED` — the document is outside the implemented support rules.
  It is **not** "safe", "unsafe", "rejected as dangerous", or
  "violated". No general `VIOLATED` result and no counterexample engine
  exists.
- `CONFINED` — the checked source root is byte-identical to the
  regenerated closed profile.

## Trusted components

A defect in any of these can invalidate a verification claim without any
change to the authored model:

- the Haskell frontend, contract renderer, support gate, Agda generator,
  and Wasp emitter/confinement checker, with their direct dependencies
  (`aeson`; the exactly pinned `jsonschema 0.3.0.1` behind an explicit
  schema-profile gate; `regex-tdfa`; `containers`; the GHC boot
  libraries `directory`, `filepath`, `process`; `unix`);
- the five embedded Agda kernel modules (`Mithril.Base`, `Core`,
  `Policy`, `Effect`, `Guarantee`) and the two support rules themselves;
- the external Agda 2.8.0 toolchain (exactly this version; any other is
  a tool failure, exit 2);
- for the Wasp slice: Wasp 0.25.0, Node, Prisma, PostgreSQL, the
  profile templates, and the lowering;
- the platform components beneath them.

## Explicit non-claims

- `core/schema.json` defines the structural JSON grammar only — not
  semantic correctness and not proof.
- Normalization is structural canonicalization of one authored document
  only: no policy evaluation, no simplification, no folding, no claim of
  semantic equivalence between differently authored documents, and no
  semantic diff.
- The human-readable contract is a deterministic review artifact, not a
  proof; its rendered guarantees are explicitly labelled unverified
  proof obligations.
- No general proof search is implemented; the handwritten Agda kernel
  defines generic semantics and lemmas, and the generated module
  re-proves exactly the two supported rules per document.
- No semantic-preservation theorem proves Core-to-Agda correspondence,
  and none proves Core-to-Wasp correspondence. A rendered Wasp bundle is
  trusted correspondence evidence, not a proof.
- Golden files protect deterministic output and expose drift; they are
  not proofs. Test evidence in general is not proof.
- No policy evaluator, no TenantIsolation or AuthenticatedMutation
  verification, no verification of any obligation shape beyond the two
  supported rules, no general JSON-to-Agda generation, no general Wasp
  backend, no whole-product generator, no runtime sandbox or runtime
  enforcement, and no released binaries exist.
- Verification claims never mean "secure" in general. See
  [../SECURITY.md](../SECURITY.md) for how claims are scoped.

## Known unresolved boundaries

Deliberate, documented gaps — not desired contracts:

- Duplicate JSON object members are accepted under the JSON parser's
  (Aeson's) member semantics rather than rejected; which occurrence wins
  is not part of any Mithril contract.
- No independent input-size, nesting, memory, or execution-resource
  limits are enforced. `mithril validate` is not hardened validation for
  arbitrary untrusted, unbounded input.
- The Wasp confinement check is path-based, not descriptor-relative; the
  time-of-check caveats above apply.
- The Wasp filesystem confinement boundary has been exercised on Linux
  only. Other POSIX platforms are outside the current confinement
  claim.
- Packaging and distribution (prebuilt binaries, containers) are
  undecided.
- No lint or formatting command has been selected for the Haskell code.

## Current toolchain versions

| Component | Version |
|---|---|
| GHC | 9.12.4 |
| cabal-install | 3.18.1.0 |
| Agda | exactly 2.8.0 (`--safe --no-libraries --ignore-interfaces`) |
| Language edition | GHC2021 |
| Wasp (integration battery only) | 0.25.0 |
| Node.js (integration battery only) | 24 |
| PostgreSQL (integration battery only) | 16 |
| Platform | Linux/POSIX (the documented current workflow) |
