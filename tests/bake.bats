#!/usr/bin/env bats
# bake: .bake file translation without any engine; build, rootfs and VM boot when podman/docker, a local base image and qemu exist.

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
	cat > "$T/x.bake" << 'E2'
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
	run ./bake show "$T/x.bake"
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

@test "bake: new writes NAME.bake; several .bake files sit side by side and ls lists them" {
	cd "$T"
	B="$BATS_TEST_DIRNAME/../bake"
	run "$B" new web
	[ -f web.bake ]
	run "$B" new db
	run "$B" new web
	[ "$status" -eq 1 ]
	run "$B" ls
	[ "$output" = $'db\t./db.bake\nweb\t./web.bake' ]
	run "$B" show web
	[ "$status" -eq 0 ]; [ "${lines[0]}" = "FROM docker.io/library/alpine:3.20" ]
	run "$B" show db.bake
	[ "$status" -eq 0 ]
}

@test "bake: a directory with one .bake file works, with several it asks which, the old bakefile name still works" {
	cd "$T"
	B="$BATS_TEST_DIRNAME/../bake"
	mkdir one many old
	printf 'base x\n' > one/a.bake
	printf 'base x\n' > many/a.bake; printf 'base y\n' > many/b.bake
	printf 'base z\n' > old/bakefile
	run "$B" show one;  [ "$status" -eq 0 ]; [ "$output" = "FROM x" ]
	run "$B" show many; [ "$status" -eq 1 ]; [[ "$output" == *"several .bake files"* && "$output" == *"a.bake b.bake"* ]]
	run "$B" show many/b; [ "$output" = "FROM y" ]
	run "$B" show old;  [ "$output" = "FROM z" ]
	run "$B" show empty_dir_that_does_not_exist; [ "$status" -eq 1 ]
}

@test "bake: no arguments for usage gives help, an unknown command exits 2" {
	run ./bake --help
	[ "$status" -eq 0 ]; [[ "$output" == *"bake build [--pull] [FILE]"* ]]
	run ./bake nonsense
	[ "$status" -eq 2 ]
}

