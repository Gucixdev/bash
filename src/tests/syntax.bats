#!/usr/bin/env bats
# Every executable script in this repo must at least parse cleanly -
# the cheapest possible real test, catches typos before anything else.

setup() {
	cd "$BATS_TEST_DIRNAME/.."
}

@test "every executable top-level script parses (sh -n or bash -n)" {
	for f in *; do
		[ -f "$f" ] && [ -x "$f" ] || continue
		shebang=$(head -1 "$f")
		case "$shebang" in
			*/sh|*env\ sh) sh -n "$f" ;;
			*) bash -n "$f" ;;
		esac
	done
}

@test "every launchers/ script parses" {
	for f in launchers/blenderlauncher/blenderlauncher launchers/comfylauncher/comfylauncher \
		launchers/protonlauncher/protonlauncher launchers/templeos/templeos; do
		[ -f "$f" ] && [ -x "$f" ] || continue
		bash -n "$f"
	done
}

@test "launchers/comfylauncher/comfylauncher parses" {
	bash -n launchers/comfylauncher/comfylauncher
}

@test "every top-level tool answers --help from its header" {
	for f in btth cleaner ezcontainers flatseal metadata_cleaner scenario sniff todo trash wifi \
		hf gh screenshot logbucket manwriter findfat morph fixmedia skilltree claude_maintain; do
		run ./"$f" --help
		[ "$status" -eq 0 ]
		[ -n "$output" ]
	done
}

@test "shellcheck: no warnings or errors" {
	command -v shellcheck >/dev/null || skip "shellcheck not installed"
	run shellcheck -S warning btth cleaner ezcontainers findfat fixmedia flatseal gh hf logbucket \
		manwriter metadata_cleaner morph scenario screenshot sniff todo trash wifi \
		launchers/blenderlauncher/blenderlauncher launchers/comfylauncher/comfylauncher \
		launchers/protonlauncher/protonlauncher templates/*
	[ "$status" -eq 0 ]
}
