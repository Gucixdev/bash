#!/usr/bin/env bats
# repos tests: every repo and remote is a throw-away local one, nothing touches GitHub or $HOME.

setup() {
	T=$(mktemp -d)
	export REPOS_ROOT=$T/root HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_SYSTEM=/dev/null
	mkdir -p "$REPOS_ROOT" "$HOME" "$T/remote"
	git config --global user.name tester
	git config --global user.email t@example.invalid
	git config --global init.defaultBranch main
	git config --global protocol.file.allow always
	R="$BATS_TEST_DIRNAME/../repos"
}

teardown() { rm -rf "$T"; }

# mk NAME - a repo with one commit, cloned from a bare remote, plus a second clone ("other") to play someone else
mk() {
	git init -q --bare "$T/remote/$1.git"
	git clone -q "$T/remote/$1.git" "$REPOS_ROOT/$1" 2> /dev/null
	echo one > "$REPOS_ROOT/$1/f"
	git -C "$REPOS_ROOT/$1" add f
	git -C "$REPOS_ROOT/$1" commit -qm one
	git -C "$REPOS_ROOT/$1" push -q origin main 2> /dev/null
	git clone -q "$T/remote/$1.git" "$T/other-$1"
}

# elsewhere NAME FILE TEXT - a commit made in the other clone and pushed
elsewhere() {
	echo "$3" > "$T/other-$1/$2"
	git -C "$T/other-$1" add "$2"
	git -C "$T/other-$1" commit -qm "other $2"
	git -C "$T/other-$1" push -q origin main 2> /dev/null
}

# here NAME FILE TEXT - a local commit
here() {
	echo "$3" > "$REPOS_ROOT/$1/$2"
	git -C "$REPOS_ROOT/$1" add "$2"
	git -C "$REPOS_ROOT/$1" commit -qm "here $2"
}

@test "status: clean and in sync" {
	mk a
	run "$R" status
	[ "$status" -eq 0 ]
	[[ $output == *"a "*"main"*"clean"*"in sync"* ]]
}

@test "list shows only git folders" {
	mk a
	mkdir "$REPOS_ROOT/notgit"
	run "$R" list
	[ "$output" = a ]
}

@test "unknown repo name is a usage error" {
	mk a
	run "$R" pull nope
	[ "$status" -eq 2 ]
}

@test "pull: behind only fast-forwards" {
	mk a
	elsewhere a g new
	run "$R" pull a
	[ "$status" -eq 0 ]
	[[ $output == *"fast-forwarded 1 commits"* ]]
	[ -f "$REPOS_ROOT/a/g" ]
}

@test "pull: -n changes nothing" {
	mk a
	elsewhere a g new
	run "$R" pull -n a
	[[ $output == *"would fast-forward 1 commits"* ]]
	[ ! -f "$REPOS_ROOT/a/g" ]
}

@test "pull: diverged only adds needmerge/main, HEAD and files stay" {
	mk a
	elsewhere a g theirs
	here a h mine
	head=$(git -C "$REPOS_ROOT/a" rev-parse HEAD)
	run "$R" pull a
	[ "$status" -eq 0 ]
	[[ $output == *"needmerge/main"* ]]
	[ "$(git -C "$REPOS_ROOT/a" rev-parse HEAD)" = "$head" ]
	[ ! -f "$REPOS_ROOT/a/g" ]
	[ "$(git -C "$REPOS_ROOT/a" rev-parse needmerge/main)" = "$(git -C "$T/other-a" rev-parse HEAD)" ]
}

@test "pull: changed tracked file blocks the fast-forward" {
	mk a
	elsewhere a g new
	echo edit >> "$REPOS_ROOT/a/f"
	run "$R" pull a
	[[ $output == *"commit or stash first"* ]]
	[ ! -f "$REPOS_ROOT/a/g" ]
	grep -q edit "$REPOS_ROOT/a/f"
}

