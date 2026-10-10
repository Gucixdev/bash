#!/usr/bin/env bats
# Behavior tests for the tools that don't need a GUI/network/root to
# exercise their real logic - error paths, passthrough, dispatch.

setup() {
	cd "$BATS_TEST_DIRNAME/.."
}

@test "ghidra: clear error when not installed" {
	run ./ghidra
	[ "$status" -eq 1 ]
	[[ "$output" == *"pacman -S ghidra"* ]]
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

@test "ezlink: report mode never touches anything (dry run by default)" {
	run ./ezlink report
	[ "$status" -eq 0 ]
}
