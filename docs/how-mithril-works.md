# How Mithril works

This guide is for programmers who know ordinary web applications but are new
to formal methods, Agda, and compiler terminology. It explains the current
prototype through one role-changing example, then follows that example through
the implementation.

The exact implementation and claim ledger is [current-scope.md](current-scope.md).
The normative pipeline and artifact-ownership rules are in
[compiler-architecture.md](compiler-architecture.md).

## Start with a role-changing application

Consider an application with users, organizations, and a `Membership`
relation. Each membership carries one of two roles:

```text
Member < Admin
```

The runnable
[`acme-nspe-self-update.mir.json`](../test/fixtures/acme-nspe-self-update.mir.json)
fixture contains two relevant actions:

1. `Membership.changeRole` lets an `Admin` change another existing member's
   role. Its policy requires the actor to have the top role, the actor and
   target to be different users, and the target membership to exist.
2. `Membership.changeOwnRole` lets an authenticated user write their own role
   only when `newRole <= currentRole`.

The second action permits an `Admin` to become a `Member` and permits an equal
write. It does not permit a `Member` to become an `Admin`. The first action
writes another user's membership, not the actor's. Together, these two exact
action shapes support the selected property that a user cannot raise their
own authority through either action.

Mithril calls this property **No Self Privilege Escalation** (NSPE). It calls
the two accepted action shapes **structural proof rules** because the verifier
recognizes their precise parameters, policy tree, effect, and case scope. In
this example, the case scope is the organization this guarantee case applies
to. It does not search for a proof of an arbitrary policy. A semantically
similar policy written in a different shape is outside the implemented rules
and is reported `UNSUPPORTED`.

This example exercises both currently supported structural rules; Mithril is
not a general authorization verifier.

## Why use one source document?

Authorization systems often have several descriptions of the same intended
rule: prose for a reviewer, a model for analysis, and application code for the
server. When those are written separately, a small difference in a guard,
role order, or target identity can make them disagree. Coding agents face the
same risk as human implementers.

Mithril takes one constrained Core document and derives its review contract,
Agda obligation module, and supported Wasp application through one
deterministic compiler path. The purpose is to remove separate interpretations
of the input inside the backends.

Using one source does not, by itself, prove that a generated Agda model or
TypeScript application preserves the Core document's meaning. No such
semantic-preservation theorem exists yet. The generators and their mappings
remain trusted parts of the relevant claim.

## The input: Mithril Core

**Mithril Core** is a small authorization domain-specific language (DSL). A
domain-specific language represents one limited problem area rather than
general-purpose computation. Core describes:

- entities and their attributes;
- ordered enum values such as `Member < Admin`;
- relations such as a user's membership in an organization;
- actions, including their parameters, allow policies, effects, and results;
- selected guarantee obligations.

Core is currently authored as JSON. The same JSON also serves as the
compiler's external intermediate representation (IR), meaning the structured
form accepted by the compiler. A human can write it directly. An optional,
untrusted LLM can propose it, but Mithril has no natural-language interface.
The document must still be reviewed as the statement of intent.

[`core/schema.json`](../core/schema.json) defines the permitted JSON shape.
Passing that schema establishes only that the JSON has the expected structure.
It does not establish that names resolve, types match, an action is safe, or a
guarantee holds.

## One frontend produces one checked internal form

Every command that consumes a Core file begins with the same Haskell frontend:

```text
parse -> structural validation -> resolution -> typecheck -> normalization
```

Each stage adds a limited fact:

| Stage | What it establishes |
|---|---|
| Parse | The file is well-formed JSON with no trailing input. |
| Structural validation | The JSON conforms to the supported profile of `core/schema.json`. |
| Resolution | Declaration names are unique in their namespaces, and every reference names an existing declaration of the right kind. |
| Typecheck | Terms, policies, effects, results, relation endpoints, enum orders, and guarantee parameters satisfy the Core v0 static type rules. |
| Normalization | The checked document is copied into one explicit internal form with resolved identities, stored term types, materialized enum ranks, and explicit endpoint bindings. |