@test "pull: needmerge moves forward when the remote moves again, and gets a new name if it cannot" {
	mk a
	elsewhere a g one
	here a h mine
	"$R" pull a > /dev/null
	elsewhere a g2 two
	run "$R" pull a
	[[ $output == *"moved forward"* ]]
	[ "$(git -C "$REPOS_ROOT/a" rev-parse needmerge/main)" = "$(git -C "$T/other-a" rev-parse HEAD)" ]
	# the remote's history is rewritten by someone else: the old needmerge is not an ancestor any more
	git -C "$T/other-a" reset -q --hard HEAD~2
	echo rewritten > "$T/other-a/z"
	git -C "$T/other-a" add z
	git -C "$T/other-a" commit -qm rewritten
	git -C "$T/other-a" push -q -f origin main 2> /dev/null
	run "$R" pull a
	[[ $output == *"needmerge/main-"* ]]
	[ "$(git -C "$REPOS_ROOT/a" for-each-ref refs/heads/needmerge/ | wc -l)" -eq 2 ]
}

@test "push: ahead pushes after asking (-y)" {
	mk a
	here a h mine
	run "$R" push -y a
	[ "$status" -eq 0 ]
	[[ $output == *"pushed 1 commits"* ]]
	[ "$(git -C "$T/remote/a.git" rev-parse main)" = "$(git -C "$REPOS_ROOT/a" rev-parse HEAD)" ]
}

@test "push: without a terminal and without -y nothing is sent" {
	mk a
	here a h mine
	run "$R" push a < /dev/null
	[ "$status" -eq 2 ]
	[ "$(git -C "$T/remote/a.git" rev-parse main)" != "$(git -C "$REPOS_ROOT/a" rev-parse HEAD)" ]
}

@test "push: diverged is never pushed, never forced" {
	mk a
	elsewhere a g theirs
	here a h mine
	run "$R" push -y a
	[[ $output == *"needmerge/main"* ]]
	[ "$(git -C "$T/remote/a.git" rev-parse main)" = "$(git -C "$T/other-a" rev-parse HEAD)" ]
}

@test "push: -n shows the plan and sends nothing" {
	mk a
	here a h mine
	run "$R" push -n a
	[[ $output == *"to push"* ]]
	[ "$(git -C "$T/remote/a.git" rev-parse main)" != "$(git -C "$REPOS_ROOT/a" rev-parse HEAD)" ]
}

@test "merge: needmerge without conflict" {
	mk a
	elsewhere a g theirs
	here a h mine
	"$R" pull a > /dev/null
	run "$R" needmerge a
	[[ $output == *"1 commits only on main, 1 only on the remote"* ]]
	run "$R" merge -y a
	[ "$status" -eq 0 ]
	[ -f "$REPOS_ROOT/a/g" ] && [ -f "$REPOS_ROOT/a/h" ]
	run "$R" status a
	[[ $output == *"ahead"* ]]
}

@test "merge: a conflict is aborted and leaves the tree as it was" {
	mk a
	elsewhere a f theirs
	here a f mine
	"$R" pull a > /dev/null
	head=$(git -C "$REPOS_ROOT/a" rev-parse HEAD)
	run "$R" merge -y a
	[ "$status" -eq 1 ]
	[[ $output == *"merge aborted"* ]]
	[ "$(git -C "$REPOS_ROOT/a" rev-parse HEAD)" = "$head" ]
	[ -z "$(git -C "$REPOS_ROOT/a" status --porcelain)" ]
	[ "$(cat "$REPOS_ROOT/a/f")" = mine ]
}

@test "a repo without a remote is reported, not touched" {
	git init -q "$REPOS_ROOT/solo"
	git -C "$REPOS_ROOT/solo" commit -q --allow-empty -m x
	run "$R" pull solo
	[ "$status" -eq 0 ]
	[[ $output == *"no remote branch"* ]]
	run "$R" push -y solo
	[[ $output == *"first push by hand"* ]]
}

@test "several repos in one call, only the chosen ones" {
	mk a
	mk b
	elsewhere a g new
	elsewhere b g new
	run "$R" pull a
	[ -f "$REPOS_ROOT/a/g" ]
	[ ! -f "$REPOS_ROOT/b/g" ]
	run "$R" pull
	[ -f "$REPOS_ROOT/b/g" ]
}
