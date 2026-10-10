#!/usr/bin/env bats
# Behavior tests for the tools that don't need a GUI/network/root to
# exercise their real logic - error paths, passthrough, dispatch.

setup() {
	cd "$BATS_TEST_DIRNAME/.."
}

@test "metadata_cleaner: usage error with no args" {
	run ./metadata_cleaner
	[ "$status" -eq 2 ]
}

@test "metadata_cleaner: clean error on missing file" {
	run ./metadata_cleaner /no/such/file
	[ "$status" -eq 1 ]
	[[ "$output" == *"no such file"* ]]
}

@test "metadata_cleaner: strips an image via ImageMagick fallback" {
	tmp=$(mktemp -d)
	convert -size 4x4 xc:red "$tmp/in.png"
	run ./metadata_cleaner "$tmp/in.png"
	[ "$status" -eq 0 ]
	[ -f "$tmp/clean-in.png" ]
	rm -rf "$tmp"
}

@test "sniff: clear error when tcpdump missing" {
	run ./sniff
	[ "$status" -eq 1 ]
	[[ "$output" == *"tcpdump"* ]]
}

@test "nmap: passthrough mode reaches the real nmap" {
	run ./nmap -- --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nmap version"* ]]
}

@test "nmap: unknown preset is a clean error, not a crash" {
	run ./nmap nope some-host
	[ "$status" -eq 2 ]
}

@test "gitgrab: usage error with no args" {
	run ./gitgrab
	[ "$status" -eq 2 ]
}

@test "gitgrab: repo without a path is a clean error" {
	run ./gitgrab owner/repo
	[ "$status" -eq 2 ]
	[[ "$output" == *"PATH"* ]]
}

@test "gitgrab: refuses to overwrite an existing file" {
	tmp=$(mktemp -d)
	echo keep > "$tmp/x"
	run ./gitgrab owner/repo x -o "$tmp/x"
	[ "$status" -eq 1 ]
	[[ "$output" == *"exists"* ]]
	[ "$(cat "$tmp/x")" = keep ]
	rm -rf "$tmp"
}

@test "logcollector: summary-only run writes no archive" {
	tmp=$(mktemp -d)
	run ./logcollector -n -s "1 hour ago" -o "$tmp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"logcollector summary"* ]]
	[ -z "$(ls -A "$tmp")" ]
	rm -rf "$tmp"
}

@test "logcollector: redacts tokens, passwords and private keys" {
	tmp=$(mktemp -d)
	eval "$(sed -n '/^redact() {/,/^}/p' ./logcollector)"
	redact_ip=0
	out=$(printf '%s\n' \
		'x ghp_abcdefghijklmnopqrstuvwxyz0123456789 y' \
		'db password=hunter2 ok' \
		'-----BEGIN OPENSSH PRIVATE KEY-----' 'AAAAsecret' '-----END OPENSSH PRIVATE KEY-----' \
		'plain line' | redact)
	[[ "$out" != *ghp_abc* ]]
	[[ "$out" != *hunter2* ]]
	[[ "$out" != *AAAAsecret* ]]
	[[ "$out" == *"plain line"* ]]
	rm -rf "$tmp"
}

@test "manwriter: builds a man page from a script header" {
	tmp=$(mktemp -d)
	printf '%s\n' '#!/bin/sh' '# <manwriter>' '# demo - does a thing' '#' '# usage: demo' '# @flag -v:be loud' '# </manwriter>' > "$tmp/demo"
	run ./manwriter -d "$tmp" "$tmp/demo"
	[ "$status" -eq 0 ]
	grep -q '^.SH NAME' "$tmp/demo.1"
	grep -q 'does a thing' "$tmp/demo.1"
	grep -q 'be loud' "$tmp/demo.1"
	rm -rf "$tmp"
}