The final value is the **typed normalized Core**. “Typed” means the static type
rules have passed. “Normalized” means the compiler has made structural facts
explicit and deterministic. It does not mean that the compiler evaluated the
policy, simplified Boolean expressions, compared two documents for equivalent
meaning, or proved a guarantee.

The internal Haskell API attaches a stage to each document. The contract
renderer and generators accept only the normalized stage, and external code
cannot construct that internal representation through the public API. These
types enforce compiler-pipeline discipline within Haskell. They do not prove
an authorization property.

## Three derived surfaces

All current downstream components consume the same typed normalized Core. None
re-reads the authored JSON.

### Text contract for review

`mithril contract FILE` renders a deterministic, line-oriented account of the
normalized declarations, actions, and selected guarantees. It gives a reviewer
a stable view of what entered the compiler, especially when an LLM proposed
the JSON.

The contract's human-facing presentation is provisional. Rendering does not
evaluate a policy or establish a guarantee. The selected guarantees are
labelled as unverified proof obligations, so the contract is a review artifact,
not a proof.

### Document-specific Agda module

Agda is a programming language and type checker in which a proposition can be
represented as a type and a proof as a value of that type. If the type checker
accepts the value, it has checked the proof against the definitions and rules
provided to it. Readers do not need to know Agda syntax to understand the
boundary here.

Mithril contains five handwritten Agda kernel modules. The kernel defines the
fixed state, policy, effect, authorization, and NSPE semantics used by the
current verifier slice. It is embedded into the Haskell tool and is trusted.

For a supported Core document, `mithril verify FILE` generates a separate
document-specific Agda module. The module instantiates a known proof shape for
each accepted Rule-1 or Rule-2 case. The tool places the generated module and
embedded kernel in a fresh temporary workspace and invokes exactly Agda 2.8.0
with `--safe --no-libraries --ignore-interfaces`.

This is deterministic proof generation for two known rules, not general proof
search. Agda checks every selected case of the one selected NSPE obligation.
No Core-to-Agda semantic-preservation theorem checks the generator's mapping,
so the Haskell generator, support rules, and embedded kernel remain trusted.

### Closed Wasp demonstrator

