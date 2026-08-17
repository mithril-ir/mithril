# Mithril

> **Status: experimental; the compiler is not implemented.** This repository currently contains documentation — including the accepted compiler-architecture specification, [`docs/compiler-architecture.md`](docs/compiler-architecture.md) — an experimental Agda semantic spike (`agda/`), the first Mithril Core v0 concrete-syntax checkpoint: a normative JSON Schema plus one handwritten example model, and the Haskell host tool with pinned Haskell CI. The `mithril` CLI supports help and version output plus the first two deterministic frontend boundaries, `mithril validate FILE`: JSON parsing, structural validation against the Core v0 schema compiled into the tool from `core/schema.json`, and complete Core v0 name resolution — whose success is now carried as an explicit internal decoded and name-resolved Core representation rather than raw JSON. No Mithril typechecker, normalizer, verifier, proof generator, or target generator exists yet, and acceptance neither proves guarantees nor verifies an application. The spike now includes one hand-transcribed application experiment — a NoSelfPrivilegeEscalation proof for a single Acme action inside the fixed-schema Agda kernel ([`agda/README.md`](agda/README.md)) — but no automated verifier or JSON-to-Agda connection exists; it is not generated from and not connected to the JSON, and the JSON document itself and everything else described below remain unverified.

Mithril is experimental formal-verification infrastructure for **authorization and data-access security in AI-generated web backends**. That is its entire initial scope: it is not a general-purpose verification framework, not a web framework, and not a security product.

## The idea

Humans describe access-control intent in natural language, and that intent is captured in **Mithril Core**, a small, explicit intermediate representation authored as a JSON document. A human may write the JSON directly; an untrusted LLM may optionally propose it. Everything downstream derives from the authored document deterministically, through a single frontend and one shared typed normalized Core:

```
natural-language intent
    │  optional, untrusted human or LLM translation
    ▼
authored Mithril Core JSON
    │  one deterministic frontend (planned Haskell host tool):
    │  parse → validate → resolve → typecheck → normalize
    ▼
typed normalized Core ──┬──▶ human-readable security contract
                        ├──▶ Agda checking of stated properties
                        └──▶ deterministic generation of Wasp code
```

