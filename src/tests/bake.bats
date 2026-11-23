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

@test "bake: up passes port, mount (with a \${VAR:-default} host path), gpu and the container name to the engine, and never replaces a foreign container" {
	mkdir "$T/fake"
	cat > "$T/fake/podman" << EOF2
#!/bin/sh
echo "\$@" >> $T/calls
case "\$1" in
  inspect) [ -f $T/foreign ] && exit 0; exit 1 ;;
  container) [ -f $T/foreign ] && exit 0; exit 1 ;;
  nvidia-ctk) ;;
esac
exit 0
EOF2
	chmod +x "$T/fake/podman"
	printf 'name u\ncontainer u-box\nbase scratch\nport 127.0.0.1:9000:80\nmount ${UHOME:-~/x}/data:/data\n' > "$T/u.bake"
	UHOME=$T/h PATH=$T/fake:$PATH run ./bake up --no-build "$T/u.bake"; [ "$status" -eq 0 ]
	grep -q -- "run -d --name u-box --label bake.managed=1 -p 127.0.0.1:9000:80 -v $T/h/data:/data u" "$T/calls"
	[ -d "$T/h/data" ]
	touch "$T/foreign"
	UHOME=$T/h PATH=$T/fake:$PATH run ./bake up --no-build "$T/u.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"not touching it"* ]]
}

# ---- audit round 2: fakes for the engine, qemu, curl and socat; nothing real is started -------------------------------

fake_engine() { # a podman that logs every call; inspect/container answer from $T/foreign and $T/label
	export XDG_DATA_HOME=$T/data
	mkdir -p "$T/fake"
	cat > "$T/fake/podman" << EOF2
#!/bin/sh
echo "\$@" >> $T/calls
case "\$1" in
  build) cat > $T/cf ;;
  inspect|container) [ -f $T/foreign ] || exit 1
     case "\$*" in *Labels*) [ -f $T/label ] && echo 1; exit 0 ;; esac; exit 0 ;;
  export) [ -f $T/exportfail ] && { echo half > "\$3"; exit 1; }; echo tar > "\$3" ;;
  create) echo cid ;;
esac
exit 0
EOF2
	chmod +x "$T/fake/podman"
}

@test "bake: BAKE_OFFLINE=0 or empty is not offline, only a set non-zero value is" {
	fake_engine; mkrepo
	printf 'base scratch\ngit file://%s main /app\n' "$R" > "$T/o.bake"
	BAKE_OFFLINE=0 PATH=$T/fake:$PATH run ./bake build "$T/o.bake"
	[ "$status" -eq 0 ]; [[ "$output" != *offline* ]]
	rm -rf "$T/state"
	BAKE_OFFLINE= PATH=$T/fake:$PATH run ./bake build "$T/o.bake"; [ "$status" -eq 0 ]
	rm -rf "$T/state"
	BAKE_OFFLINE=1 PATH=$T/fake:$PATH run ./bake build "$T/o.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"never fetched"* ]]
}

@test "bake: a name that is a path is refused, nothing is written outside the state dir" {
	fake_engine
	printf 'name ../../esc\nbase scratch\n' > "$T/n.bake"
	PATH=$T/fake:$PATH run ./bake build "$T/n.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"usable name"* ]]
	[ ! -e "$T/esc.log" ] && [ ! -e "$T/state/esc" ] && [ ! -s "$T/calls" ]
	cd "$T"; B="$BATS_TEST_DIRNAME/../bake"
	run "$B" new ../escaped; [ "$status" -eq 2 ]; [ ! -e "$T/../escaped.bake" ]
	run "$B" new -x; [ "$status" -eq 2 ]
	run "$B" new "a b"; [ "$status" -eq 2 ]
	PATH=$T/fake:$PATH run "$B" vm start ../../x --kernel k; [ "$status" -eq 1 ]
	PATH=$T/fake:$PATH run "$B" vm stop ../x; [ "$status" -eq 1 ]; [[ "$output" == *"usable VM name"* ]]
}

@test "bake: build and up read their options after FILE too" {
	fake_engine; mkdir -p "$T/w"
	printf 'name u\nbase scratch\nport 9000:80\n' > "$T/u.bake"
	PATH=$T/fake:$PATH run ./bake build "$T/u.bake" --pull; [ "$status" -eq 0 ]
	grep -q -- '--pull=newer' "$T/calls"
	: > "$T/calls"
	PATH=$T/fake:$PATH run ./bake up "$T/u.bake" --no-build; [ "$status" -eq 0 ]
	! grep -q '^build' "$T/calls"
	grep -q '^run -d --name u ' "$T/calls"
	PATH=$T/fake:$PATH run ./bake up "$T/u.bake" --bogus; [ "$status" -eq 2 ]
	PATH=$T/fake:$PATH run ./bake build "$T/u.bake" "$T/u.bake"; [ "$status" -eq 2 ]
}

