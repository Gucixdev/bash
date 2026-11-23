/-
  Model of the `repos` tool (../repos): what pull and push may do to the commits of a branch.
  A branch is the list of commits reachable from its tip (a commit is a Nat). The claims proved here:
    * pull never loses a local commit and never moves the local branch except by a fast-forward;
    * a fast-forward happens only when the tree is clean and the remote is strictly ahead;
    * when both sides moved, the local branch is unchanged and the remote's commits land on a needmerge branch;
    * a needmerge branch is only moved forward (old commits stay reachable) or a new one is added;
    * push never removes a remote commit, and pushes only when we are strictly ahead (never forced).
  Model, not the bash: the bash maps to it as `probe` (kind) -> `pull`/`push` (the case arms).
-/

def ahead (L R : List Nat) : Bool := L.any (fun x => !R.contains x)
def behind (L R : List Nat) : Bool := R.any (fun x => !L.contains x)

inductive Kind | synced | ahead | behind | diverged
  deriving DecidableEq

def kind (L R : List Nat) : Kind :=
  match ahead L R, behind L R with
  | true, true => .diverged
  | true, false => .ahead
  | false, true => .behind
  | false, false => .synced

/-- needmerge branch handling: (main needmerge/BR, extra suffixed ones) -/
def toNm (nm : Option (List Nat)) (extra : List (List Nat)) (R : List Nat) :
    Option (List Nat) × List (List Nat) :=
  match nm with
  | none => (some R, extra)
  | some c =>
    if c == R then (some c, extra)
    else if c.all R.contains then (some R, extra)   -- c is an ancestor of the remote: moved forward
    else (some c, R :: extra)                       -- unrelated: a new branch, nothing moved

/-- pull: new local branch and the needmerge state. `dirty` = tracked files changed. -/
def pull (dirty : Bool) (L R : List Nat) (nm : Option (List Nat)) (extra : List (List Nat)) :
    List Nat × Option (List Nat) × List (List Nat) :=
  match kind L R with
  | .synced | .ahead => (L, nm, extra)
  | .diverged => let (n, e) := toNm nm extra R; (L, n, e)
  | .behind => if dirty then (L, nm, extra) else (R, nm, extra)

/-- push: new remote branch. Only when strictly ahead, and then the remote becomes our branch (a fast-forward). -/
def push (L R : List Nat) : List Nat :=
  match kind L R with
  | .ahead => L
  | _ => R

def held (nm : Option (List Nat)) (extra : List (List Nat)) (x : Nat) : Prop :=
  (∃ c, nm = some c ∧ x ∈ c) ∨ ∃ b ∈ extra, x ∈ b

theorem ahead_false {L R : List Nat} (h : ahead L R = false) : ∀ x ∈ L, x ∈ R := by
  intro x hx
  simp only [ahead, List.any_eq_false] at h
  have := h x hx
  simpa using this

theorem behind_false {L R : List Nat} (h : behind L R = false) : ∀ x ∈ R, x ∈ L := by
  intro x hx
  simp only [behind, List.any_eq_false] at h
  have := h x hx
  simpa using this

/-- pull: no local commit is ever lost. -/
theorem pull_keeps_local (dirty : Bool) (L R : List Nat) (nm extra) :
    ∀ x ∈ L, x ∈ (pull dirty L R nm extra).1 := by
  intro x hx
  unfold pull
  cases hk : kind L R <;> simp only [] <;> try exact hx
  case behind =>
    have hb : ahead L R = false := by
      unfold kind at hk; split at hk <;> simp_all
    cases dirty <;> simp [hx, ahead_false hb x hx]
  
/-- pull moves the local branch only by a fast-forward: clean tree, remote strictly ahead of us. -/
theorem pull_moves_only_ff (dirty : Bool) (L R : List Nat) (nm extra)
    (h : (pull dirty L R nm extra).1 ≠ L) : dirty = false ∧ kind L R = .behind ∧ (pull dirty L R nm extra).1 = R := by
  unfold pull at *
  cases hk : kind L R <;> simp [hk] at h ⊢
  case behind => cases dirty <;> simp_all

