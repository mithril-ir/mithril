# Contributing to Mithril

Thanks for your interest in Mithril. Please read this short document before opening an issue or pull request.

## Where the project stands

Mithril's compiler backends and verifier are **not implemented**; the frontend now is. On the Haskell side the repository contains the `mithril-ir` Cabal package (GHC 9.12.4, cabal-install 3.18.1.0, GHC2021) whose `mithril` CLI prints help and version output and implements the four deterministic frontend boundaries: `mithril validate FILE`, JSON parsing, structural Core v0 validation against the canonical `core/schema.json` compiled into the tool at build time — no runtime file or environment lookup selects the grammar — (JSON parsing via `aeson`; validation via the exactly pinned, provisional `jsonschema 0.3.0.1` behind an explicit schema-profile gate), complete Core v0 name resolution (declaration-name uniqueness per namespace and resolution of every name reference; deterministic maps and sets via the direct `containers` dependency), complete Core v0 static typing of the resolved document (term, policy, effect, and result types; operand, relation-endpoint, and payload compatibility; enum-order permutation validity; `CreateEntity` initializer completeness; guarantee well-typedness — with no new dependency), and deterministic Core v0 normalization of the well-typed document (statically typed terms via the typechecker's own judgment, materialized enum ranks, explicit endpoint bindings, declaration-ordered `CreateEntity` initializers, explicit guarantee structure — again with no new dependency), together with unit tests, process-level CLI regression tests over the built executable, downstream API-boundary compile-fail probes, and pinned Haskell CI. A successfully resolved document is carried as an explicit internal decoded and name-resolved Core representation — resolved references use internal identifiers and retain JSON source paths, and generic JSON ends at the internal decode boundary — the typechecker consumes exactly that representation, and the normalizer turns the well-typed document into a distinct explicit typed normalized representation; but structural validation still establishes JSON shape only, name resolution establishes names only, static typing establishes the Core v0 typing judgments only, and normalization establishes deterministic structural canonicalization of one authored document only — no boolean simplification, constant folding, operand reordering, policy evaluation, or canonical equality between differently authored documents, and the internal representations prove no property. No Mithril verifier, contract renderer, or generator exists yet — no policy is evaluated, no guarantee is established, and nothing consumes the typed normalized Core; see [`docs/compiler-architecture.md`](docs/compiler-architecture.md).

The canonical Haskell checks, run from the repository root:

```
cabal check
cabal build all --enable-tests
cabal test all --test-show-details=direct
sh test/api-probes/run-api-probes.sh
cabal run mithril -- --help
cabal run mithril -- --version
cabal run mithril -- validate examples/acme/acme.mir.json
```

CI runs all of them on every push and pull request. Run them locally before submitting a change that touches the Haskell tool, `core/schema.json`, or `examples/acme/acme.mir.json`; the final command must keep reporting the Acme example as valid Mithril Core v0 through normalization. The probe script builds the expected-to-fail downstream package under `test/api-probes/` with a dedicated project file (`cabal.project.probes`) and verifies that every attack on the stage abstraction — importing the hidden document, representation, typechecker, normalized-representation, or normalizer modules, calling the `CoreDocument` constructor (including to forge a `Typed` or `Normalized` document), coercing between stages (including from `Resolved` to `Typed` and from `Typed` to `Normalized`) or from a raw JSON value into a stage, or coercing a resolved document back to a raw JSON value — still fails to compile for its intended reason; because the internal representation, typechecker, and normalizer modules cannot even be imported, downstream code can neither construct resolved or normalized nodes, typed or normalized documents, nor mint or cross-coerce internal identifiers. The same script then builds the flag-gated in-package probes of `mithril-ir` itself: after their control proves the real internal identifier definitions are in scope, the attack executables attempt cross-namespace `coerce` between global identifier types and must fail with GHC's representation-mismatch error — the identifier namespaces are distinct data types, non-coercible even for code inside the package. It needs a POSIX shell in addition to the pinned toolchain (on platforms without one, CI remains the authoritative runner).

The representation modules — resolved and normalized alike, with the shared static type language — live in a package-private named sublibrary of `mithril-ir` (`visibility: private`). That is an internal testability and encapsulation mechanism, not a packaging or distribution decision: no other package can depend on it or import its modules, while the package's own test suite uses it to white-box-inspect the real resolved and normalized models — identifiers, owners, retained JSON source paths, stamped static types, materialized ranks, and canonical initializer order — produced by the production pipeline, alongside the black-box pipeline checks.

