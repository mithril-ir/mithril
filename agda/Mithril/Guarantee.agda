{-# OPTIONS --safe #-}

-- Mithril Agda spike: the fixed-schema NoSelfPrivilegeEscalation
-- proposition.
--
-- This module states, over the spike's FIXED schema, what the JSON
-- guarantee object
--
--   { kind: NoSelfPrivilegeEscalation,
--     authority: { relation: Membership, subjectEndpoint: user,
--                  scopeEndpoints: [organization],
--                  absenceLevel: Bottom, payloadOrder: MembershipRole } }
--
-- means for ONE transition: the subject's own Membership payload in the
-- scope organization, ordered with absence as bottom
-- (nothing < Member < Admin), must not increase from pre- to post-state.
--
-- SPECIALIZED FOR THE SPIKE: the authority relation (Membership), subject
-- kind (User), scope kind (Organization) and payload order (Role) are the
-- fixed-schema ones; a full kernel would draw them from the guarantee's
-- authority declaration.  No JSON is consumed here and no automated
-- verifier exists: `Mithril.Acme` instantiates this proposition for one
-- hand-transcribed action only.

module Mithril.Guarantee where

open import Mithril.Base
open import Mithril.Core

-- Small propositional helpers -------------------------------------------------
--
-- Generic facts about `Mithril.Base`/`Mithril.Core` functions needed by
-- the guarantee slice, kept here to leave the kernel modules untouched.
-- Their Bool/Nat arguments are EXPLICIT on purpose: callers instantiate
-- them with stuck evaluation results that unification could not infer
-- through the non-injective `_&&_`.

&&-false-absurd : ∀ b → (b && false) ≡ true → ⊥
&&-false-absurd true  ()
&&-false-absurd false ()

eqNat-refl : ∀ n → eqNat n n ≡ true
eqNat-refl zero    = refl
eqNat-refl (suc n) = eqNat-refl n

-- Authority -------------------------------------------------------------------

-- The authority of a subject User in a scope Organization: the Membership
-- payload, with absence (`nothing`) as the declared Bottom level.
Authority : Set
Authority = Maybe Role

authorityOf : State → EntityRef UserK → EntityRef OrgK → Authority
authorityOf s u o = lookupMem s u o

-- The authority order declared by the guarantee: the MembershipRole enum
-- order lifted to Maybe with absence as bottom — nothing < Member < Admin.
authLeq : Authority → Authority → Bool
authLeq = leqVal (maybe-ord role-ord)

-- The intended strict chain, as checked equations:
nothing≤member : authLeq nothing (just memberR) ≡ true
nothing≤member = refl

member≰nothing : authLeq (just memberR) nothing ≡ false
member≰nothing = refl

member≤admin : authLeq (just memberR) (just adminR) ≡ true
member≤admin = refl

admin≰member : authLeq (just adminR) (just memberR) ≡ false
admin≰member = refl

authLeq-refl : ∀ l → authLeq l l ≡ true
authLeq-refl nothing        = refl
authLeq-refl (just memberR) = refl
authLeq-refl (just adminR)  = refl

-- The proposition ---------------------------------------------------------------

-- NoSelfPrivilegeEscalation for one transition, subject and scope: the
-- subject's own authority in the scope does not increase — post ≤ pre in
-- the (total) authority order, i.e. the level is "not raised".
NoSelfPrivilegeEscalation : (pre post : State)
                          → EntityRef UserK → EntityRef OrgK → Set
NoSelfPrivilegeEscalation pre post subj scope =
  authLeq (authorityOf post subj scope) (authorityOf pre subj scope) ≡ true

-- The stronger route used by the positive proof: a transition that leaves
-- the subject's authority tuple exactly unchanged never escalates it.
-- (All arguments are explicit: they occur in the statement only under
-- `membership _ (ix _) (ix _)`, where unification cannot recover them.)
authority-unchanged→no-escalation :
  ∀ pre post subj scope
  → authorityOf post subj scope ≡ authorityOf pre subj scope
  → NoSelfPrivilegeEscalation pre post subj scope
authority-unchanged→no-escalation pre post subj scope eq =
  trans (cong (λ l → authLeq l (authorityOf pre subj scope)) eq)
        (authLeq-refl (authorityOf pre subj scope))