@test "bake: build runs the checks, a failing check exits 1, rootfs exports the filesystem" {
	need_engine
	mkdir "$T/p"
	printf 'base %s\nenv G=hi\nrun echo built-$G > /built\ncheck cat /built => built-hi\n' "$BASE" > "$T/p/bake-bats.bake"
	run ./bake build "$T/p"
	[ "$status" -eq 0 ]; [[ "$output" == *"check ok:   cat /built => built-hi"* ]]
	printf 'check true => never\n' >> "$T/p/bake-bats.bake"
	run ./bake build "$T/p"
	[ "$status" -eq 1 ]; [[ "$output" == *"check FAIL"* ]]
	sed -i '/never/d' "$T/p/bake-bats.bake"
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

# a local upstream repo with one commit; bake_commit adds another
mkrepo() {
	R=$T/upstream; git init -q -b main "$R"
	git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
	printf 'one\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -qm one
}
bump() { printf '%s\n' "$1" > "$R/f"; git -C "$R" commit -qam "$1"; }

@test "bake: a git line becomes COPY --from=src0 with the upstream commit in a label, and sources follow upstream" {
	mkrepo; mkdir "$T/g"
	printf 'base scratch\ngit file://%s main /app\n' "$R" > "$T/g/g.bake"
	run ./bake show "$T/g/g.bake"; [ "$status" -eq 0 ]; [[ "$output" == *"COPY --from=src0 / /app"* && "$output" == *unsynced* ]]
	run ./bake sync_nothing; [ "$status" -eq 2 ]
	# sync through the build path, with the engine replaced by a fake that records its arguments
	mkdir "$T/fake"; printf '#!/bin/sh\necho "$@" >> %s/calls\ncat > %s/cf\nexit 0\n' "$T" "$T" > "$T/fake/podman"; chmod +x "$T/fake/podman"
	PATH=$T/fake:$PATH run ./bake build "$T/g/g.bake"; [ "$status" -eq 0 ]
	sha1=$(git -C "$R" rev-parse main)
	[[ "$output" == *": ${sha1:0:9}"* && "$output" != *"->"* ]]
	grep -q -- "--build-context src0=" "$T/calls"; grep -q "bake.src.0=\"file://$R main $sha1\"" "$T/cf"
	[ "$(cat "$T/state/bake/src/g/0/f")" = one ]; [ ! -e "$T/state/bake/src/g/0/.git" ]
	PATH=$T/fake:$PATH run ./bake build "$T/g/g.bake"; [[ "$output" == *"(unchanged)"* ]]
	bump two; sha2=$(git -C "$R" rev-parse main)
	PATH=$T/fake:$PATH run ./bake build "$T/g/g.bake"; [[ "$output" == *"${sha1:0:9} -> ${sha2:0:9}"* ]]
	[ "$(cat "$T/state/bake/src/g/0/f")" = two ]
	BAKE_OFFLINE=1 PATH=$T/fake:$PATH run ./bake build "$T/g/g.bake"; [ "$status" -eq 0 ]; [[ "$output" == *offline* ]]
}

@test "bake: BAKE_OFFLINE with a source never fetched is refused; a git line needs 2 or 3 words" {
	mkrepo; mkdir "$T/fake"; printf '#!/bin/sh\ncat > /dev/null\n' > "$T/fake/podman"; chmod +x "$T/fake/podman"
	printf 'base scratch\ngit file://%s /app\n' "$R" > "$T/o.bake"
	BAKE_OFFLINE=1 PATH=$T/fake:$PATH run ./bake build "$T/o.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"never fetched"* ]]
	printf 'base scratch\ngit onlyone\n' > "$T/w.bake"
	run ./bake show "$T/w.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"git needs URL"* ]]
}

@test "bake: outdated compares the image label with upstream (real engine)" {
	need_engine; mkrepo; mkdir "$T/g"
	printf 'base %s\ngit file://%s main /app\ncheck cat /app/f => one\n' "$BASE" "$R" > "$T/g/bake-out.bake"
	run ./bake outdated "$T/g/bake-out.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"no image built yet"* ]]
	run ./bake build "$T/g/bake-out.bake"; [ "$status" -eq 0 ]; [[ "$output" == *"check ok"* ]]
	run ./bake outdated "$T/g/bake-out.bake"; [ "$status" -eq 0 ]; [[ "$output" == *current* ]]
	bump two
	run ./bake outdated "$T/g/bake-out.bake"; [ "$status" -eq 1 ]; [[ "$output" == *upstream* ]]
	run ./bake build "$T/g/bake-out.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"check FAIL"* ]]	# the check still wants "one"
	run ./bake outdated "$T/g/bake-out.bake"; [ "$status" -eq 0 ]
	podman rmi bake-out > /dev/null 2>&1 || docker rmi bake-out > /dev/null 2>&1 || true
}

@test "bake: vm kind takes a local ISO, makes the disk once, and attaches the ISO only while the disk has no boot sector" {
	command -v qemu-img > /dev/null || skip "no qemu-img"
	mkdir "$T/fake"; printf '#!/bin/sh\necho "$@" > %s/qargs\nexit 0\n' "$T" > "$T/fake/qemu-system-$(uname -m)"; chmod +x "$T/fake/qemu-system-$(uname -m)"
	printf 'x' > "$T/a.iso"
	printf 'kind vm\niso %s\ndisk 1M\ndrive ide\nram 256M\nqemu -vga std\n' "$T/a.iso" > "$T/v.bake"
	PATH=$T/fake:$PATH run ./bake up "$T/v.bake"; [ "$status" -eq 0 ]
	grep -q -- "-cdrom $T/a.iso" "$T/qargs"; grep -q "if=ide" "$T/qargs"; grep -q -- "-vga std" "$T/qargs"; grep -q -- "-m 256M" "$T/qargs"
	d=$T/state/bake/disk/v.img; [ -f "$d" ]
	printf '\x55\xaa' | dd of="$d" bs=1 seek=510 conv=notrunc 2> /dev/null
	: > "$T/qargs"; rm -rf "$T/state/bake/vm"
	PATH=$T/fake:$PATH run ./bake up "$T/v.bake"; [ "$status" -eq 0 ]
	! grep -q -- "-cdrom" "$T/qargs"
}