If a `core/schema.json` change affects declaration namespaces, reference-bearing fields, Core constructors, enum uniqueness/order or `User` assumptions, or structural invariants used by resolution, typing, or normalization, follow the [mandatory schema-and-resolver audit](docs/compiler-architecture.md#schema-and-resolver-evolution): audit the internal schema decoder and the decoded/resolved representation's construct coverage as well as `Mithril.Core.Resolution`, the static typechecker behind `Mithril.Core.Typing`, and the normalizer with the normalized representation's construct coverage behind `Mithril.Core.Normalization`, identify every changed constructor and reference location, and add the relevant targeted regressions in the same change. Recompilation only detects changed schema bytes; passing structural validation and compilation does not establish decoder, representation, resolver, typechecker, or normalizer completeness — that completeness remains a manually reviewed obligation, not an automated proof.

Two operational caveats of the current validator — known gaps, not contracts: duplicate JSON object members are accepted under Aeson's member semantics rather than rejected (no particular occurrence is contractually the winner), and no independent input-size, nesting, memory, or execution-resource limits exist yet. Do not describe `mithril validate` as hardened validation for arbitrary untrusted, unbounded input. Neither caveat affects the narrower claim that the unchanged Acme example structurally validates, resolves, typechecks, and normalizes.

- **No lint or formatting command has been selected.** Do not invent one — any Haskell lint or format command you find elsewhere is not real. Such tools will be documented here if and when they are chosen.
- The experimental Agda semantic spike described below stays separate from the Haskell scaffold; its checks are real and remain required whenever files under `agda/` change.
- The most valuable contributions right now are design discussion, review of the scope and non-guarantees documented in the README, and prior-art references — not product code.

### The experimental Agda semantic spike

The repository does contain an experimental Agda mechanization of candidate kernel semantics under `agda/`. It is an exploratory spike, not a product prototype, and it does not select Agda as the implementation language.

It requires **exactly Agda 2.8.0** and uses Agda builtins only (no standard library and no other external library). Its only application-level result is one checked, hand-transcribed, fixed-schema proof slice (see [`agda/README.md`](agda/README.md)): the Acme example's `Membership.changeRole` action satisfies its selected NoSelfPrivilegeEscalation case, with checked negative evidence that an unsafe self-promotion variant violates the same proposition. Everything else remains unverified: there is no automated JSON-to-Agda connection, neither `examples/acme/acme.mir.json` nor the complete Acme model is verified, no other action or guarantee family (TenantIsolation, AuthenticatedMutation) is proved, and the slice is an experiment, not a product verifier.

Its two authoritative checks are real commands. Run both from the repository root, and run each from deleted `.agdai` interfaces so that neither check can succeed through interfaces produced by the other:

```
find . -type f -name '*.agdai' -delete
agda --safe -i agda agda/Mithril/Everything.agda

find . -type f -name '*.agdai' -delete
agda --safe --no-libraries --ignore-interfaces -i agda agda/Mithril/Everything.agda
```

[`agda/README.md`](agda/README.md) is the detailed source for the spike's boundary and these commands. Changes touching `agda/` must keep both checks passing.

## Discuss before building

Major architectural changes — the design of Mithril Core, the verification approach, the code-generation strategy — should be **discussed in an issue before any implementation work begins**. A pull request that lands a large unsolicited design is likely to be closed in favor of a discussion, however good the code is. Small fixes (typos, broken links, clarifications) can go straight to a pull request.

## Conventions

- **Branch names** are lowercase kebab-case with an optional short prefix, for example `feat/core-v0`, `docs/threat-model`, `fix/readme-links`.
- **Commit and PR titles** are concise English in sentence case: an initial capital letter, no final period. For example: `Clarify verifier trust assumptions in README`.
- We do **not** use Conventional Commit prefixes (`feat:`, `fix:`, `chore:`) by default.

## Honesty about security claims

Mithril's credibility depends on never overstating what is verified. Documentation and code comments must not describe target properties as implemented guarantees. When in doubt, say less. See [SECURITY.md](SECURITY.md) and the non-guarantees section of the [README](README.md).

## Code of conduct

All participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
