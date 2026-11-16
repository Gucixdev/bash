#!/usr/bin/env bats
# launchers/templeos/templeos: no network, no QEMU. Fake curl, qemu-img and qemu-system-x86_64 on PATH record their argv.
# TOS_HOME points into the test tmp dir so the script never touches the real .tos folder next to it.

setup() {
	TOS=$(cd "$BATS_TEST_DIRNAME/.." && pwd)/launchers/templeos/templeos
	T=$BATS_TEST_TMPDIR
	mkdir -p "$T/fake" "$T/home" "$T/data"
	export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_DATA_HOME=$T/home/.local/share
	export TOS_HOME=$T/data
	unset TOS_ISO TOS_DISK TOS_ISO_URL TOS_DISK_SIZE TOS_RAM
	# curl: records argv, writes the file named by -o
	cat > "$T/fake/curl" << 'EOF2'
#!/bin/sh
echo "$@" >> "$FAKE_LOG/curl.argv"
[ -n "$CURL_RC" ] && exit "$CURL_RC"
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
printf FAKEISO > "$out"
EOF2
	# qemu-img create -f raw FILE SIZE: records argv, makes a blank file
	cat > "$T/fake/qemu-img" << 'EOF2'
#!/bin/sh
echo "$@" >> "$FAKE_LOG/qemu-img.argv"
printf '' > "$4"
EOF2
	cat > "$T/fake/qemu-system-x86_64" << 'EOF2'
#!/bin/sh
echo "$@" >> "$FAKE_LOG/qemu.argv"
EOF2
	chmod +x "$T/fake/"*
	export FAKE_LOG=$T
	export PATH=$T/fake:$PATH
}

# bare: PATH with only the basics, so curl/qemu-* are surely absent
bare() {
	mkdir -p "$T/bare"
	local c p
	for c in bash env dirname dd od tr du cut mv rm mkdir cat; do
		p=$(command -v "$c") && ln -sf "$p" "$T/bare/$c"
	done
	export PATH=$T/bare
}

# installed: a disk image carrying the MBR signature 55 AA at offset 510
installed() {
	dd if=/dev/zero of="$T/data/disk.img" bs=512 count=4 2> /dev/null
	printf '\125\252' | dd of="$T/data/disk.img" bs=1 seek=510 conv=notrunc 2> /dev/null
}

@test "templeos: unknown argument prints usage and exits 2" {
	run "$TOS" frobnicate
	[ "$status" -eq 2 ]
	[[ $output == *"usage: tos [run | info | clean]"* ]]
	[ ! -e "$T/curl.argv" ]
}

@test "templeos: no argument downloads ISO, creates disk, boots with the ISO attached" {
	run "$TOS"
	[ "$status" -eq 0 ]
	[ "$(cat "$T/data/TempleOS.ISO")" = FAKEISO ]
	[ ! -e "$T/data/TempleOS.ISO.part" ]
	[ -f "$T/data/disk.img" ]
	grep -q 'templeos.org/Downloads/TempleOS.ISO' "$T/curl.argv"
	grep -q -- "-f raw $T/data/disk.img 64M" "$T/qemu-img.argv"
	grep -q -- "-m 256" "$T/qemu.argv"
	grep -q -- "-hda $T/data/disk.img" "$T/qemu.argv"
	grep -q -- "-cdrom $T/data/TempleOS.ISO -boot d" "$T/qemu.argv"
}

@test "templeos: env overrides for URL, size, RAM and paths are honoured" {
	TOS_ISO_URL=http://127.0.0.1:9/x.iso TOS_DISK_SIZE=8M TOS_RAM=128 \
		TOS_ISO=$T/data/my.iso TOS_DISK=$T/data/my.img run "$TOS"
	[ "$status" -eq 0 ]
	[ -f "$T/data/my.iso" ] && [ -f "$T/data/my.img" ]
	grep -q 'http://127.0.0.1:9/x.iso' "$T/curl.argv"
	grep -q -- "-f raw $T/data/my.img 8M" "$T/qemu-img.argv"
	grep -q -- "-m 128 -hda $T/data/my.img" "$T/qemu.argv"
}

