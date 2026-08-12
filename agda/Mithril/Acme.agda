{-# OPTIONS --safe #-}

-- Mithril Agda spike: first application-level guarantee slice for Acme.
--
-- This module HAND-TRANSCRIBES one action of the handwritten JSON example
-- `examples/acme/acme.mir.json` — `Membership.changeRole` — into the
-- fixed-schema spike kernel, and proves the one NoSelfPrivilegeEscalation
-- case that the JSON document selects for it: no authorized execution of
-- the action raises the authenticated actor's own Membership authority in
-- the selected organization.  Negative evidence follows: a deliberately
-- unsafe self-promotion variant admits a concrete valid, authorized
-- Member → Admin transition, and a checked theorem shows that transition
-- violates the same proposition.
--
-- WHAT THIS IS NOT.  No parser, resolver, typechecker, normalizer,
-- verifier or JSON-to-Agda lowering exists; the transcription below is by
-- hand and is not checked against the JSON document by any tool.  Only
-- this one action/property slice is treated: the remaining Acme actions,
-- the other guarantee families (TenantIsolation, AuthenticatedMutation),
-- and the JSON document itself remain unverified.  DeleteEntity semantics
-- (used by `Project.delete`) are not modeled by the kernel at all.

module Mithril.Acme where

open import Mithril.Base
open import Mithril.Core
open import Mithril.Policy
open import Mithril.Effect
open import Mithril.Guarantee
open import Mithril.Spike using
  (alice; mallory; acmeOrg; acme; acme-wf; alice-exists; acmeOrg-exists)

-- Membership.changeRole: parameters ---------------------------------------------
--
-- JSON parameters, in declaration order:
--
--   target       : EntityRef User          ↦ entity UserK
--   organization : EntityRef Organization  ↦ entity OrgK
--   newRole      : Enum MembershipRole     ↦ role
--
-- (`MembershipRole = {Member, Admin}` with order `[Member, Admin]` is the
-- spike's `Role` with `memberR < adminR`; `Argument n` becomes the de
-- Bruijn index of the parameter.)

ChangeRoleCtx : Ctx
ChangeRoleCtx = ∅ ▸ entity UserK ▸ entity OrgK ▸ role

targetVar : Var ChangeRoleCtx (entity UserK)
targetVar = there (there here)

organizationVar : Var ChangeRoleCtx (entity OrgK)
organizationVar = there here

newRoleVar : Var ChangeRoleCtx role
newRoleVar = here

-- Membership.changeRole: allow policy --------------------------------------------
--
-- JSON:  And( LessOrEqual( Some(Admin)
--                        , Lookup(Membership, [Actor, organization]) )
--           , And( Not(Equal(Actor, target))
--                , IsSome(Lookup(Membership, [target, organization])) ) )
--
-- Constructor mapping (same nesting, same operand order):
--   Some(Enum MembershipRole v)      ↦ justT (roleL v)
--   Lookup(Membership, [u, o])       ↦ memT u o
--   LessOrEqual at Maybe Role        ↦ leqT (maybe-ord role-ord)
--                                      (absence-as-bottom order)
--   Not(Equal(_, _)) at User         ↦ notT (eqT _ _)
--   IsSome(Lookup(Membership, u, o)) ↦ hasMemT u o  (the kernel's fused
--                                      relation-presence form, defined as
--                                      isJust of the same lookup)
--   Actor                            ↦ actorT
--   Argument n                       ↦ arg (de Bruijn index of n)
--
-- The three conjuncts are named for use in the proofs; `changeRoleAllow`
-- composes them with exactly the JSON nesting And(⋯, And(⋯, ⋯)).

actorIsAdmin : Term authed ChangeRoleCtx bool
actorIsAdmin = leqT (maybe-ord role-ord)
                    (justT (roleL adminR))
                    (memT actorT (arg organizationVar))

actorIsNotTarget : Term authed ChangeRoleCtx bool
actorIsNotTarget = notT (eqT actorT (arg targetVar))

targetIsMember : Term authed ChangeRoleCtx bool
targetIsMember = hasMemT (arg targetVar) (arg organizationVar)

changeRoleAllow : Term authed ChangeRoleCtx bool
changeRoleAllow = andT actorIsAdmin (andT actorIsNotTarget targetIsMember)

-- Membership.changeRole: the complete action -------------------------------------
--
-- principalMode AuthenticatedOnly ↦ the `authenticatedOnly` mode index and
-- the single-branch `authP` policy; classification Mutation with a
-- SetRelation effect ↦ `mutA` with `setRelE`, whose descriptor index
-- forces the `done` result (JSON result Done); the effect writes
-- Membership(target, organization) := newRole.

changeRole : Action authenticatedOnly ChangeRoleCtx doneD
changeRole =
  mutA (authP changeRoleAllow)
       (setRelE (arg targetVar) (arg organizationVar) (arg newRoleVar))

-- Request projections ------------------------------------------------------------

targetOf : Args ChangeRoleCtx → EntityRef UserK
targetOf γ = lookupArg γ targetVar

organizationOf : Args ChangeRoleCtx → EntityRef OrgK
organizationOf γ = lookupArg γ organizationVar

-- The guarantee case for this action selects scope [Argument organization];
-- that scope term evaluates to exactly the `organization` argument the
-- theorems below use.
scopeTerm : Term authed ChangeRoleCtx (entity OrgK)
scopeTerm = arg organizationVar

scope-is-organization :
  ∀ (s : State) (a : EntityRef UserK) (γ : Args ChangeRoleCtx)
  → eval s (mkAuthed a) γ scopeTerm ≡ organizationOf γ
scope-is-organization s a γ = refl

-- Policy success separates actor from target -------------------------------------

-- The middle conjunct of the allow policy evaluates to
-- `notB (eqNat (ix actor) (ix target))`.  Assuming the indices were equal,
-- `eqNat-refl` rewrites that conjunct to `notB true`, which computes to
-- `false` and collapses the whole policy value to `A && false` — refuted
-- by `&&-false-absurd`.  So a successful policy forces the index
-- inequality the SetRelation frame lemma needs.
changeRole-policy-actor≢target :
  ∀ (s : State) (a : EntityRef UserK) (γ : Args ChangeRoleCtx)
  → checkPolicy s γ (authC a) (policyOf changeRole) ≡ true
  → ¬ (ix a ≡ ix (targetOf γ))
changeRole-policy-actor≢target s a γ pol p =
  &&-false-absurd (eval s (mkAuthed a) γ actorIsAdmin)
    (subst (λ b → (eval s (mkAuthed a) γ actorIsAdmin
                   && (notB b && eval s (mkAuthed a) γ targetIsMember))
                  ≡ true)
           (trans (sym (cong (eqNat (ix a)) p)) (eqNat-refl (ix a)))
           pol)

-- THE SAFE THEOREMS ---------------------------------------------------------------

-- Strong form: for EVERY pre-state, authenticated actor, argument
-- environment, capability for the complete `changeRole` action and
-- allocator, the authorized execution leaves the actor's own Membership
-- tuple in the selected organization EXACTLY unchanged.  Well-formedness
-- and request validity are not separate premises: they travel inside the
-- capability.  The proof composes the policy-derived actor ≢ target
-- inequality with the kernel's SetRelation frame lemma.
changeRole-actor-authority-unchanged :
  ∀ {s : State} {a : EntityRef UserK} {γ : Args ChangeRoleCtx}
    (cap : Capability s (authC a) γ changeRole) (al : Allocator s)
  → authorityOf (postState (execute cap al)) a (organizationOf γ)
  ≡ authorityOf s a (organizationOf γ)
changeRole-actor-authority-unchanged {s} {a} {γ} cap al =
  execute-setRel-frame cap al a (organizationOf γ) noHit
  where
  noHit : ¬ ((ix (targetOf γ) ≡ ix a)
           × (ix (organizationOf γ) ≡ ix (organizationOf γ)))
  noHit (tEq , _) =
    changeRole-policy-actor≢target s a γ (policy-ok cap) (sym tEq)

-- Guarantee form: no authorized execution of Membership.changeRole raises
-- the authenticated actor's own authority in the selected organization —
-- the NoSelfPrivilegeEscalation case the JSON document selects for this
-- action, proved here for the hand-transcribed action.
changeRole-no-self-escalation :
  ∀ {s : State} {a : EntityRef UserK} {γ : Args ChangeRoleCtx}
    (cap : Capability s (authC a) γ changeRole) (al : Allocator s)
  → NoSelfPrivilegeEscalation s (postState (execute cap al))
                              a (organizationOf γ)
changeRole-no-self-escalation {s} {a} {γ} cap al =
  authority-unchanged→no-escalation
    s (postState (execute cap al)) a (organizationOf γ)
    (changeRole-actor-authority-unchanged cap al)

-- Non-vacuity: the safe action is genuinely executable ----------------------------
--
-- A staffed variant of the Spike state: alice (user 0) is an ADMIN of the
-- acme organization and mallory (user 1) is a Member.  (States are
-- self-contained values; in `Mithril.Spike`'s `acme` the same references
-- carry different memberships.)

staffMembership : MembershipMap
staffMembership zero       zero = just adminR
staffMembership (suc zero) zero = just memberR
staffMembership _          _    = nothing

acmeStaff : State
acmeStaff = record
  { users      = 2
  ; orgs       = 1
  ; projects   = 1
  ; projOrg    = λ _ → 0
  ; membership = staffMembership
  }

acmeStaff-wf : WF acmeStaff
acmeStaff-wf = record
  { proj-ok     = λ p _ → s≤s z≤n
  ; mem-user-ok = user-ok
  ; mem-org-ok  = org-ok
  }
  where
  user-ok : ∀ u o r → staffMembership u o ≡ just r → u < 2
  user-ok zero          zero    r refl = s≤s z≤n
  user-ok zero          (suc o) r ()
  user-ok (suc zero)    zero    r refl = s≤s (s≤s z≤n)
  user-ok (suc zero)    (suc o) r ()
  user-ok (suc (suc u)) o       r ()

  org-ok : ∀ u o r → staffMembership u o ≡ just r → o < 1
  org-ok zero          zero    r refl = s≤s z≤n
  org-ok zero          (suc o) r ()
  org-ok (suc zero)    zero    r refl = s≤s z≤n
  org-ok (suc zero)    (suc o) r ()
  org-ok (suc (suc u)) o       r ()

alice-staff-exists : Exists acmeStaff alice
alice-staff-exists = s≤s z≤n

mallory-staff-exists : Exists acmeStaff mallory
mallory-staff-exists = s≤s (s≤s z≤n)

acmeOrg-staff-exists : Exists acmeStaff acmeOrg
acmeOrg-staff-exists = s≤s z≤n

-- Admin alice promotes ANOTHER user (mallory, an existing Member) to
-- Admin: every policy conjunct holds, so the safe action authorizes and
-- executes — the universal theorems are not vacuous.
promoteOtherArgs : Args ChangeRoleCtx
promoteOtherArgs = ∅ ▸ mallory ▸ acmeOrg ▸ adminR

promoteOtherCap : Capability acmeStaff (authC alice) promoteOtherArgs changeRole
promoteOtherCap =
  grant acmeStaff-wf alice-staff-exists
        (((tt , mallory-staff-exists) , acmeOrg-staff-exists) , tt) refl

afterPromoteOther : ExecOut doneD
afterPromoteOther = execute promoteOtherCap (canonAlloc acmeStaff)

-- The action does real work — the TARGET's authority changes …
promote-other-target-changed :
  authorityOf (postState afterPromoteOther) mallory acmeOrg ≡ just adminR
promote-other-target-changed = refl

-- … while the ACTOR's own tuple is untouched (instance of the strong
-- theorem) …
promote-other-actor-unchanged :
  authorityOf (postState afterPromoteOther) alice acmeOrg
  ≡ authorityOf acmeStaff alice acmeOrg
