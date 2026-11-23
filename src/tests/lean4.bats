#!/usr/bin/env bats
# lean4/check: proofs that compile pass, a sorry or a broken file fails. Skipped without a lean toolchain.

setup() {
	command -v lean > /dev/null || ls "$HOME"/.elan/toolchains/*/bin/lean > /dev/null 2>&1 || skip "no lean"
	cp "$BATS_TEST_DIRNAME/../lean4/check" "$BATS_TEST_TMPDIR/check"
	cd "$BATS_TEST_TMPDIR" || return
}

@test "a proved theorem passes" {
	printf 'theorem t (a b : Nat) : a + b = b + a := Nat.add_comm a b\n' > ok.lean
	run ./check ok.lean
	[ "$status" -eq 0 ]
	[[ $output == "ok   ok.lean" ]]
}

@test "sorry fails" {
	printf 'theorem t (a : Nat) : a = a := by sorry\n' > s.lean
	run ./check s.lean
	[ "$status" -eq 1 ]
	[[ $output == *sorry* ]]
}

@test "a type error fails" {
	printf 'theorem t : 1 = 2 := rfl\n' > bad.lean
	run ./check bad.lean
	[ "$status" -eq 1 ]
	[[ $output == "FAIL bad.lean"* ]]
}

@test "an unexpected axiom fails" {
	printf 'axiom evil : False\ntheorem t : False := evil\n#print axioms t\n' > ax.lean
	run ./check ax.lean
	[ "$status" -eq 1 ]
	[[ $output == *axiom* ]]
}

@test "a missing file is reported" {
	run ./check nope.lean
	[ "$status" -eq 1 ]
}
