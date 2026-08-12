{-# OPTIONS --safe #-}

-- Mithril Agda spike: a representative Acme-style example composing state,
-- lookup, policy evaluation, capabilities, authorized execution and
-- results — plus the regression evidence for the capability boundary.
--
-- The scenario: one organization ("acme", index 0) with one project
-- ("apollo", index 0, belonging to acme).  Two users: alice (index 0), a
-- member of acme, and mallory (index 1), an outsider with no membership.
--
-- Several example actions below are DELIBERATELY permissive: they exercise
-- the mechanics (upsert, creation, framing), not sensible policy design.
-- No application-level security property is claimed; in particular
-- NoSelfPrivilegeEscalation remains a future target, not something this
-- spike enforces.

module Mithril.Spike where

open import Mithril.Base
open import Mithril.Core
open import Mithril.Policy
open import Mithril.Effect

-- The example state -----------------------------------------------------------

alice mallory : EntityRef UserK
alice   = ref 0
mallory = ref 1

acmeOrg : EntityRef OrgK
acmeOrg = ref 0

apollo : EntityRef ProjectK
apollo = ref 0

acmeMembership : MembershipMap
acmeMembership zero zero = just memberR
acmeMembership _    _    = nothing

acme : State
acme = record
  { users      = 2
  ; orgs       = 1
  ; projects   = 1
  ; projOrg    = λ _ → 0
  ; membership = acmeMembership
  }

acme-wf : WF acme
acme-wf = record
  { proj-ok     = λ p _ → s≤s z≤n
  ; mem-user-ok = user-ok
  ; mem-org-ok  = org-ok
  }
  where
  user-ok : ∀ u o r → acmeMembership u o ≡ just r → u < 2
  user-ok zero    zero    r refl = s≤s z≤n
  user-ok zero    (suc o) r ()
  user-ok (suc u) o       r ()

  org-ok : ∀ u o r → acmeMembership u o ≡ just r → o < 1
  org-ok zero    zero    r refl = s≤s z≤n
  org-ok zero    (suc o) r ()
  org-ok (suc u) o       r ()

alice-exists : Exists acme alice
alice-exists = s≤s z≤n

mallory-exists : Exists acme mallory
mallory-exists = s≤s (s≤s z≤n)

acmeOrg-exists : Exists acme acmeOrg
acmeOrg-exists = s≤s z≤n

apollo-exists : Exists acme apollo
apollo-exists = s≤s z≤n

-- Relation lookup is total and closed-world ------------------------------------

member-lookup-present : lookupMem acme alice acmeOrg ≡ just memberR
member-lookup-present = refl

missing-lookup-absent : lookupMem acme mallory acmeOrg ≡ nothing
missing-lookup-absent = refl

-- An authenticated member policy -----------------------------------------------

-- One typed argument: the organization the request is about.
OrgCtx : Ctx
OrgCtx = ∅ ▸ entity OrgK

orgArg : Args OrgCtx
orgArg = ∅ ▸ acmeOrg

-- "The actor's membership in the argument organization is at least Member",
-- via ordered comparison on Maybe Role with absence as bottom: an absent
-- membership compares below `just memberR`, so outsiders are denied by the
-- same total comparison that admits members — no unwrap, no partiality.
memberPol : Policy OrgCtx authenticatedOnly
memberPol = authP (leqT (maybe-ord role-ord)
                        (justT (roleL memberR))
                        (memT actorT (arg here)))

member-allowed : checkPolicy acme orgArg (authC alice) memberPol ≡ true
member-allowed = refl

outsider-denied : checkPolicy acme orgArg (authC mallory) memberPol ≡ false
outsider-denied = refl

-- Scope of the Actor claim -----------------------------------------------------

data IsActor : ∀ {a Γ t} → Term a Γ t → Set where
  is-actor : ∀ {Γ} → IsActor (actorT {Γ})

-- Direct actorT SYNTAX cannot occur in an anonymous term: `actorT` only
-- types at `authed`.  This is a claim about syntax and direct environment
-- access, nothing more.
no-anon-actorT : ∀ {Γ t} (e : Term anon Γ t) → IsActor e → ⊥
no-anon-actorT e ()

-- What is NOT claimed: an ordinary valid User ARGUMENT may have exactly
-- the actor's value, and an anonymous-level term may consume it.  Core v0
-- claims no provenance tracking and no non-interference.  Below, the same
-- reference (alice) reaches an anonymous term through an argument and an
-- authenticated term through actorT, with identical results.
UserCtx : Ctx
UserCtx = ∅ ▸ entity UserK

anonUserArg : Term anon UserCtx (entity UserK)
anonUserArg = arg here

actor-value-flows-as-argument :
  eval acme tt (∅ ▸ alice) anonUserArg
  ≡ eval acme (mkAuthed alice) (∅ ▸ alice) actorT
actor-value-flows-as-argument = refl

-- Reads: capabilities bind the COMPLETE action ---------------------------------

ProjCtx : Ctx
ProjCtx = ∅ ▸ entity ProjectK

projArg : Args ProjCtx
projArg = ∅ ▸ apollo

viewOrgObs : Term anon ProjCtx (entity OrgK)
viewOrgObs = orgOfT (arg here)

-- Two AnyPrincipal reads with the SAME (deliberately public) policy but
-- different designated observations — of different kinds, even.  The
-- policy never mentions the observation; the capability nevertheless
-- authorizes policy-plus-observation as one complete action, so the two
-- capabilities below have different types and each execution returns its
-- own action's designated observation, never the other's.
viewProjectOrg : Action anyPrincipal ProjCtx (observeD OrgK)
viewProjectOrg = readA (anyP (boolL true) (boolL true)) viewOrgObs

viewProject : Action anyPrincipal ProjCtx (observeD ProjectK)
viewProject = readA (anyP (boolL true) (boolL true)) (arg here)

viewOrgCap : Capability acme anonC projArg viewProjectOrg
viewOrgCap = grant acme-wf tt (tt , apollo-exists) refl

viewProjCap : Capability acme anonC projArg viewProject
viewProjCap = grant acme-wf tt (tt , apollo-exists) refl

view-org : execute viewOrgCap (canonAlloc acme) ≡ (acme , observed acmeOrg)
view-org = refl

view-proj : execute viewProjCap (canonAlloc acme) ≡ (acme , observed apollo)
view-proj = refl

-- The observed value is exactly the designated observation of the action
-- carried by the capability (instance of `execute-read-exact`) …
view-org-exact : resultOf (execute viewOrgCap (canonAlloc acme))
               ≡ observed (eval acme tt projArg viewOrgObs)
view-org-exact = execute-read-exact viewOrgCap (canonAlloc acme)

-- … and the observed entity exists in the valid pre-state.
view-org-observed-exists : Exists acme acmeOrg
view-org-observed-exists = execute-read-exists viewOrgCap (canonAlloc acme)

-- The authenticated branch of an AnyPrincipal read: same designated
-- observation, still evaluated in the anonymous effect environment.
viewOrgCapAuth : Capability acme (authC alice) projArg viewProjectOrg
viewOrgCapAuth = grant acme-wf alice-exists (tt , apollo-exists) refl

view-org-authed : execute viewOrgCapAuth (canonAlloc acme) ≡ (acme , observed acmeOrg)
view-org-authed = refl

-- SetRelation, insertion: absent tuple → present ---------------------------------

-- "Join an organization you are not yet in, as a member."
joinOrg : Action authenticatedOnly OrgCtx doneD
joinOrg = mutA (authP (notT (hasMemT actorT (arg here))))
               (setRelE actorT (arg here) (roleL memberR))

-- The capability packages validity (well-formed pre-state, existing
-- caller, existing argument) BEFORE the policy equation is accepted.
joinCap : Capability acme (authC mallory) orgArg joinOrg
joinCap = grant acme-wf mallory-exists (tt , acmeOrg-exists) refl

-- `execute` and `execute-wf` need nothing but the capability and the
-- execution-only allocator.
afterJoin : ExecOut doneD
afterJoin = execute joinCap (canonAlloc acme)

join-lookup : lookupMem (postState afterJoin) mallory acmeOrg ≡ just memberR
join-lookup = refl

join-result-done : resultOf afterJoin ≡ done
join-result-done = refl

join-frame-alice : lookupMem (postState afterJoin) alice acmeOrg ≡ just memberR
join-frame-alice = refl

-- The same fact through the general frame lemma.
join-frame-general : lookupMem (postState afterJoin) alice acmeOrg
                   ≡ lookupMem acme alice acmeOrg
join-frame-general = execute-setRel-frame joinCap (canonAlloc acme) alice acmeOrg noHit
  where
  noHit : ¬ ((1 ≡ 0) × (0 ≡ 0))
  noHit (() , _)

join-wf : WF (postState afterJoin)
join-wf = execute-wf joinCap (canonAlloc acme)

-- SetRelation, replacement: present tuple → new payload --------------------------

-- Any member may set their own payload to Admin.  (Deliberately permissive:
-- this exercises upsert-replacement through the authorized boundary.)
selfAdmin : Action authenticatedOnly OrgCtx doneD
selfAdmin = mutA memberPol (setRelE actorT (arg here) (roleL adminR))

selfAdminCap : Capability acme (authC alice) orgArg selfAdmin
selfAdminCap = grant acme-wf alice-exists (tt , acmeOrg-exists) refl

afterPromote : ExecOut doneD
afterPromote = execute selfAdminCap (canonAlloc acme)

promote-lookup : lookupMem (postState afterPromote) alice acmeOrg ≡ just adminR
promote-lookup = refl

promote-frame : lookupMem (postState afterPromote) mallory acmeOrg ≡ nothing
promote-frame = refl

promote-wf : WF (postState afterPromote)
promote-wf = execute-wf selfAdminCap (canonAlloc acme)

-- CreateEntity -------------------------------------------------------------------

-- "A member of an organization may create a project in it."  The new
-- project's reference is NOT part of the request: OrgCtx carries only the
-- organization, and no entity-reference term of a valid request can
-- evaluate to the candidate (general theorem: `fresh-not-evaluable`;
-- checked inhabited instance: `fresh-candidate-unreachable` below).  The
-- candidate arrives only at execution time, through the allocator.
createProject : Action authenticatedOnly OrgCtx (createdD ProjectK)
createProject = mutA memberPol (createE ProjectK (arg here))

createCap : Capability acme (authC alice) orgArg createProject
createCap = grant acme-wf alice-exists (tt , acmeOrg-exists) refl

afterCreate : ExecOut (createdD ProjectK)
afterCreate = execute createCap (canonAlloc acme)

-- The candidate did not exist in the pre-state …
create-candidate-was-fresh : ¬ Exists acme (fst (canonAlloc acme ProjectK))
create-candidate-was-fresh = allocator-fresh acme (canonAlloc acme) ProjectK

-- … creation returns exactly that candidate …
create-exact : resultOf afterCreate ≡ created (fst (canonAlloc acme ProjectK))
create-exact = execute-create-exact createCap (canonAlloc acme)

create-ref : resultOf afterCreate ≡ created (ref 1)
create-ref = refl

-- … the candidate exists afterward, with its organization attribute set …
create-exists : Exists (postState afterCreate) (ref {ProjectK} 1)
create-exists = execute-create-exists createCap (canonAlloc acme)

create-org-set : projOrg (postState afterCreate) 1 ≡ 0
create-org-set = refl

-- … pre-existing tuples and attribute values are framed …
create-mem-frame : lookupMem (postState afterCreate) alice acmeOrg ≡ just memberR
create-mem-frame = refl

create-projOrg-frame : projOrg (postState afterCreate) 0 ≡ 0
create-projOrg-frame = refl

create-apollo-still-exists : Exists (postState afterCreate) apollo
create-apollo-still-exists =
  execute-create-preserves-exists createCap (canonAlloc acme) apollo apollo-exists

-- … the counter vector changes exactly as specified: Projects gains
-- exactly one, Users and Organizations are exactly untouched …
create-projects-count : count (postState afterCreate) ProjectK
                      ≡ suc (count acme ProjectK)
create-projects-count = execute-create-count-selected createCap (canonAlloc acme)

create-users-count : count (postState afterCreate) UserK ≡ count acme UserK
create-users-count = execute-create-count-other createCap (canonAlloc acme) UserK (λ ())

create-orgs-count : count (postState afterCreate) OrgK ≡ count acme OrgK
create-orgs-count = execute-create-count-other createCap (canonAlloc acme) OrgK (λ ())

-- … and the post-state is well-formed, from the capability alone.
create-wf : WF (postState afterCreate)
create-wf = execute-wf createCap (canonAlloc acme)

-- No entity-reference term of a valid request can evaluate to the fresh
-- candidate.  The instantiation of the general `fresh-not-evaluable`
-- theorem is genuinely inhabited: `projTerm` is an explicit project-typed
-- term (the ProjCtx request's Project argument, which evaluates to
-- apollo), so the proof reaches the semantic freshness inequality — it
-- does not hold by eliminating an impossible term.
projTerm : Term authed ProjCtx (entity ProjectK)
projTerm = arg here

fresh-candidate-unreachable :
  ¬ (eval acme (mkAuthed alice) projArg projTerm ≡ fst (canonAlloc acme ProjectK))
fresh-candidate-unreachable =
  fresh-not-evaluable acme (mkAuthed alice) projArg projTerm
    (fst (canonAlloc acme ProjectK))
    acme-wf alice-exists (tt , apollo-exists)
    (snd (canonAlloc acme ProjectK))

-- Regression: the initializer, not a constant, names the new Project's org --------

-- A second, two-organization state: one user (alice, index 0), member of
-- betaOrg (index 1) and of nothing else; one project (apollo) in org 0.
betaOrg : EntityRef OrgK
betaOrg = ref 1

acme2Membership : MembershipMap
acme2Membership zero (suc zero) = just memberR
acme2Membership _    _          = nothing

acme2 : State
acme2 = record
  { users      = 1
  ; orgs       = 2
  ; projects   = 1
  ; projOrg    = λ _ → 0
  ; membership = acme2Membership
  }

acme2-wf : WF acme2
acme2-wf = record
  { proj-ok     = λ p _ → s≤s z≤n
  ; mem-user-ok = user-ok
  ; mem-org-ok  = org-ok
  }
  where
  user-ok : ∀ u o r → acme2Membership u o ≡ just r → u < 1
  user-ok zero    (suc zero)    r refl = s≤s z≤n
  user-ok zero    zero          r ()
  user-ok zero    (suc (suc o)) r ()
  user-ok (suc u) o             r ()

  org-ok : ∀ u o r → acme2Membership u o ≡ just r → o < 2
  org-ok zero    (suc zero)    r refl = s≤s (s≤s z≤n)
  org-ok zero    zero          r ()
  org-ok zero    (suc (suc o)) r ()
  org-ok (suc u) o             r ()

alice-exists₂ : Exists acme2 alice
alice-exists₂ = s≤s z≤n

betaOrg-exists : Exists acme2 betaOrg
betaOrg-exists = s≤s (s≤s z≤n)

-- The SAME complete action `createProject`, whose initializer is the org
-- ARGUMENT, executed against betaOrg (reference 1) instead of reference 0.
betaArg : Args OrgCtx
betaArg = ∅ ▸ betaOrg

createBetaCap : Capability acme2 (authC alice) betaArg createProject
createBetaCap = grant acme2-wf alice-exists₂ (tt , betaOrg-exists) refl

afterCreateBeta : ExecOut (createdD ProjectK)
afterCreateBeta = execute createBetaCap (canonAlloc acme2)

-- The new Project (index 1 = the allocator's candidate) stores
-- organization reference 1 — the evaluation of the action's initializer.
-- An implementation that ignored the InitTerm and always initialized
-- Project.organization to organization 0 could not satisfy these.
create-beta-init : projOrg (postState afterCreateBeta) 1 ≡ 1
create-beta-init = refl

create-beta-init-not-zero : ¬ (projOrg (postState afterCreateBeta) 1 ≡ 0)
create-beta-init-not-zero ()

-- The same fact through the general initializer-binding theorem, at the
-- exact allocator candidate and the exact action initializer.
orgInit : Term authed OrgCtx (entity OrgK)
orgInit = arg here

create-beta-via-general :
  projOrg (postState afterCreateBeta) (ix (fst (canonAlloc acme2 ProjectK)))
  ≡ ix (eval acme2 (mkAuthed alice) betaArg orgInit)
create-beta-via-general = execute-create-project-init createBetaCap (canonAlloc acme2)

-- Regression: ghost requests have no capability ----------------------------------

ghostUser : EntityRef UserK
ghostUser = ref 9

-- A ghost authenticated caller is invalid …
ghost-caller-invalid : ∀ m → ¬ ValidCaller acme (authC {m} ghostUser)
ghost-caller-invalid m (s≤s (s≤s ()))

-- … so NO action whatsoever can be authorized for it: a capability for a
-- ghost caller is unconstructable from the required premises.
no-ghost-caller-cap : ∀ {m Γ d} {γ : Args Γ} {act : Action m Γ d}
                    → ¬ Capability acme (authC ghostUser) γ act
no-ghost-caller-cap {m = m} cap = ghost-caller-invalid m (caller-ok cap)

-- In particular the old counterexample — executing joinOrg as a ghost
-- user, which would have installed a Membership tuple with a nonexistent
-- endpoint — is unconstructable.
no-ghost-join-cap : ¬ Capability acme (authC ghostUser) orgArg joinOrg
no-ghost-join-cap = no-ghost-caller-cap

-- Ghost ARGUMENTS are equally dead.  `addMember` writes Membership at two
-- argument endpoints under a deliberately permissive policy — precisely
-- the shape of the reviewed counterexample.
UOCtx : Ctx
UOCtx = ∅ ▸ entity UserK ▸ entity OrgK

addMember : Action authenticatedOnly UOCtx doneD
addMember = mutA (authP (boolL true))
                 (setRelE (arg (there here)) (arg here) (roleL memberR))

ghostArgs : Args UOCtx
ghostArgs = ∅ ▸ ghostUser ▸ acmeOrg

ghost-args-invalid : ¬ ValidArgs acme ghostArgs
ghost-args-invalid ((_ , s≤s (s≤s ())) , _)

no-ghost-member-cap : ¬ Capability acme (authC alice) ghostArgs addMember
no-ghost-member-cap cap = ghost-args-invalid (args-ok cap)

-- The sharpest instance: the fresh allocation candidate itself, smuggled
-- in as a request argument.  Its validity is refutable, so no capability
-- exists and no authorized execution can observe or store it.
freshUser : EntityRef UserK
freshUser = fst (canonAlloc acme UserK)

freshArgs : Args UOCtx
freshArgs = ∅ ▸ freshUser ▸ acmeOrg

freshUser-args-invalid : ¬ ValidArgs acme freshArgs
freshUser-args-invalid ((_ , s≤s (s≤s ())) , _)

no-fresh-arg-cap : ¬ Capability acme (authC alice) freshArgs addMember
no-fresh-arg-cap cap = freshUser-args-invalid (args-ok cap)
