#!/usr/bin/env bats
# lib/: the small helpers other scripts build on.

setup() {
	cd "$BATS_TEST_DIRNAME/.."
	tmp=$(mktemp -d)
	export SETTINGS_HOME="$tmp/cfg"
}

teardown() {
	rm -rf "$tmp"
}

# --- settings ----------------------------------------------------------

@test "settings: set then get round-trips, values may contain = and quotes" {
	run ./lib/settings set demo greeting "it's a=b"
	[ "$status" -eq 0 ]
	run ./lib/settings get demo greeting
	[ "$output" = "it's a=b" ]
}

@test "settings: unset key exits 1 without a default, prints the default with one" {
	run ./lib/settings get demo nope
	[ "$status" -eq 1 ]
	run ./lib/settings get demo nope fallback
	[ "$status" -eq 0 ]
	[ "$output" = fallback ]
}

@test "settings: environment variable APP_KEY wins over the file" {
	./lib/settings set demo theme dark
	DEMO_THEME=light run ./lib/settings get demo theme
	[ "$output" = light ]
}

@test "settings: set replaces instead of appending, unset removes" {
	./lib/settings set demo a 1
	./lib/settings set demo a 2
	./lib/settings set demo b 3
	run ./lib/settings list demo
	[ "$output" = "$(printf 'a=2\nb=3')" ]
	./lib/settings unset demo a
	run ./lib/settings list demo
	[ "$output" = "b=3" ]
}

@test "settings: the file is private (mode 600) and comments survive a write" {
	./lib/settings set demo a 1
	printf '# keep me\n' >> "$SETTINGS_HOME/demo/settings"
	./lib/settings set demo b 2
	[ "$(stat -c %a "$SETTINGS_HOME/demo/settings")" = 600 ]
	grep -q '^# keep me$' "$SETTINGS_HOME/demo/settings"
}

@test "settings: export is eval-safe even with quotes and command syntax" {
	./lib/settings set demo cmd "\$(touch $tmp/pwned); 'x'"
	eval "$(./lib/settings export demo)"
	[ "$DEMO_CMD" = "\$(touch $tmp/pwned); 'x'" ]
	[ ! -e "$tmp/pwned" ]
}

@test "settings: rejects bad app and key names" {
	run ./lib/settings set demo 'bad key' x
	[ "$status" -eq 2 ]
	run ./lib/settings get '../etc' key
	[ "$status" -eq 2 ]
}

# --- wizard ------------------------------------------------------------

@test "wizard: answers become eval-able assignments, empty answer takes the default" {
	printf '%s\n' 'name|Name' 'shell|Shell|bash,zsh,fish|zsh' > "$tmp/steps"
	printf '%s\n' "O'Neil" '' > "$tmp/ans"
	WIZARD_ANSWERS="$tmp/ans" run ./lib/wizard "$tmp/steps"
	[ "$status" -eq 0 ]
	eval "$output"
	[ "$name" = "O'Neil" ]
	[ "$shell" = zsh ]
}

@test "wizard: an answer outside the choices is an error" {
	printf '%s\n' 'shell|Shell|bash,zsh' > "$tmp/steps"
	printf 'fish\n' > "$tmp/ans"
	WIZARD_ANSWERS="$tmp/ans" run ./lib/wizard "$tmp/steps"
	[ "$status" -eq 2 ]
	[[ "$output" == *"not one of"* ]]
}

@test "wizard: a variable name that is not an identifier is refused (the output is eval'd)" {
	printf '%s\n' 'a b|Prompt' > "$tmp/steps"
	run ./lib/wizard "$tmp/steps"
	[ "$status" -eq 2 ]
}

@test "wizard: plain mode takes numbers for choices and goes back with <" {
	printf '%s\n' 'name|Name' 'shell|Shell|bash,zsh,fish' > "$tmp/steps"
	run sh -c "printf '%s\n' first '<' second 3 | WIZARD_PLAIN=1 ./lib/wizard '$tmp/steps' 2>/dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"name='second'"* ]]
	[[ "$output" == *"shell='fish'"* ]]
}

