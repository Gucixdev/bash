#!/usr/bin/env bats
# templates/compare, setup and bench: the parts nothing else covers. Package managers are fakes, nothing is installed.

setup() {
	cd "$BATS_TEST_TMPDIR" || return
	mkdir proj sub
	for t in compare setup bench; do cp "$BATS_TEST_DIRNAME/../templates/$t" proj/$t; done
	export GIT_CONFIG_GLOBAL=/dev/null
}

@test "compare: A and B are paths from where you stand, not from the project root" {
	echo a > a.txt; echo b > b.txt; echo a > c.txt
	run ./proj/compare a.txt c.txt
	[ "$status" -eq 0 ]; [[ $output == *identical* ]]
	run ./proj/compare a.txt b.txt
	[ "$status" -eq 1 ]
	cd sub; echo z > z.txt
	run ../proj/compare z.txt ../a.txt
	[ "$status" -eq 1 ]
	mkdir d1 d2; echo x > d1/f; echo y > d2/f
	run ../proj/compare d1 d2
	[ "$status" -eq 1 ]; [[ $output == *"differ"* ]]
	run ../proj/compare d1 nope
	[ "$status" -eq 2 ]
}

fakepm() {   # a PATH with only the tools setup needs, one fake package manager that logs its arguments
	mkdir -p bin
	for t in dirname readlink env bash cat; do ln -sf "$(command -v "$t")" bin/$t; done
	printf '#!/bin/sh\nshift\necho "$@" >> %s/pm.log\n' "$BATS_TEST_TMPDIR" > bin/sudo; chmod +x bin/sudo
	for pm in "$@"; do printf '#!/bin/sh\n' > "bin/$pm"; chmod +x "bin/$pm"; done
}

@test "setup: the package column of this system's package manager is used, - and empty fall back" {
	fakepm apt-get
	sed -i "s/^DEPS=.*/DEPS='nocmd1|gcc|gcc-apt|gcc-dnf|gcc-xbps\\nnocmd2|-\\nnocmd3|pac|-|x|y\\nnocmd4|-|-'/; /^make|make$/d; /^cc|gcc$/d; /^shellcheck|shellcheck'$/d; /^git|git$/d" proj/setup
	PATH=$PWD/bin run ./proj/setup -y
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	[[ $output == *"will run: sudo apt-get install gcc-apt nocmd2 pac nocmd4"* ]] || { echo "$output"; false; }
	grep -qx 'install gcc-apt nocmd2 pac nocmd4' pm.log
}

@test "setup: an unknown argument is a usage error" {
	fakepm apt-get
	PATH=$PWD/bin run ./proj/setup --nope
	[ "$status" -eq 2 ]
}

@test "bench: a command that fails is reported instead of timed as if it worked" {
	run ./proj/bench -n 3 -- false
	[ "$status" -eq 1 ]; [[ $output == *"exited non-zero"* ]]
	run ./proj/bench -n 3 -- true
	[ "$status" -eq 0 ]; [[ $output == *runs* ]]
}