[Wasp](https://wasp.sh/) is a web application framework. Mithril currently
uses it for two small executable profiles:

- Profile v0 accepts exactly the case sequence `[Rule 1]`.
- Profile v1 accepts exactly `[Rule 1, Rule 2]` in authored order.

Both profiles are closed 14-file applications. Every other verified sequence,
including a Rule-2 singleton or a reversed pair, is refused before Mithril
resolves, inspects, stages, backs up, or writes the destination.

The generated Actions require Wasp authentication and use `context.user.id`
as the actor identity. Each authorization read and its one relation update run
inside a Prisma interactive transaction at PostgreSQL `Serializable`
isolation. These details are part of the two profile mappings. They are not a
general Wasp backend.

`mithril wasp check CORE_FILE WASP_ROOT` regenerates the selected profile in
memory and checks the whole source root. It rejects missing, changed, extra,
symbolically linked, or hard-linked inputs. `mithril wasp generate` installs a
complete owned root and finishes with the same check.

`CONFINED` describes the source snapshot the checker walked at the time of the
check. It is not a runtime sandbox. Later mutation, changes after `wasp build`,
dependency compromise, and other processes with database credentials are
outside that claim. Wasp, Node, Prisma, PostgreSQL, the templates, and the
Core-to-Wasp lowering remain trusted; no Core-to-Wasp semantic-preservation
theorem exists.

The closed design prevents an unnoticed handwritten server path from sitting
beside the generated Actions in the checked source root. It also makes the
profiles unsuitable for composition with a normal hand-edited Wasp
application. A future composable adapter is an architecture direction, not an
implemented feature.

## How support is decided

Before Agda runs, a pure **support gate** examines the typed normalized Core.
It accepts exactly one selected NSPE obligation whose nonempty cases each match
Rule 1 or Rule 2. It records the accepted relation, endpoint identities, role
ranking, and rule tag for every case in authored order.

That record is an internal Haskell value named `NspeSupportPlan`. It is a
support witness: it records why the document fits the implemented slice. Both
the Agda generator and Wasp emitter consume the same plan instead of defining
their own acceptance rules. The plan is not generated code and is not a proof.

The two main verifier results are intentionally different:

- `VERIFIED` (exit 0) means Agda 2.8.0 accepted every required theorem for
  every selected case of the document's one selected obligation.
- `UNSUPPORTED` (exit 3) means the document lies outside the implemented
  structural rules. It does not mean safe, unsafe, dangerous, or violated.

There is no `VIOLATED` result or counterexample engine. The exact rule shapes,
diagnostic classes, and all exit codes are specified in
[current-scope.md](current-scope.md).

## Evidence, proof, and trust

Several different mechanisms provide different kinds of evidence:

- Haskell stage types prevent accidental pipeline bypass within the exposed
  Haskell interfaces.
- Golden tests freeze the exact bytes of contracts, generated Agda modules,
  and Wasp trees so output drift is visible.
- Agda checks the generated proof terms for every selected case of a supported
  obligation.
- The Wasp confinement check compares a complete source root with the
  regenerated closed profile.

Only the Agda step checks the stated NSPE theorems. A stage type, deterministic
translation, passing test, golden file, or confinement result is not a formal
proof of backend correspondence or general security.

The relevant trusted computing base includes the Haskell tool and its pinned
dependencies, the embedded Agda kernel, the two support rules, Agda 2.8.0, and,
for the Wasp slice, Wasp, Node, Prisma, PostgreSQL, the templates, and the
lowering. The exact list and non-claims are maintained in the
[scope ledger](current-scope.md#trusted-components).

## Repository map

| Path | Contents |
|---|---|
| `core/schema.json` | The normative JSON Schema for the external Core v0 document shape. |
| `examples/acme/` | The handwritten broad Acme example. It validates and renders a contract but is not supported by the verifier. |
| `src/`, `src-internal/`, `app/` | The Haskell CLI, frontend, contract renderer, verifier slice, and Wasp emitter. `src-internal/` is package-private. |
| `agda/Mithril/` | The five embedded kernel modules plus authored experiments outside that kernel. See [`agda/README.md`](../agda/README.md). |
| `test/fixtures/` | Authored regression inputs and committed golden outputs. Generated goldens are changed only through their generators. |
| `test/api-probes/` | Compile-fail probes that pin the public Haskell API and stage boundary. |
| `test/wasp-integration/` | The separate live Wasp and PostgreSQL integration harness. |
| `docs/` | This guide, the exact scope ledger, and the normative architecture. |

The supported quickstart document remains in `test/fixtures/` because it is a
regression fixture. `examples/` contains human-facing authored examples. Local
experiments belong outside the repository or in an ignored location; generated
goldens are never edited by hand.

## Product and development use of coding agents

In the product architecture, an optional untrusted LLM can propose only the
authored Core JSON. No LLM participates after that boundary: parsing,
normalization, contract rendering, Agda generation and checking, Wasp
generation, and verdict reporting are deterministic toolchain steps.

Separately, substantial coding-agent assistance has been used to develop this
repository under human-directed architecture, review, and testing. That fact
does not strengthen any trust claim. Agent-written code is reviewed and tested
like other code, and test results remain evidence rather than proof.

## Short glossary

| Term | Meaning |
|---|---|
| Mithril Core | The constrained authorization DSL, currently authored as JSON. |
| IR | Intermediate representation: structured compiler input or internal data. |
| Typed normalized Core | The checked internal form consumed by every downstream generator. Its existence proves no policy property. |
| NSPE | No Self Privilege Escalation, the only property family currently supported by the verifier. |
| Structural proof rule | One exact policy and effect shape recognized by the support gate. |
| Agda kernel | The handwritten and trusted definitions and lemmas used to check generated obligations. |
| `VERIFIED` | Agda 2.8.0 accepted every required theorem for every selected case of one supported obligation. |
| `UNSUPPORTED` | Outside the implemented rules; not a safety or violation verdict. |
| `CONFINED` | The checked source root matched the regenerated closed Wasp profile at check time. |
| Trusted computing base | Components whose defects can invalidate a claim even when the authored document is unchanged. |