@test "wizard: end of input cancels with exit 1 and prints nothing" {
	printf '%s\n' 'name|Name' > "$tmp/steps"
	run sh -c "WIZARD_PLAIN=1 ./lib/wizard '$tmp/steps' < /dev/null 2>/dev/null"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

# --- evq ---------------------------------------------------------------

@test "evq: events come out in the order they went in, then the queue is empty" {
	export XDG_RUNTIME_DIR="$tmp"
	./lib/evq push -q t one
	./lib/evq push -q t two
	run ./lib/evq count -q t
	[ "$output" = 2 ]
	run ./lib/evq pop -q t
	[ "$output" = one ]
	run ./lib/evq pop -q t
	[ "$output" = two ]
	run ./lib/evq pop -q t
	[ "$status" -eq 1 ]
}

@test "evq: peek does not consume, clear empties the queue" {
	export XDG_RUNTIME_DIR="$tmp"
	./lib/evq push -q t one
	run ./lib/evq peek -q t
	[ "$output" = one ]
	run ./lib/evq count -q t
	[ "$output" = 1 ]
	./lib/evq clear -q t
	run ./lib/evq count -q t
	[ "$output" = 0 ]
}

@test "evq: a queue name with a slash is refused" {
	export XDG_RUNTIME_DIR="$tmp"
	run ./lib/evq push -q ../x boom
	[ "$status" -eq 2 ]
}

# --- dspq --------------------------------------------------------------

@test "dspq: downloads in parallel into place, atomically (no .part left)" {
	echo hello > "$tmp/src"
	run ./lib/dspq -j 2 --state "$tmp/st" "file://$tmp/src|$tmp/out/a|a" "file://$tmp/src|$tmp/out/b|b"
	[ "$status" -eq 0 ]
	[ "$(cat "$tmp/out/a")" = hello ]
	[ "$(cat "$tmp/out/b")" = hello ]
	[ -z "$(ls "$tmp/out" | grep '\.part$')" ]
	[[ "$(cat "$tmp/st/a")" == *done ]]
}

@test "dspq: a failing entry makes the queue exit non-zero, the good one still lands" {
	echo hello > "$tmp/src"
	run ./lib/dspq --state "$tmp/st" "file://$tmp/src|$tmp/out/ok|ok" "file://$tmp/missing|$tmp/out/bad|bad"
	[ "$status" -ne 0 ]
	[ -f "$tmp/out/ok" ]
	[ ! -e "$tmp/out/bad" ]
}

@test "dspq: input without url|dest entries is a usage error" {
	run ./lib/dspq -j 2 nonsense
	[ "$status" -eq 2 ]
}

# --- lazytui --------------------------------------------------------

@test "lazytui: _lt_trim strips both ends and keeps the inside" {
	run sh -c '. ./lib/lazytui; _lt_trim "   a  b   "'
	[ "$output" = "a  b" ]
}

@test "lazytui: _lt_hint draws a cap per modifier plus the label" {
	run sh -c '. ./lib/lazytui; _lt_hint ctrl-r Refresh'
	[[ "$output" == *Ctrl* ]]
	[[ "$output" == *" R "* ]]
	[[ "$output" == *Refresh* ]]
}

@test "lazytui: lt_select rejects unknown options instead of ignoring them" {
	run sh -c '. ./lib/lazytui; lt_select --nope x </dev/null'
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown arg"* ]]
}

@test "lazytui: lt_realbin skips the script itself and finds the real binary" {
	mkdir "$tmp/bin" "$tmp/real"
	printf '#!/bin/sh\n. "%s/lib/lazytui"\nlt_realbin mytool\n' "$PWD" > "$tmp/bin/mytool"
	chmod +x "$tmp/bin/mytool"
	printf '#!/bin/sh\necho real\n' > "$tmp/real/mytool"
	chmod +x "$tmp/real/mytool"
	PATH="$tmp/bin:$tmp/real:$PATH" run mytool
	[ "$status" -eq 0 ]
	[ "$output" = "$tmp/real/mytool" ]
}