The key design commitment is that any LLM involvement ends at the authored Core document, and that contract rendering, Agda verification, and target code generation all consume the same typed normalized Core rather than interpreting the JSON independently. Everything downstream of the authored document is intended to be deterministic and auditable, so that what gets checked is exactly what gets executed. Haskell has been selected as the implementation language for this deterministic host tool; today it implements the first two stages — JSON parsing plus Core v0 structural validation, then complete Core v0 name resolution (`mithril validate FILE`) — and nothing downstream: no Mithril typechecking, no normalization, no verification, and no generation. [Wasp](https://wasp.sh/) is the first planned executable target. [`docs/compiler-architecture.md`](docs/compiler-architecture.md) is authoritative for the pipeline and its artifact-ownership boundaries.

## Current status vs. intended functionality

| Status | Description |
|---|---|
| **Exists today** | This documentation, the accepted compiler-architecture specification ([`docs/compiler-architecture.md`](docs/compiler-architecture.md)), contribution and security policies, agent guidelines, an experimental Agda semantic spike under `agda/` (including one hand-transcribed application slice: a checked NoSelfPrivilegeEscalation proof for the Acme `Membership.changeRole` action, see [`agda/README.md`](agda/README.md)), the Core v0 concrete-syntax checkpoint: [`core/schema.json`](core/schema.json) with the handwritten [`examples/acme/acme.mir.json`](examples/acme/acme.mir.json), and the Haskell host tool with pinned Haskell CI: Cabal package `mithril-ir` building the `mithril` CLI — help and version output plus `mithril validate FILE`, deterministic JSON parsing, Core v0 structural validation against the canonical schema compiled into the tool at build time from `core/schema.json` (no runtime file or environment lookup selects the grammar), and complete Core v0 name resolution (GHC 9.12.4, cabal-install 3.18.1.0; JSON parsing via `aeson`, structural validation via the exactly pinned `jsonschema 0.3.0.1` behind an explicit schema-profile gate, name resolution in the host tool itself with deterministic maps and sets from `containers`). A successfully resolved document is carried as an explicit internal decoded and name-resolved Core representation — identifier-based references with JSON source paths; generic JSON ends at the internal decode boundary. The tool ships with unit tests (including white-box checks of the real resolved model through a package-private sublibrary), process-level CLI regression tests, and downstream plus in-package compile-fail probes of its stage and identifier abstractions. The Acme example passes structural validation and name resolution. |
| **Does not exist yet** | Everything beyond JSON parsing, structural validation, and name resolution: the Mithril typechecker, normalizer, verifier, contract renderer, Wasp generator, and the optional LLM authoring aid (untrusted; it may propose Mithril Core JSON but remains outside the deterministic and trusted compiler pipeline). Structural validation is JSON shape conformance only, and name resolution establishes only declaration-name uniqueness and reference existence — together they type nothing, normalize nothing, and establish no security property. |

### Canonical Haskell commands

The host tool's authoritative build, test, and validation commands, run from the repository root:

```
cabal check
cabal build all --enable-tests
cabal test all --test-show-details=direct
sh test/api-probes/run-api-probes.sh
cabal run mithril -- --help
cabal run mithril -- --version
cabal run mithril -- validate examples/acme/acme.mir.json
```

The fourth command runs the API-boundary compile-fail probes in two parts. The downstream part builds a probe package that depends on `mithril-ir` as an ordinary external package and proves that importing the hidden document and representation modules, using the `CoreDocument` constructor, coercing between pipeline stages (or from a raw JSON value into one), and extracting a raw JSON value back out of a resolved document all fail to compile for the intended reasons — which also means external code cannot construct resolved nodes, mint internal identifiers, or coerce between identifier namespaces, since their types cannot even be named. The in-package part then proves the identifier boundary from inside the tool: flag-gated probe executables of `mithril-ir` itself (with their own compiling control that imports the real internal identifier definitions) attempt cross-namespace `coerce` between global identifier types and must fail with GHC's representation-mismatch error, because the identifier namespaces are distinct data types that not even internal compiler code can coerce into one another. The script needs a POSIX shell in addition to the pinned toolchain.

## Core v0 syntax checkpoint

[`core/schema.json`](core/schema.json) is the first normative concrete-syntax checkpoint for generic Mithril Core v0: a JSON Schema (draft 2020-12) that freezes the external JSON shape of a Core document — schema declarations, term constructors, effects, results, principal modes, and guarantee selections.

It validates JSON shape only. Schema acceptance establishes structural facts (required fields, closed constructor sets, principal-mode surface shape, action classification/effect/result compatibility, and the structural exclusion of direct `Actor` syntax from anonymous policy branches and from `AnyPrincipal` effects and results). It establishes no name resolution, no uniqueness, no typing, no enum-order correctness, no policy evaluation, and no security property.

[`examples/acme/acme.mir.json`](examples/acme/acme.mir.json) is a handwritten example model. It is neither generated nor verified. The three guarantee objects it selects — TenantIsolation, AuthenticatedMutation, and NoSelfPrivilegeEscalation — remain unverified for this document; their appearance in the JSON selects proof obligations and proves nothing. Separately, the Agda spike hand-transcribes the `Membership.changeRole` action and proves its selected NoSelfPrivilegeEscalation case inside the fixed-schema kernel ([`agda/README.md`](agda/README.md)); no tool connects that proof to this JSON document.

The `mithril` CLI checks this structural conformance, and then complete Core v0 name resolution, deterministically:

```sh
cabal run mithril -- validate examples/acme/acme.mir.json
```

`mithril validate FILE` parses FILE as JSON (rejecting malformed input and trailing garbage), validates it against the canonical schema compiled into the tool from `core/schema.json` within an explicitly gated schema profile (local `#` references only; see the tool's help text for its non-claims — the schema is embedded at build time, so no runtime package-data override such as the `mithril_ir_datadir` environment variable can substitute the grammar; this is provenance by construction, not a cryptographic-integrity claim), and then resolves every Core v0 name: declaration names must be unique independently in each namespace — entities, enums, relations, and actions globally; attributes within one entity, endpoints within one relation, parameters within one action — and every name reference must resolve in its correct namespace, including enum values against their enum, action-local `Argument` references, and entity-local `Attribute` members selected through the narrow declared-type lookup that is the only typing-shaped work in this stage. The Acme example passes. Passing establishes JSON shape plus name resolution only — the resolved stage is an opaque attestation about names, not typed normalized Core: no Mithril typechecker, normalizer, verifier, or Wasp generator exists yet, so term typing, operand compatibility, enum-order permutation validity, endpoint arity, and every deeper semantic check remain with the planned single Haskell frontend, which will produce the one typed normalized Core consumed by contract rendering, Agda checking, and target generation alike ([`docs/compiler-architecture.md`](docs/compiler-architecture.md)). A structurally valid document can therefore resolve successfully and still fail the future typechecker. Structural conformance can equally be checked with any standard JSON Schema draft 2020-12 validator; the name-resolution stage is specific to the host tool. The separate Agda spike under `agda/` explores candidate kernel semantics; it remains hand-transcribed, is not generated from and does not consume this JSON, and its single application proof does not verify this document.

The temporary representation checkpoint recorded at the previous milestone is now closed: a successfully resolved document is no longer the unchanged raw JSON value. The frontend decodes the structurally valid document into an explicit internal decoded and name-resolved Core representation — every Core v0 construct an explicit Haskell node, every resolved reference an internal namespace-specific identifier rather than a textual name, and every node and reference retaining its originating JSON path for future diagnostics. Generic JSON ends at that internal decode boundary: the raw Aeson value is discarded when resolution succeeds, the representation stays internal to the tool (it is not a public API), and the future typechecker, normalizer, Agda emitter, and backend adapters are to consume it rather than reinterpreting raw JSON or rebuilding name resolution independently. None of this changes what resolution establishes: the explicit representation is not typed normalized Core — it remains untyped, unnormalized, and unverified, and proves no property — and keeping the schema decoder, the representation's construct coverage, and the resolver aligned with `core/schema.json` remains a manually reviewed obligation, not an automated proof.

Two operational caveats apply to the current tool — known gaps, not contracts: duplicate JSON object members are currently accepted under the JSON parser's (Aeson's) member semantics rather than rejected, and which occurrence wins is not part of any Mithril contract; and no independent input-size, nesting, memory, or execution-resource limits are enforced yet. `mithril validate` should therefore not be treated as hardened validation for arbitrary untrusted, unbounded input. Neither caveat changes the narrower claim above: the unchanged Acme example structurally validates and resolves.

## Target properties (not implemented guarantees)

The following are properties Mithril **aims to verify in the future**. No product implementation of them exists, and none of them is guaranteed for any real application:

- **TenantIsolation** — a request executing on behalf of one tenant cannot read or write another tenant's data through generated data-access paths.
- **AuthenticatedMutation** — no generated mutation endpoint is reachable without an authenticated principal.
- **NoSelfPrivilegeEscalation** — no principal can use generated endpoints to raise their own privileges.

The only formal artifact so far is the Agda spike's hand-transcribed, fixed-schema experiment ([`agda/README.md`](agda/README.md)): one NoSelfPrivilegeEscalation action/property slice — the Acme `Membership.changeRole` action — is proved inside the kernel, with a checked counterexample for an unsafe variant. It covers nothing else: not the complete Acme model, not the JSON document, and not the other two properties. No automated verifier or JSON-to-Agda connection exists yet.

## What Mithril will not guarantee

Even once implemented, Mithril will not make an application "secure" in any general sense, and it will never be reasonable to describe a Mithril-verified backend as unhackable. In particular, Mithril does not and will not address:

- vulnerabilities in code outside the verified policy logic (frontends, custom handlers, third-party dependencies);
- infrastructure, deployment, and operational security (TLS configuration, secret management, database hardening);
- denial of service, side channels, and timing attacks;
- bugs in the trusted computing base: the verifier itself, the code generator, the target framework, and the runtime beneath them;
- the gap between what a human *meant* and what they *stated* — the LLM translation step is explicitly untrusted, and a faithful verification of the wrong intent is still the wrong policy.

Future verification claims will always be scoped to explicitly documented properties under explicitly documented assumptions, as described in [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get involved at this early stage, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards. Security reports should follow [SECURITY.md](SECURITY.md).

If Mithril saves you from an authorization bug, feel free to buy us a beer (preferably a Hacker-Pschorr).

## License

Mithril is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the full text.
