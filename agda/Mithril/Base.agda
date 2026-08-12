{-# OPTIONS --safe #-}

-- Mithril Agda spike: minimal prelude.
--
-- The spike is restricted to Agda builtins (no external library), so the
-- handful of standard facts it needs — negation, sums, products, ordering
-- on Nat, decidable equality — are defined here.

module Mithril.Base where

open import Agda.Builtin.Nat public using (Nat; zero; suc)
open import Agda.Builtin.Bool public using (Bool; true; false)
open import Agda.Builtin.Equality public using (_≡_; refl)
open import Agda.Builtin.Unit public using (⊤; tt)
open import Agda.Builtin.Maybe public using (Maybe; just; nothing)
open import Agda.Builtin.Sigma public using (Σ; _,_; fst; snd)

infixr 2 _×_
infixr 1 _⊎_
infix 4 _≤_ _<_ _≟_

-- Empty type and negation ---------------------------------------------------

data ⊥ : Set where

¬_ : Set → Set
¬ A = A → ⊥

absurd : {A : Set} → ⊥ → A
absurd ()

-- Sums and products ----------------------------------------------------------

data _⊎_ (A B : Set) : Set where
  inl : A → A ⊎ B
  inr : B → A ⊎ B

_×_ : Set → Set → Set
A × B = Σ A (λ _ → B)

-- Equality helpers -----------------------------------------------------------

sym : {A : Set} {x y : A} → x ≡ y → y ≡ x
sym refl = refl

trans : {A : Set} {x y z : A} → x ≡ y → y ≡ z → x ≡ z
trans refl q = q

cong : {A B : Set} (f : A → B) {x y : A} → x ≡ y → f x ≡ f y
cong f refl = refl

subst : {A : Set} (P : A → Set) {x y : A} → x ≡ y → P x → P y
subst P refl p = p

-- Booleans -------------------------------------------------------------------

_&&_ : Bool → Bool → Bool
true  && b = b
false && _ = false

_||_ : Bool → Bool → Bool
true  || _ = true
false || b = b

notB : Bool → Bool
notB true  = false
notB false = true

eqBool : Bool → Bool → Bool
eqBool true  true  = true
eqBool false false = true
eqBool true  false = false
eqBool false true  = false

isJust : {A : Set} → Maybe A → Bool
isJust (just _) = true
isJust nothing  = false

-- Ordering on Nat ------------------------------------------------------------

data _≤_ : Nat → Nat → Set where
  z≤n : ∀ {n} → zero ≤ n
  s≤s : ∀ {m n} → m ≤ n → suc m ≤ suc n

_<_ : Nat → Nat → Set
m < n = suc m ≤ n

≤-refl : ∀ {n} → n ≤ n
≤-refl {zero}  = z≤n
≤-refl {suc n} = s≤s ≤-refl

≤-step : ∀ {m n} → m ≤ n → m ≤ suc n
≤-step z≤n     = z≤n
≤-step (s≤s p) = s≤s (≤-step p)

≤-trans : ∀ {m n p} → m ≤ n → n ≤ p → m ≤ p
≤-trans z≤n     _       = z≤n
≤-trans (s≤s a) (s≤s b) = s≤s (≤-trans a b)

<-irrefl : ∀ {n} → ¬ (n < n)
<-irrefl (s≤s p) = <-irrefl p

≤-pred : ∀ {m n} → suc m ≤ suc n → m ≤ n
≤-pred (s≤s p) = p

-- Every m ≤ n is either strict or an equality.
≤→<⊎≡ : ∀ {m n} → m ≤ n → (m < n) ⊎ (m ≡ n)
≤→<⊎≡ (z≤n {zero})  = inr refl
≤→<⊎≡ (z≤n {suc n}) = inl (s≤s z≤n)
≤→<⊎≡ (s≤s p) with ≤→<⊎≡ p
... | inl q = inl (s≤s q)
... | inr q = inr (cong suc q)

-- Decidable equality on Nat --------------------------------------------------

data Dec (A : Set) : Set where
  yes : A   → Dec A
  no  : ¬ A → Dec A

suc-injective : ∀ {m n} → suc m ≡ suc n → m ≡ n
suc-injective refl = refl

_≟_ : (m n : Nat) → Dec (m ≡ n)
zero  ≟ zero  = yes refl
zero  ≟ suc n = no (λ ())
suc m ≟ zero  = no (λ ())
suc m ≟ suc n with m ≟ n
... | yes p = yes (cong suc p)
... | no np = no (λ q → np (suc-injective q))

-- Decision combinator: pick a value from a decision, without pattern-matching
-- lambdas, so functions defined with it unfold cleanly in proofs.
decIf : {A X : Set} → Dec A → X → X → X
decIf (yes _) x _ = x
decIf (no _)  _ y = y
