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
	printf '%s\n' '#!/bin/sh' '# demo - does a thing' '#' '# usage: demo' '# @flag -v:be loud' '' 'echo hi' > "$tmp/demo"
	run ./manwriter -d "$tmp" "$tmp/demo"
	[ "$status" -eq 0 ]
	grep -q '^.SH NAME' "$tmp/demo.1"
	grep -q 'does a thing' "$tmp/demo.1"
	grep -q 'be loud' "$tmp/demo.1"
	rm -rf "$tmp"
}

@test "sniff: summarizes tcpdump text from stdin" {
	run sh -c "printf '%s\n' \
		'1696953601.1 IP 192.168.1.10.54321 > 142.250.74.46.443: Flags [P.], seq 1:518, ack 1, win 502, length 517' \
		'1696953601.3 IP 192.168.1.10.41234 > 192.168.1.1.53: 12345+ A? example.com. (29)' \
		| ./sniff -"
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 packets"* ]]
	[[ "$output" == *"tcp/https (443)"* ]]
	[[ "$output" == *"example.com."* ]]
}

@test "findfat: lists the biggest file first" {
	tmp=$(mktemp -d)
	dd if=/dev/zero of="$tmp/big" bs=1k count=64 2>/dev/null
	dd if=/dev/zero of="$tmp/small" bs=1k count=1 2>/dev/null
	run ./findfat -file -n 1 "$tmp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/big"* ]]
	[[ "$output" != *"/small"* ]]
	rm -rf "$tmp"
}

@test "morph: refuses to overwrite and to cross kinds" {
	tmp=$(mktemp -d)
	: > "$tmp/a.png"; : > "$tmp/b.png"
	run ./morph "$tmp/a.png" "$tmp/b.png"
	[ "$status" -eq 1 ]
	[[ "$output" == *"exists"* ]]
	run ./morph "$tmp/a.png" "$tmp/a.mp3"
	[ "$status" -eq 1 ]
	[[ "$output" == *"cannot convert"* ]]
	rm -rf "$tmp"
}

@test "fixmedia: -c reports a healthy image as ok" {
	command -v convert >/dev/null || command -v magick >/dev/null || skip "ImageMagick not installed"
	tmp=$(mktemp -d)
	convert -size 4x4 xc:red "$tmp/a.png" 2>/dev/null || magick -size 4x4 xc:red "$tmp/a.png"
	run ./fixmedia -c "$tmp/a.png"
	[ "$status" -eq 0 ]
	[[ "$output" == ok* ]]
	rm -rf "$tmp"
}