promote-other-actor-unchanged =
  changeRole-actor-authority-unchanged promoteOtherCap (canonAlloc acmeStaff)

-- … and the guarantee case holds for this concrete execution.
promote-other-no-self-escalation :
  NoSelfPrivilegeEscalation acmeStaff (postState afterPromoteOther)
                            alice acmeOrg
promote-other-no-self-escalation =
  changeRole-no-self-escalation promoteOtherCap (canonAlloc acmeStaff)

-- NEGATIVE EVIDENCE: a deliberately unsafe self-promotion variant -----------------
--
-- Same parameter context and same SetRelation effect as `changeRole`, but
-- the allow policy demands only that the ACTOR hold at least Member
-- authority in the organization: the Admin requirement, the
-- actor ≠ target guard and the target-membership requirement are all
-- dropped, so a mere Member may select target := themself,
-- newRole := Admin.  This action is NOT part of the Acme JSON document;
-- it exists as machine-checked evidence that the proposition proved above
-- is falsifiable and that the safe proof genuinely depends on the policy.

changeRoleUnsafe : Action authenticatedOnly ChangeRoleCtx doneD
changeRoleUnsafe =
  mutA (authP (leqT (maybe-ord role-ord)
                    (justT (roleL memberR))
                    (memT actorT (arg organizationVar))))
       (setRelE (arg targetVar) (arg organizationVar) (arg newRoleVar))

