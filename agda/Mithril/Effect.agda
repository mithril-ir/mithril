{-# OPTIONS --safe #-}

-- Mithril embedded fixed-schema Agda kernel: effects, results, actions and
-- the authorized execution boundary.
--
-- This module owns the result descriptors, the one-effect mutation
-- language indexed by the descriptor it produces, actions, the
-- `Capability` authorization evidence, the only public transition
-- `execute`, and the theorems about authorized executions.  Authorization
-- is a capability indexed by the exact pre-state, caller, arguments and
-- COMPLETE action; a policy equation alone is never authorization, and the
-- raw effect interpreter stays private to this module.  The representation
-- choices these definitions fix are itemized in `agda/README.md`.

module Mithril.Effect where

open import Mithril.Base
open import Mithril.Core
open import Mithril.Policy

-- Result descriptors and results ---------------------------------------------

data Desc : Set where
  observeD : EntityKind → Desc   -- a read observing one entity
  createdD : EntityKind → Desc   -- a mutation that created an entity
  doneD    : Desc                -- any other mutation

data Result : Desc → Set where
  observed : ∀ {k} → EntityRef k → Result (observeD k)
  created  : ∀ {k} → EntityRef k → Result (createdD k)
  done     : Result doneD

-- Effects ---------------------------------------------------------------------

-- Creation payload at the term level (a new Project names its organization).
InitTerm : Auth → Ctx → EntityKind → Set
InitTerm a Γ UserK    = ⊤
InitTerm a Γ OrgK     = ⊤
InitTerm a Γ ProjectK = Term a Γ (entity OrgK)

-- The one-effect language of a mutation, indexed by the result descriptor
-- it produces.  `MutEffect a Γ (observeD k)` is uninhabited: no mutation
-- can observe.
data MutEffect (a : Auth) (Γ : Ctx) : Desc → Set where
  noChangeE : MutEffect a Γ doneD
  setRelE   : Term a Γ (entity UserK) → Term a Γ (entity OrgK) → Term a Γ role
            → MutEffect a Γ doneD
  createE   : (k : EntityKind) → InitTerm a Γ k → MutEffect a Γ (createdD k)

-- Actions ----------------------------------------------------------------------

-- An action couples a policy with either a designated observation (reads)
-- or an effect (mutations).  Policies and effects live at `modeAuth m`:
-- effects and outputs of AnyPrincipal actions cannot contain actorT.
--
-- A read's policy is NOT required to mention the observation term: a
-- deliberately permissive policy may authorize a designated target without
-- inspecting it.  What binds them is the capability, which is indexed by
-- the COMPLETE action — policy and observation together.
data Action (m : Mode) (Γ : Ctx) : Desc → Set where
  readA : ∀ {k} → Policy Γ m → Term (modeAuth m) Γ (entity k)
        → Action m Γ (observeD k)
  mutA  : ∀ {d} → Policy Γ m → MutEffect (modeAuth m) Γ d
        → Action m Γ d

policyOf : ∀ {m Γ d} → Action m Γ d → Policy Γ m
policyOf (readA p _) = p
policyOf (mutA p _)  = p

-- Allocation as an execution-only input ----------------------------------------

-- The runtime allocator: at execution time, for any kind, a candidate
-- reference together with a proof that it is fresh in the pre-state.  It
-- supplies no initializer values — required attributes come exclusively
-- from the action's declared `InitTerm`.
Allocator : State → Set
Allocator s = (k : EntityKind) → Σ (EntityRef k) (λ r → Fresh s k r)

-- The canonical allocator: the next counter value is always fresh.
canonAlloc : (s : State) → Allocator s
canonAlloc s k = ref (count s k) , refl

-- Whatever the allocator, its candidate did not exist in the pre-state.
allocator-fresh : ∀ (s : State) (al : Allocator s) k → ¬ Exists s (fst (al k))
allocator-fresh s al k = fresh-not-exists s k (fst (al k)) (snd (al k))

ExecOut : Desc → Set
ExecOut d = State × Result d

postState : ∀ {d} → ExecOut d → State
postState = fst

resultOf : ∀ {d} → ExecOut d → Result d
resultOf = snd

-- The capability ----------------------------------------------------------------

-- `Capability s c γ act` is proof-relevant authorization for the EXACT
-- request: pre-state `s`, caller `c`, arguments `γ`, and the COMPLETE
-- action `act` — including its effect or designated read observation, not
-- merely its policy.  Two definitionally equal actions are the same
-- semantic action; a capability for one action cannot be consumed for a
-- different one, however its policy equation happens to normalize.
--
-- Validity comes before accepted authorization: the policy equation is
-- only ever accepted as authorization when `grant` packages it with
-- pre-state well-formedness and caller/argument validity for the same
-- request.  A request naming ghost references has no capability, because
-- `caller-ok`/`args-ok` are unprovable for it.
record Capability {m : Mode} {Γ : Ctx} {d : Desc}
                  (s : State) (c : Caller m) (γ : Args Γ)
                  (act : Action m Γ d) : Set where
  constructor grant
  field
    pre-wf    : WF s
    caller-ok : ValidCaller s c
    args-ok   : ValidArgs s γ
    policy-ok : checkPolicy s γ c (policyOf act) ≡ true

open Capability public

-- Internal, unauthorized semantic helpers ---------------------------------------

private

  evalInit : ∀ {a Γ} (k : EntityKind) → State → PEnv a → Args Γ
           → InitTerm a Γ k → AllocInit k
  evalInit UserK    s ρ γ _ = tt
  evalInit OrgK     s ρ γ _ = tt
  evalInit ProjectK s ρ γ e = eval s ρ γ e

  evalInit-valid : ∀ {a Γ} k (s : State) (ρ : PEnv a) (γ : Args Γ)
                   (i : InitTerm a Γ k)
                 → WF s → ValidEnv s ρ → ValidArgs s γ
                 → ValidInit s k (evalInit k s ρ γ i)
  evalInit-valid UserK    s ρ γ i wf ρv γv = tt
  evalInit-valid OrgK     s ρ γ i wf ρv γv = tt
  evalInit-valid ProjectK s ρ γ i wf ρv γv = eval-valid s ρ γ i wf ρv γv

  -- Raw effect interpreter.  Deliberately private: it consumes no
  -- authorization and is NOT an authorized transition.  The only public
  -- transition is `execute` below, which reaches this code exclusively
  -- through a `Capability`.
  execMut : ∀ {a Γ d} (s : State) → PEnv a → Args Γ → MutEffect a Γ d
          → Allocator s → ExecOut d
  execMut s ρ γ noChangeE          al = s , done
  execMut s ρ γ (setRelE eu eo er) al =
    setMem s (eval s ρ γ eu) (eval s ρ γ eo) (eval s ρ γ er) , done
  execMut s ρ γ (createE k i)      al =
    alloc s k (evalInit k s ρ γ i) , created (fst (al k))

  -- Conditional preservation for the raw interpreter; at the authorized
  -- boundary every premise is supplied from the capability.
  execMut-wf : ∀ {a Γ d} (s : State) (ρ : PEnv a) (γ : Args Γ)
               (eff : MutEffect a Γ d) (al : Allocator s)
             → WF s → ValidEnv s ρ → ValidArgs s γ
             → WF (postState (execMut s ρ γ eff al))
  execMut-wf s ρ γ noChangeE al wf ρv γv = wf
  execMut-wf s ρ γ (setRelE eu eo er) al wf ρv γv =
    setMem-wf s (eval s ρ γ eu) (eval s ρ γ eo) (eval s ρ γ er) wf
              (eval-valid s ρ γ eu wf ρv γv) (eval-valid s ρ γ eo wf ρv γv)
  execMut-wf s ρ γ (createE k i) al wf ρv γv =
    alloc-wf s k (evalInit k s ρ γ i) wf (evalInit-valid k s ρ γ i wf ρv γv)

-- Authorized execution -----------------------------------------------------------

-- The one public transition.  Everything about the request — pre-state,
-- caller, arguments, complete action — is fixed by the capability's
-- indices; the allocator is the only execution-time input.
execute : ∀ {m Γ d} {s : State} {c : Caller m} {γ : Args Γ}
          {act : Action m Γ d}
        → Capability s c γ act → Allocator s → ExecOut d
execute {s = s} {c = c} {γ = γ} {act = readA p out} cap al =
  s , observed (eval s (effEnv c) γ out)
execute {s = s} {c = c} {γ = γ} {act = mutA p eff} cap al =
  execMut s (effEnv c) γ eff al

-- Any authorized execution preserves well-formedness.  The capability is
-- the ONLY assumption about the request: well-formedness and validity are
-- extracted from it, never passed separately.
execute-wf : ∀ {m Γ d} {s : State} {c : Caller m} {γ : Args Γ}
             {act : Action m Γ d}
             (cap : Capability s c γ act) (al : Allocator s)
           → WF (postState (execute cap al))
execute-wf {act = readA p out} cap al = pre-wf cap
execute-wf {s = s} {c = c} {γ = γ} {act = mutA p eff} cap al =
  execMut-wf s (effEnv c) γ eff al
             (pre-wf cap) (effEnv-valid s c (caller-ok cap)) (args-ok cap)

-- Reads: exactly the designated observation, of an existing entity ---------------

module _ {m : Mode} {Γ : Ctx} {k : EntityKind}
         {s : State} {c : Caller m} {γ : Args Γ}
         {p : Policy Γ m} {out : Term (modeAuth m) Γ (entity k)} where

  -- A read changes nothing.
  execute-read-nochange : (cap : Capability s c γ (readA p out)) (al : Allocator s)
                        → postState (execute cap al) ≡ s
  execute-read-nochange cap al = refl

  -- The result is `observed` of exactly the evaluation of the designated
  -- observation term of the action the capability is indexed by.
  execute-read-exact : (cap : Capability s c γ (readA p out)) (al : Allocator s)
                     → resultOf (execute cap al)
                     ≡ observed (eval s (effEnv c) γ out)
  execute-read-exact cap al = refl

  -- The observed entity exists in the (valid, well-formed) pre-state.
  execute-read-exists : (cap : Capability s c γ (readA p out)) (al : Allocator s)
                      → Exists s (eval s (effEnv c) γ out)
  execute-read-exists cap al =
    eval-valid s (effEnv c) γ out
               (pre-wf cap) (effEnv-valid s c (caller-ok cap)) (args-ok cap)

-- SetRelation: requested tuple written, everything else framed ------------------

module _ {m : Mode} {Γ : Ctx}
         {s : State} {c : Caller m} {γ : Args Γ} {p : Policy Γ m}
         {eu : Term (modeAuth m) Γ (entity UserK)}
         {eo : Term (modeAuth m) Γ (entity OrgK)}
         {er : Term (modeAuth m) Γ role} where

  execute-setRel-point : (cap : Capability s c γ (mutA p (setRelE eu eo er)))
                         (al : Allocator s)
                       → lookupMem (postState (execute cap al))
                                   (eval s (effEnv c) γ eu) (eval s (effEnv c) γ eo)
                       ≡ just (eval s (effEnv c) γ er)
  execute-setRel-point cap al =
    setMem-lookup s (eval s (effEnv c) γ eu) (eval s (effEnv c) γ eo)
                    (eval s (effEnv c) γ er)

  execute-setRel-frame : (cap : Capability s c γ (mutA p (setRelE eu eo er)))
                         (al : Allocator s)
                         (u′ : EntityRef UserK) (o′ : EntityRef OrgK)
                       → ¬ ((ix (eval s (effEnv c) γ eu) ≡ ix u′)
                          × (ix (eval s (effEnv c) γ eo) ≡ ix o′))
                       → lookupMem (postState (execute cap al)) u′ o′
                       ≡ lookupMem s u′ o′
  execute-setRel-frame cap al u′ o′ np =
    setMem-lookup-other s (eval s (effEnv c) γ eu) (eval s (effEnv c) γ eo)
                          (eval s (effEnv c) γ er) u′ o′ np

-- CreateEntity: exact candidate, existence, and frame ---------------------------

module _ {m : Mode} {Γ : Ctx} {k : EntityKind}
         {s : State} {c : Caller m} {γ : Args Γ}
         {p : Policy Γ m} {i : InitTerm (modeAuth m) Γ k} where

  -- Creation returns exactly the allocator's candidate …
  execute-create-exact : (cap : Capability s c γ (mutA p (createE k i)))
                         (al : Allocator s)
                       → resultOf (execute cap al) ≡ created (fst (al k))
  execute-create-exact cap al = refl

  -- … which exists in the post-state …
  execute-create-exists : (cap : Capability s c γ (mutA p (createE k i)))
                          (al : Allocator s)
                        → Exists (postState (execute cap al)) (fst (al k))
  execute-create-exists cap al =
    alloc-exists s k (evalInit k s (effEnv c) γ i) (fst (al k)) (snd (al k))

  -- … while relation tuples, existing attribute values and existing
  -- entities are all preserved.
  execute-create-mem-frame : (cap : Capability s c γ (mutA p (createE k i)))
                             (al : Allocator s)
                             (u : EntityRef UserK) (o : EntityRef OrgK)
                           → lookupMem (postState (execute cap al)) u o
                           ≡ lookupMem s u o
  execute-create-mem-frame cap al u o =
    alloc-mem s k (evalInit k s (effEnv c) γ i) (ix u) (ix o)

  execute-create-projOrg-frame : (cap : Capability s c γ (mutA p (createE k i)))
                                 (al : Allocator s)
                                 (pj : Nat) → pj < projects s
                               → projOrg (postState (execute cap al)) pj
                               ≡ projOrg s pj
  execute-create-projOrg-frame cap al pj plt =
    alloc-projOrg s k (evalInit k s (effEnv c) γ i) pj plt

  execute-create-preserves-exists : (cap : Capability s c γ (mutA p (createE k i)))
                                    (al : Allocator s)
                                    {k′ : EntityKind} (r : EntityRef k′)
                                  → Exists s r
                                  → Exists (postState (execute cap al)) r
  execute-create-preserves-exists cap al r ex =
    alloc-preserves-exists s k (evalInit k s (effEnv c) γ i) r ex

  -- The exact counter-vector change of authorized creation: the selected
  -- kind's counter increments by exactly one …
  execute-create-count-selected : (cap : Capability s c γ (mutA p (createE k i)))
                                  (al : Allocator s)
                                → count (postState (execute cap al)) k
                                ≡ suc (count s k)
  execute-create-count-selected cap al =
    alloc-count s k (evalInit k s (effEnv c) γ i)

  -- … and every unrelated kind's counter is EXACTLY unchanged.
  execute-create-count-other : (cap : Capability s c γ (mutA p (createE k i)))
                               (al : Allocator s)
                               (k′ : EntityKind) → ¬ (k′ ≡ k)
                             → count (postState (execute cap al)) k′
                             ≡ count s k′
  execute-create-count-other cap al k′ np =
    alloc-count-other s k (evalInit k s (effEnv c) γ i) k′ np

-- Project creation: exact initializer binding -----------------------------------

module _ {m : Mode} {Γ : Ctx}
         {s : State} {c : Caller m} {γ : Args Γ}
         {p : Policy Γ m} {i : InitTerm (modeAuth m) Γ ProjectK} where

  -- The organization attribute of the created Project — at exactly the
  -- candidate the allocator selected — is exactly the evaluation of the
  -- capability-indexed ACTION's declared initializer, under the
  -- capability's exact pre-state, caller environment and arguments.  The
  -- allocator contributes only the candidate and its freshness evidence;
  -- neither is available to policy evaluation.
  execute-create-project-init :
      (cap : Capability s c γ (mutA p (createE ProjectK i)))
      (al : Allocator s)
    → projOrg (postState (execute cap al)) (ix (fst (al ProjectK)))
    ≡ ix (eval s (effEnv c) γ i)
  execute-create-project-init cap al rewrite snd (al ProjectK) =
    alloc-projOrg-new s (eval s (effEnv c) γ i)
