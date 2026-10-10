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
			*python*) continue ;; # bdfeditor - not a shell script
		esac
		case "$shebang" in
			*/sh|*env\ sh) sh -n "$f" ;;
			*) bash -n "$f" ;;
		esac
	done
}

@test "every installer/ script parses" {
	for f in installer/*; do
		[ -f "$f" ] && [ -x "$f" ] || continue
		bash -n "$f"
	done
}