@test "bake: a mount with :ro keeps the options and does not make a directory named after them" {
	fake_engine
	printf 'name u\nbase scratch\nmount ${UHOME:-~/x}/data:/data:ro\nmount %s/plain:/p\n' "$T" > "$T/u.bake"
	UHOME=$T/h PATH=$T/fake:$PATH run ./bake up --no-build "$T/u.bake"; [ "$status" -eq 0 ]
	grep -q -- "-v $T/h/data:/data:ro -v $T/plain:/p u" "$T/calls"
	[ -d "$T/h/data" ] && [ -d "$T/plain" ]
	[ ! -e "$T/h/data:" ] && [ ! -e "$T/h/data:/data" ]
	printf 'name u\nbase scratch\nmount /nocolon\n' > "$T/v.bake"
	PATH=$T/fake:$PATH run ./bake up --no-build "$T/v.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"HOST:CONTAINER"* ]]
}

@test "bake: down does not stop a container that bake did not make" {
	fake_engine
	printf 'name u\nbase scratch\n' > "$T/u.bake"
	touch "$T/foreign"
	PATH=$T/fake:$PATH run ./bake down "$T/u.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"not touching it"* ]]
	! grep -q '^stop' "$T/calls"
	touch "$T/label"
	PATH=$T/fake:$PATH run ./bake down "$T/u.bake"; [ "$status" -eq 0 ]
	grep -q '^stop u' "$T/calls"
}

@test "bake: rootfs refuses an existing tarball and a failed export leaves no tarball" {
	fake_engine
	printf 'name r\nbase scratch\n' > "$T/r.bake"
	echo precious > "$T/out.tar"
	PATH=$T/fake:$PATH run ./bake rootfs "$T/r.bake" "$T/out.tar"; [ "$status" -eq 1 ]; [[ "$output" == *"exists"* ]]
	[ "$(cat "$T/out.tar")" = precious ]
	touch "$T/exportfail"
	PATH=$T/fake:$PATH run ./bake rootfs "$T/r.bake" "$T/new.tar"; [ "$status" -eq 1 ]
	[ ! -e "$T/new.tar" ] && [ ! -e "$T/new.tar.part" ]
}

@test "bake: a git URL or ref that starts with - is refused (git would take it as an option)" {
	printf 'base scratch\ngit --upload-pack=touch main /app\n' > "$T/d.bake"
	run ./bake show "$T/d.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"starts with -"* ]]
	printf 'base scratch\ngit https://x/y --output=z /app\n' > "$T/e.bake"
	run ./bake show "$T/e.bake"; [ "$status" -eq 1 ]; [[ "$output" == *"starts with -"* ]]
}

@test "bake: vm ls with an empty vm folder lists nothing, not a '*' row" {
	mkdir -p "$T/state/bake/vm"
	run ./bake vm ls; [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "bake: CRLF line ends in a .bake file are ignored" {
	printf 'base alpine:3.20\r\npkg git\r\nenv A=1\r\n' > "$T/c.bake"
	run ./bake show "$T/c.bake"; [ "$status" -eq 0 ]
	[[ "$output" != *$'\r'* ]]
}

@test "bake: vm shot refuses a stale screenshot, and quotes the path it hands to the monitor" {
	command -v qemu-img > /dev/null || skip "no qemu-img"
	mkdir -p "$T/fake" "$T/state/bake/vm/g"
	cp "$(command -v sleep)" "$T/fake/qemu-fake"; "$T/fake/qemu-fake" 30 & echo $! > "$T/state/bake/vm/g/pid"
	printf '#!/bin/sh\ncat > %s/mon\n' "$T" > "$T/fake/socat"; chmod +x "$T/fake/socat"
	export XDG_RUNTIME_DIR=$T/run; mkdir -p "$XDG_RUNTIME_DIR"
	echo old > "$T/my shot.ppm"
	PATH=$T/fake:$PATH run ./bake vm shot g "$T/my shot.ppm"
	kill "$(cat "$T/state/bake/vm/g/pid")" 2> /dev/null
	[ "$status" -eq 1 ]; [[ "$output" == *"no screenshot came back"* ]]
	[ "$(cat "$T/my shot.ppm")" = old ]
	grep -q '^screendump "' "$T/mon"
}

@test "bake: an upper-case sha256 on an iso line is accepted" {
	command -v qemu-img > /dev/null || skip "no qemu-img"
	fake_engine
	printf '#!/bin/sh\nout=\nwhile [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; -fsSIL) printf "ETag: \\"1\\"\\r\\n"; exit 0 ;; esac; shift; done\n[ -z "$out" ] || printf "isobytes" > "$out"\n' > "$T/fake/curl"; chmod +x "$T/fake/curl"
	sum=$(printf 'isobytes' | sha256sum | cut -d' ' -f1)
	printf 'kind vm\niso http://example.invalid/a.iso %s\ndisk 1M\n' "${sum^^}" > "$T/v.bake"
	PATH=$T/fake:$PATH run ./bake build "$T/v.bake"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "bake: a comma in a vm disk path is doubled so qemu does not split the -drive option" {
	mkdir -p "$T/fake"; q=qemu-system-$(uname -m)
	printf '#!/bin/sh\necho "$@" > %s/qargs\nexit 0\n' "$T" > "$T/fake/$q"; chmod +x "$T/fake/$q"
	PATH=$T/fake:$PATH run ./bake vm start c --disk "$T/a,b.img"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	grep -q -- "file=$T/a,,b.img,if=virtio" "$T/qargs"
}