@test "templeos: idempotent, an existing ISO and disk are neither fetched nor recreated" {
	printf KEEPISO > "$T/data/TempleOS.ISO"
	printf KEEPDISK > "$T/data/disk.img"
	run "$TOS"
	[ "$status" -eq 0 ]
	[[ $output == *"ISO already at"* ]]
	[[ $output == *"disk already at"* ]]
	[ ! -e "$T/curl.argv" ]
	[ ! -e "$T/qemu-img.argv" ]
	[ "$(cat "$T/data/TempleOS.ISO")" = KEEPISO ]
	[ "$(cat "$T/data/disk.img")" = KEEPDISK ]
}

@test "templeos: a failed download leaves no ISO behind and does not boot" {
	CURL_RC=22 run "$TOS"
	[ "$status" -ne 0 ]
	[ ! -e "$T/data/TempleOS.ISO" ]
	[ ! -e "$T/qemu.argv" ]
}

@test "templeos: installed disk (MBR signature 55 AA) boots without the ISO" {
	printf KEEPISO > "$T/data/TempleOS.ISO"
	installed
	run "$TOS" run
	[ "$status" -eq 0 ]
	grep -q -- "-hda $T/data/disk.img" "$T/qemu.argv"
	run grep -q -- "-cdrom" "$T/qemu.argv"
	[ "$status" -eq 1 ]
}

@test "templeos: blank disk (no signature) boots from the ISO" {
	printf KEEPISO > "$T/data/TempleOS.ISO"
	dd if=/dev/zero of="$T/data/disk.img" bs=512 count=4 2> /dev/null
	run "$TOS" run
	[ "$status" -eq 0 ]
	grep -q -- "-cdrom $T/data/TempleOS.ISO -boot d" "$T/qemu.argv"
}

@test "templeos: run refuses when the ISO or the disk is missing" {
	run "$TOS" run
	[ "$status" -eq 1 ]
	[[ $output == *"no ISO at"* ]]
	printf ISO > "$T/data/TempleOS.ISO"
	run "$TOS" run
	[ "$status" -eq 1 ]
	[[ $output == *"no disk at"* ]]
	[ ! -e "$T/qemu.argv" ]
	[ ! -e "$T/curl.argv" ]
}

@test "templeos: missing tools are named and exit 1" {
	bare
	run "$TOS"
	[ "$status" -eq 1 ]
	[[ $output == *"need 'curl'"* ]]
	printf ISO > "$T/data/TempleOS.ISO"
	run "$TOS"
	[ "$status" -eq 1 ]
	[[ $output == *"need 'qemu-img'"* ]]
	printf D > "$T/data/disk.img"
	run "$TOS"
	[ "$status" -eq 1 ]
	[[ $output == *"need 'qemu-system-x86_64'"* ]]
}

@test "templeos info: reports paths, sizes and RAM, changes nothing" {
	run "$TOS" info
	[ "$status" -eq 0 ]
	[[ $output == *"ISO:  $T/data/TempleOS.ISO (missing)"* ]]
	[[ $output == *"disk: $T/data/disk.img (missing)"* ]]
	[[ $output == *"RAM:  256MiB"* ]]
	printf ISO > "$T/data/TempleOS.ISO"
	printf D > "$T/data/disk.img"
	TOS_RAM=64 run "$TOS" info
	[ "$status" -eq 0 ]
	[[ $output != *"(missing)"* ]]
	[[ $output == *"RAM:  64MiB"* ]]
	[ ! -e "$T/curl.argv" ] && [ ! -e "$T/qemu.argv" ]
}

@test "templeos clean: removes the disk image, keeps the ISO" {
	printf ISO > "$T/data/TempleOS.ISO"
	printf D > "$T/data/disk.img"
	run "$TOS" clean
	[ "$status" -eq 0 ]
	[ ! -e "$T/data/disk.img" ]
	[ "$(cat "$T/data/TempleOS.ISO")" = ISO ]
	# nothing to clean is not an error
	run "$TOS" clean
	[ "$status" -eq 0 ]
}

@test "templeos: with TOS_HOME set the folder next to the script is left alone" {
	before=$(ls -A "$(dirname "$TOS")" | sort | tr '\n' ' ')
	run "$TOS"
	[ "$status" -eq 0 ]
	[ "$(ls -A "$(dirname "$TOS")" | sort | tr '\n' ' ')" = "$before" ]
}