-- In `Mithril.Spike`'s `acme` state alice is a Member of the acme
-- organization, so the self-promotion request below is VALID and
-- AUTHORIZED for the unsafe variant: well-formed pre-state, existing
-- caller and arguments, and the unsafe policy accepts
-- (Member ≤ alice's Member membership).
selfPromotionArgs : Args ChangeRoleCtx
selfPromotionArgs = ∅ ▸ alice ▸ acmeOrg ▸ adminR

selfPromotionCap : Capability acme (authC alice) selfPromotionArgs changeRoleUnsafe
selfPromotionCap =
  grant acme-wf alice-exists
        (((tt , alice-exists) , acmeOrg-exists) , tt) refl

afterSelfPromotion : ExecOut doneD
afterSelfPromotion = execute selfPromotionCap (canonAlloc acme)

-- The authorized transition really escalates: Member before, Admin after.
selfPromotion-starts-member : authorityOf acme alice acmeOrg ≡ just memberR
selfPromotion-starts-member = refl

selfPromotion-ends-admin :
  authorityOf (postState afterSelfPromotion) alice acmeOrg ≡ just adminR
selfPromotion-ends-admin = refl

-- THE NEGATIVE THEOREM: that valid, authorized transition VIOLATES the
-- same NoSelfPrivilegeEscalation proposition the safe action satisfies
-- (the goal computes to `false ≡ true`, refuted by the absurd pattern).
changeRoleUnsafe-violates-no-self-escalation :
  ¬ NoSelfPrivilegeEscalation acme (postState afterSelfPromotion)
                              alice acmeOrg
changeRoleUnsafe-violates-no-self-escalation ()

-- Regression: the very same self-promotion request — same state, caller
-- and arguments — has NO capability for the SAFE action: its policy
-- refutes it (alice is not an Admin, and actor = target), so the
-- `policy-ok` field is uninhabited.
changeRole-denies-self-promotion :
  ¬ Capability acme (authC alice) selfPromotionArgs changeRole
changeRole-denies-self-promotion (grant _ _ _ ())
