#!/usr/bin/env bats
# bake: bakefile translation without any engine; build, rootfs and VM boot when podman/docker, a local base image and qemu exist.

setup() {
	cd "$BATS_TEST_DIRNAME/.."
	T=$BATS_TEST_TMPDIR
	export XDG_STATE_HOME=$T/state
	BASE=${BAKE_TEST_BASE:-docker.io/library/postgres:17-alpine}
}

need_engine() {
	local e
	for e in podman docker; do
		if command -v $e > /dev/null && $e image exists "$BASE" 2> /dev/null || $e image inspect "$BASE" > /dev/null 2>&1; then return 0; fi
	done
	skip "no podman/docker with $BASE present locally (set BAKE_TEST_BASE)"
}

@test "bake: show turns directives into a Containerfile, package family guessed from the base" {
	cat > "$T/bakefile" << 'E2'
# comment
name x
base docker.io/library/debian:12
pkg curl jq
env A=1
workdir /w
copy a b
run echo hi
user nobody
cmd ["sh"]
check true => nothing
E2
	run ./bake show "$T/bakefile"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "FROM docker.io/library/debian:12" ]
	[[ "${lines[1]}" == "RUN apt-get update && apt-get install -y --no-install-recommends curl jq"* ]]
	[[ "$output" == *$'ENV A=1\nWORKDIR /w\nCOPY a b\nRUN echo hi\nUSER nobody\nCMD ["sh"]'* ]]
	[[ "$output" != *check* ]]
}

@test "bake: alpine, arch and fedora get their own package managers; an unknown base needs family" {
	printf 'base alpine:3.20\npkg git\n' > "$T/a"; run ./bake show "$T/a"; [[ "$output" == *"apk add --no-cache git" ]]
	printf 'base archlinux\npkg git\n' > "$T/b"; run ./bake show "$T/b"; [[ "$output" == *"pacman -Sy --noconfirm --needed git"* ]]
	printf 'base fedora:41\npkg git\n' > "$T/c"; run ./bake show "$T/c"; [[ "$output" == *"dnf install -y git"* ]]
	printf 'base foo/bar\npkg git\n' > "$T/d"; run ./bake show "$T/d"; [ "$status" -eq 1 ]; [[ "$output" == *"unknown package family"* ]]
	printf 'base foo/bar\nfamily apk\npkg git\n' > "$T/e"; run ./bake show "$T/e"; [ "$status" -eq 0 ]
}

@test "bake: errors name the line; a bakefile without base is refused" {
	printf 'base x\nfrobnicate 1\n' > "$T/f"; run ./bake show "$T/f"
	[ "$status" -eq 1 ]; [[ "$output" == *"line 2: unknown directive 'frobnicate'"* ]]
	printf 'name y\n' > "$T/g"; run ./bake show "$T/g"
	[ "$status" -eq 1 ]; [[ "$output" == *"no base line"* ]]
	run ./bake show "$T/missing"
	[ "$status" -eq 1 ]
}

@test "bake: new writes a starter that shows cleanly, and does not overwrite" {
	cd "$T"
	run "$BATS_TEST_DIRNAME/../bake" new proj
	[ -f proj/bakefile ]
	run "$BATS_TEST_DIRNAME/../bake" show proj
	[ "$status" -eq 0 ]
	run "$BATS_TEST_DIRNAME/../bake" new proj
	[ "$status" -eq 1 ]
}

@test "bake: no arguments for usage gives help, an unknown command exits 2" {
	run ./bake --help
	[ "$status" -eq 0 ]; [[ "$output" == *"bake build [FILE]"* ]]
	run ./bake nonsense
	[ "$status" -eq 2 ]
}

@test "bake: build runs the checks, a failing check exits 1, rootfs exports the filesystem" {
	need_engine
	mkdir "$T/p"
	printf 'name bake-bats\nbase %s\nenv G=hi\nrun echo built-$G > /built\ncheck cat /built => built-hi\n' "$BASE" > "$T/p/bakefile"
	run ./bake build "$T/p"
	[ "$status" -eq 0 ]; [[ "$output" == *"check ok:   cat /built => built-hi"* ]]
	printf 'check true => never\n' >> "$T/p/bakefile"
	run ./bake build "$T/p"
	[ "$status" -eq 1 ]; [[ "$output" == *"check FAIL"* ]]
	sed -i '/never/d' "$T/p/bakefile"
	run ./bake rootfs "$T/p" "$T/root.tar"
	[ "$status" -eq 0 ]
	[ "$(tar -xOf "$T/root.tar" built)" = "built-hi" ]
	run ./bake run bake-bats cat /built
	[ "$output" = "built-hi" ]
}

@test "bake: qcow makes a disk and refuses to overwrite" {
	command -v qemu-img > /dev/null || skip "no qemu-img"
	run ./bake qcow "$T/d.qcow2" 64M
	[ "$status" -eq 0 ]
	qemu-img info "$T/d.qcow2" | grep -q "file format: qcow2"
	run ./bake qcow "$T/d.qcow2" 64M
	[ "$status" -eq 1 ]
}

@test "bake: vm boots a kernel headless, shows in ls, log has the console, stop ends it" {
	command -v qemu-system-"$(uname -m)" > /dev/null || skip "no qemu"
	k=$(ls /usr/lib/modules/*/vmlinuz /boot/vmlinuz* 2> /dev/null | tail -1)
	[ -r "$k" ] || skip "no readable kernel"
	run ./bake vm start t --kernel "$k" --ram 256M --cpus 1
	[ "$status" -eq 0 ]
	run ./bake vm ls
	[[ "$output" == *$'t\trunning'* ]]
	for _ in 1 2 3 4 5 6 7 8; do ./bake vm log t | grep -q "Kernel panic\|Linux version" && break; sleep 1; done
	run ./bake vm log t
	[[ "$output" == *"Kernel panic"* || "$output" == *"Linux version"* ]]
	run ./bake vm start t --kernel "$k"
	[ "$status" -eq 1 ]; [[ "$output" == *"already running"* ]]
	run ./bake vm stop t
	[ "$status" -eq 0 ]
	run ./bake vm ls
	[[ "$output" == *$'t\tstopped'* ]]
}