/-- both sides moved: the local branch is untouched. -/
theorem pull_diverged_local (dirty : Bool) (L R : List Nat) (nm extra) (h : kind L R = .diverged) :
    (pull dirty L R nm extra).1 = L := by
  simp [pull, h]

/-- both sides moved: every remote commit ends up on some needmerge branch. -/
theorem pull_diverged_holds_remote (dirty : Bool) (L R : List Nat) (nm extra) (h : kind L R = .diverged) :
    ∀ x ∈ R, held (pull dirty L R nm extra).2.1 (pull dirty L R nm extra).2.2 x := by
  intro x hx
  simp only [pull, h, toNm]
  cases nm with
  | none => exact Or.inl ⟨R, rfl, hx⟩
  | some c =>
    by_cases h1 : (c == R) = true
    · simp only [h1, if_true]
      have : c = R := by simpa using h1
      exact Or.inl ⟨c, rfl, this ▸ hx⟩
    · by_cases h2 : c.all R.contains = true
      · simp only [h1, h2, if_true]; exact Or.inl ⟨R, rfl, hx⟩
      · simp only [h1, h2]; exact Or.inr ⟨R, by simp, hx⟩

/-- needmerge never forgets: every commit held before is still held after. -/
theorem pull_nm_keeps (dirty : Bool) (L R : List Nat) (nm extra) :
    ∀ x, held nm extra x → held (pull dirty L R nm extra).2.1 (pull dirty L R nm extra).2.2 x := by
  intro x hx
  unfold pull
  cases hk : kind L R <;> simp only []
  all_goals first | exact hx | skip
  case behind => cases dirty <;> simpa using hx
  case diverged =>
    simp only [toNm]
    cases nm with
    | none => rcases hx with ⟨c, hc, _⟩ | ⟨b, hb, hxb⟩ <;> first | cases hc | exact Or.inr ⟨b, hb, hxb⟩
    | some c =>
      by_cases h1 : (c == R) = true
      · simpa [h1] using hx
      · by_cases h2 : c.all R.contains = true
        · simp only [h1, h2, if_true]
          rcases hx with ⟨c', hc', hxc⟩ | ⟨b, hb, hxb⟩
          · have : c' = c := by simpa using hc'.symm
            subst this
            exact Or.inl ⟨R, rfl, by simpa using (List.all_eq_true.mp h2 x hxc)⟩
          · exact Or.inr ⟨b, hb, hxb⟩
        · simp only [h1, h2]
          rcases hx with ⟨c', hc', hxc⟩ | ⟨b, hb, hxb⟩
          · exact Or.inl ⟨c', hc', hxc⟩
          · exact Or.inr ⟨b, by simp [hb], hxb⟩

/-- push: no remote commit is lost, and it only changes the remote when we are strictly ahead. -/
theorem push_keeps_remote (L R : List Nat) : ∀ x ∈ R, x ∈ push L R ∨ kind L R = .ahead := by
  intro x hx
  unfold push
  cases hk : kind L R <;> simp [hx]

theorem push_ahead_keeps_remote (L R : List Nat) (h : kind L R = .ahead) : ∀ x ∈ R, x ∈ push L R := by
  intro x hx
  have hb : behind L R = false := by
    unfold kind at h; split at h <;> simp_all
  simp only [push, h]
  exact behind_false hb x hx

theorem push_not_ahead (L R : List Nat) (h : kind L R ≠ .ahead) : push L R = R := by
  unfold push; cases hk : kind L R <;> simp_all

-- the model is not vacuous: concrete runs
#eval kind [1,2,3] [1,2]            -- ahead
#eval kind [1,2] [1,2,3]            -- behind
#eval kind [1,2,4] [1,2,3]          -- diverged
#eval (pull false [1,2] [1,2,3] none []).1     -- [1, 2, 3]: fast-forward
#eval (pull true  [1,2] [1,2,3] none []).1     -- [1, 2]: dirty tree, untouched
#eval (pull false [1,2,4] [1,2,3] none [])     -- local kept, remote on needmerge

#print axioms pull_keeps_local
#print axioms pull_moves_only_ff
#print axioms pull_diverged_local
#print axioms pull_diverged_holds_remote
#print axioms pull_nm_keeps
#print axioms push_keeps_remote
#print axioms push_ahead_keeps_remote
#print axioms push_not_ahead
