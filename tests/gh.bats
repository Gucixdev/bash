#!/usr/bin/env bats
# gh and hf: their own commands, the rows and git actions behind the views, and the pass-through to the
# real tools. GitHub is a fake curl that answers from files ($FAKE/<METHOD_path>) and logs every call, the
# real gh and hf are fakes too, so nothing here touches the network or a real account.

bats_require_minimum_version 1.5.0

setup() {
	cd "$BATS_TEST_DIRNAME/.."
	REPO=$PWD
	tmp=$(mktemp -d)
	export FAKE=$tmp/fake
	mkdir -p "$FAKE" "$tmp/bin" "$tmp/real" "$tmp/work"
	cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
# fake curl: the reply is $FAKE/<key> (status in <key>.code, or <key>.authcode when a token came along)
printf '%s\n' "$*" >> "$FAKE/args"
m=GET url= data= w= cfg= fail=0
while [ $# -gt 0 ]; do
	case $1 in
		-X) m=$2; shift ;;
		--data) data=$2; shift ;;
		-w) w=$2; shift ;;
		-H | -r | -o) shift ;;
		--config) [ "$2" = - ] && cfg=$(cat); shift ;;
		--*) ;;
		-*f*) fail=1 ;;
		-*) ;;
		*) url=$1 ;;
	esac
	shift
done
printf '%s %s %s\n' "$m" "$url" "$data" | sed 's/ *$//' >> "$FAKE/log"
[ -n "$cfg" ] && printf '%s\n' "$cfg" | sed 's/.*Bearer \([^"]*\)".*/auth \1/' >> "$FAKE/log"
k=$(printf '%s %s' "$m" "$url" | sed 's#https://api.github.com/##; s#[/?&=: ]#_#g')
code=200
[ -f "$FAKE/$k.code" ] && code=$(cat "$FAKE/$k.code")
[ -n "$cfg" ] && [ -f "$FAKE/$k.authcode" ] && code=$(cat "$FAKE/$k.authcode")
case $code in
	2??) [ -f "$FAKE/$k" ] && cat "$FAKE/$k" ;;
	*) [ "$fail" = 1 ] && exit 22; [ -f "$FAKE/$k" ] && cat "$FAKE/$k" ;;
esac
[ -n "$w" ] && printf '\n%s' "$code"
exit 0
EOF
	cat > "$tmp/real/gh" <<'EOF'
#!/bin/sh
# fake real gh: prints what it got (and stdin for `read`); `auth token` answers FAKE_GH_TOKEN
case "$1 ${2:-}" in
	"auth token") [ -n "${FAKE_GH_TOKEN:-}" ] && echo "$FAKE_GH_TOKEN"; exit 0 ;;
	"config get") exit 1 ;;
esac
printf 'real:'; for a; do printf ' [%s]' "$a"; done; printf '\n'
[ "$1" = read ] && cat
exit "${FAKE_RC:-0}"
EOF
	chmod +x "$tmp/bin/curl" "$tmp/real/gh"
	ln -s "$REPO/gh" "$tmp/bin/gh"
	ln -s "$REPO/hf" "$tmp/bin/hf"
	ln -s "$REPO/trash" "$tmp/bin/trash"
	PATH="$tmp/bin:$tmp/real:$PATH"
	unset GH_TOKEN GITHUB_TOKEN GH_PROTOCOL FAKE_GH_TOKEN FAKE_RC GH_CACHE GH_ME
}

teardown() {
	cd "$BATS_TEST_DIRNAME/.."
	rm -rf "$tmp"
}

key() { printf '%s %s' "$1" "$2" | sed 's#https://api.github.com/##; s#[/?&=: ]#_#g'; }

reply() {   # METHOD URL-or-API-PATH BODY [STATUS]
	printf '%s' "$3" > "$FAKE/$(key "$1" "$2")"
	[ -z "${4:-}" ] || printf '%s' "$4" > "$FAKE/$(key "$1" "$2").code"
}

fake_git() {   # git that logs its arguments; a clone makes the folder, sparse-checkout fills the one asked for
	mkdir -p "$tmp/gitbin"
	cat > "$tmp/gitbin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE/gitlog"
printf '%s\n' "${GIT_CONFIG_VALUE_0:+header}" >> "$FAKE/gitenv"
case $1 in
	clone) for a; do d=$a; done; mkdir -p "$d" ;;
	-C) [ "$3" = sparse-checkout ] && [ -z "${FAKE_NOFOLDER:-}" ] && { mkdir -p "$2/$5"; echo hi > "$2/$5/f"; } ;;
esac
exit 0
EOF
	chmod +x "$tmp/gitbin/git"
	PATH="$tmp/gitbin:$PATH"
}

min_path() {   # a PATH with only what the scripts need to start, and the tool itself
	mkdir -p "$tmp/min"
	for t in bash sh dirname basename readlink cat; do ln -s "$(command -v "$t")" "$tmp/min/$t"; done
	ln -s "$REPO/$1" "$tmp/min/$1"
}

git_repo() {   # a repo with one commit, in $tmp/work
	cd "$tmp/work"
	git init -q -b main
	git config user.name t; git config user.email t@t; git config commit.gpgsign false
	echo a > a.txt; echo b > 'b c.txt'
	git add . && git commit -qm 'feat: first'
}

# --- pass-through ---------------------------------------------------------

@test "gh: what is not its own goes to the real gh - arguments, stdin and exit status intact" {
	run sh -c 'echo piped | FAKE_RC=3 gh read --flag "two words"'
	[ "$status" -eq 3 ]
	[ "${lines[0]}" = "real: [read] [--flag] [two words]" ]
	[ "${lines[1]}" = piped ]
	run gh --version
	[ "$output" = "real: [--version]" ]
}

@test "gh: gh search repos|code|issues|prs|commits and its flags stay the real gh's" {
	run gh search repos fzf
	[ "$output" = "real: [search] [repos] [fzf]" ]
	run gh search --help
	[ "$output" = "real: [search] [--help]" ]
}

@test "gh: without the real gh, a command of the real one is a clean error" {
	min_path gh
	PATH="$tmp/min" run -127 gh pr list
	[[ "$output" == *"not installed"* ]]
}

@test "gh --help: its own commands, then the real gh's" {
	run gh --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"gh grabdir"* ]]
	[[ "$output" == *"--- the real gh"* ]]
	[[ "$output" != *"shellcheck"* ]]
}

# --- grab, grabdir --------------------------------------------------------

@test "gh grab: usage error with no args" {
	run gh grab
	[ "$status" -eq 2 ]
}

@test "gh grab: a blob URL becomes the raw URL; the token reaches curl on stdin, never in its arguments" {
	reply GET https://raw.githubusercontent.com/o/r/main/src/x.c 'int x;'
	GH_TOKEN=sekret run gh grab https://github.com/o/r/blob/main/src/x.c -o -
	[ "$status" -eq 0 ]
	[ "$output" = 'int x;' ]
	grep -qx 'GET https://raw.githubusercontent.com/o/r/main/src/x.c' "$FAKE/log"
	grep -qx 'auth sekret' "$FAKE/log"
	! grep -q sekret "$FAKE/args"
}

@test "gh grab: without GH_TOKEN it takes the token the real gh is logged in with" {
	reply GET https://raw.githubusercontent.com/o/r/HEAD/f data
	FAKE_GH_TOKEN=fromgh run gh grab o/r f -o -
	[ "$output" = data ]
	grep -qx 'auth fromgh' "$FAKE/log"
}

@test "gh grab: OWNER/REPO PATH [REF] reads HEAD unless a ref is given" {
	reply GET https://raw.githubusercontent.com/o/r/HEAD/dir/f.txt head
	reply GET https://raw.githubusercontent.com/o/r/v2/dir/f.txt v2
	run gh grab o/r dir/f.txt -o -
	[ "$output" = head ]
	run gh grab o/r dir/f.txt v2 -o -
	[ "$output" = v2 ]
}

@test "gh grab: the file lands under its own name and is not overwritten without -f" {
	reply GET https://raw.githubusercontent.com/o/r/HEAD/f.txt new
	cd "$tmp/work"
	echo keep > f.txt
	run gh grab o/r f.txt
	[ "$status" -eq 1 ]
	[[ "$output" == *exists* ]]
	[ "$(cat f.txt)" = keep ]
	run gh grab o/r f.txt -f
	[ "$status" -eq 0 ]
	[ "$(cat f.txt)" = new ]
}

@test "gh grab: a failed fetch leaves nothing behind" {
	reply GET https://raw.githubusercontent.com/o/r/HEAD/nothing.txt '' 404
	cd "$tmp/work"
	run gh grab o/r nothing.txt
	[ "$status" -eq 1 ]
	[ -z "$(ls -A)" ]
}

@test "gh grab: a token GitHub turns down gets one more try without it" {
	reply GET https://raw.githubusercontent.com/o/r/HEAD/f public
	printf 404 > "$FAKE/$(key GET https://raw.githubusercontent.com/o/r/HEAD/f).authcode"
	GH_TOKEN=expired run gh grab o/r f -o -
	[ "$status" -eq 0 ]
	[ "$output" = public ]
}

@test "gh grab: OWNER/REPO alone is a shallow clone, the token in git's environment" {
	fake_git
	cd "$tmp/work"
	GH_TOKEN=t run gh grab o/r
	[ "$status" -eq 0 ]
	grep -qx 'clone --depth 1 https://github.com/o/r.git r' "$FAKE/gitlog"
	grep -qx header "$FAKE/gitenv"
}

@test "gh grabdir: a sparse partial clone; only the folder lands, nothing temporary stays" {
	fake_git
	cd "$tmp/work"
	run gh grabdir o/r src/lib
	[ "$status" -eq 0 ]
	[ "$output" = lib/ ]
	[ "$(cat lib/f)" = hi ]
	grep -q 'clone --quiet --depth 1 --filter=blob:none --sparse https://github.com/o/r.git' "$FAKE/gitlog"
	grep -q 'sparse-checkout set src/lib$' "$FAKE/gitlog"
	[ "$(ls -A)" = lib ]
}

@test "gh grab: a tree URL is that folder at that ref" {
	fake_git
	cd "$tmp/work"
	run gh grab https://github.com/o/r/tree/dev/docs -o d
	[ "$status" -eq 0 ]
	[ -f d/f ]
	grep -q -- '--branch dev https://github.com/o/r.git' "$FAKE/gitlog"
}

@test "gh grabdir: a folder that is not there is an error and leaves nothing" {
	fake_git
	cd "$tmp/work"
	FAKE_NOFOLDER=1 run gh grabdir o/r nope
	[ "$status" -eq 1 ]
	[[ "$output" == *"no folder nope"* ]]
	[ -z "$(ls -A)" ]
}

@test "gh grabdir: an existing folder is kept unless -f" {
	fake_git
	cd "$tmp/work"
	mkdir lib && echo mine > lib/mine
	run gh grabdir o/r lib
	[ "$status" -eq 1 ]
	[ -f lib/mine ]
	run gh grabdir o/r lib -f
	[ "$status" -eq 0 ]
	[ ! -e lib/mine ]
	[ -f lib/f ]
}

@test "gh grabdir: a commit ref comes from the tarball, no git involved" {
	mkdir -p "$tmp/t/o-r-0123abc/sub/deep"
	echo x > "$tmp/t/o-r-0123abc/sub/deep/f"
	echo top > "$tmp/t/o-r-0123abc/README"
	tar -czf "$FAKE/$(key GET repos/o/r/tarball/0123abc)" -C "$tmp/t" o-r-0123abc
	cd "$tmp/work"
	run gh grabdir o/r sub 0123abc
	[ "$status" -eq 0 ]
	[ "$(cat sub/deep/f)" = x ]
	[ "$(ls -A)" = sub ]
}

# --- create, remove, public, private --------------------------------------

@test "gh create: private unless told, the description escaped into the JSON" {
	reply POST user/repos '{"full_name":"me/proj"}' 201
	cd "$tmp/work"
	run gh create proj -d 'say "hi"'
	[ "$status" -eq 0 ]
	[[ "$output" == *"created me/proj (private)"* ]]
	grep -qxF 'POST https://api.github.com/user/repos {"name":"proj","private":true,"description":"say \"hi\""}' "$FAKE/log"
}

@test "gh create: --public, and ORG/NAME goes to the org" {
	reply POST orgs/acme/repos '{"full_name":"acme/site"}' 201
	cd "$tmp/work"
	run gh create acme/site --public
	[ "$status" -eq 0 ]
	grep -qF 'POST https://api.github.com/orgs/acme/repos {"name":"site","private":false' "$FAKE/log"
}

@test "gh create: GitHub's reason for refusing comes through (the details are in .errors)" {
	reply POST user/repos '{"message":"Repository creation failed.","errors":[{"resource":"Repository","code":"custom","field":"name","message":"name already exists on this account"}]}' 422
	cd "$tmp/work"
	run gh create taken
	[ "$status" -eq 1 ]
	[[ "$output" == *"HTTP 422 - Repository creation failed (name already exists on this account)"* ]]
}

@test "gh create: a name that is no repo name is refused before asking GitHub" {
	run gh create 'bad name'
	[ "$status" -eq 1 ]
	[ ! -e "$FAKE/log" ]
}

@test "gh create: inside a repo with no origin, the new repo becomes the origin after a yes" {
	reply POST user/repos '{"full_name":"me/work"}' 201
	git_repo
	run sh -c 'echo n | gh create --no-push'
	[ -z "$(git remote)" ]
	run sh -c 'echo y | GH_PROTOCOL=ssh gh create --no-push'
	[ "$(git config --get remote.origin.url)" = git@github.com:me/work.git ]   # as stored, before any insteadOf
	grep -qF '"name":"work"' "$FAKE/log"
}

@test "gh remove: deletes only when the name is typed back" {
	reply GET repos/me/old '{"full_name":"me/old","private":true,"html_url":"https://github.com/me/old"}'
	reply DELETE repos/me/old '' 204
	run sh -c 'echo nope | gh remove me/old'
	[[ "$output" == *"kept me/old"* ]]
	! grep -q '^DELETE' "$FAKE/log"
	run sh -c 'echo old | gh remove me/old'
	[ "$status" -eq 0 ]
	[[ "$output" == *"deleted me/old"* ]]
	grep -qx 'DELETE https://api.github.com/repos/me/old' "$FAKE/log"
}

@test "gh remove: when GitHub refuses, it says which scope the token lacks" {
	reply GET repos/me/old '{"full_name":"me/old"}'
	reply DELETE repos/me/old '{"message":"Must have admin rights to Repository."}' 403
	run sh -c 'echo old | gh remove me/old'
	[ "$status" -eq 1 ]
	[[ "$output" == *"Must have admin rights"* ]]
	[[ "$output" == *delete_repo* ]]
}

@test "gh public / private: they ask first, and a bare NAME is one of yours" {
	reply GET user '{"login":"me"}'
	reply PATCH repos/me/tool '{}'
	GH_TOKEN=t run sh -c 'echo n | gh public tool'
	! grep -q '^PATCH' "$FAKE/log"
	GH_TOKEN=t run sh -c 'echo y | gh public tool'
	[ "$status" -eq 0 ]
	grep -qxF 'PATCH https://api.github.com/repos/me/tool {"private":false}' "$FAKE/log"
	run sh -c 'echo y | gh private me/tool'
	grep -qxF 'PATCH https://api.github.com/repos/me/tool {"private":true}' "$FAKE/log"
}

# --- rows behind the GitHub views ------------------------------------------

@test "gh rows: your repos, keyed OWNER/NAME, with visibility and a one-line description" {
	reply GET 'user/repos?sort=pushed&affiliation=owner&per_page=100&page=1' \
		'[{"full_name":"me/a","private":true,"stargazers_count":3,"language":"C","pushed_at":"2026-10-01T00:00:00Z","fork":false,"archived":false,"description":"tab\there"}]'
	run gh _rows repos
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | cut -f1)" = me/a ]
	[[ "$output" == *private* ]]
	[[ "$output" == *"tab here"* ]]
}

@test "gh rows: a full page of repos means one more page is read" {
	command -v jq >/dev/null || skip "jq not installed"
	jq -n '[range(100) | {full_name: "me/r\(.)", private: false, stargazers_count: 0}]' \
		> "$FAKE/$(key GET 'user/repos?sort=pushed&affiliation=owner&per_page=100&page=1')"
	reply GET 'user/repos?sort=pushed&affiliation=owner&per_page=100&page=2' '[{"full_name":"me/last","private":false}]'
	run gh _rows repos
	[ "${#lines[@]}" -eq 101 ]
	[ "$(printf '%s\n' "$output" | tail -n 1 | cut -f1)" = me/last ]
}

@test "gh rows: the search query is encoded into the URL" {
	reply GET 'search/repositories?q=fuzzy%20finder&sort=stars&order=desc&per_page=50' \
		'{"items":[{"full_name":"x/fzf","private":false,"stargazers_count":9}]}'
	run gh _rows search 'fuzzy finder'
	[ "$(printf '%s\n' "$output" | cut -f1)" = x/fzf ]
}

@test "gh rows: lens lists folders with a slash and files with sizes; a PATH narrows it" {
	reply GET 'repos/o/r/git/trees/main?recursive=1' \
		'{"tree":[{"path":"README.md","type":"blob","size":2048},{"path":"lib","type":"tree"},{"path":"lib/a.sh","type":"blob","size":10}]}'
	run gh _rows lens o/r main
	[ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = "README.md lib/ lib/a.sh " ]
	[[ "$output" == *2.0K* ]]
	run gh _rows lens o/r main lib
	[ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = "lib/ lib/a.sh " ]
}

# --- the git views --------------------------------------------------------

@test "gh files: the branch line first, then the changes keyed by path - spaces and renames included" {
	git_repo
	echo more >> a.txt; echo new > new.txt; git mv 'b c.txt' 'b d.txt'
	run gh _rows files
	[ "$(printf '%s\n' "$output" | head -n 1 | cut -f1)" = - ]
	[ "$(printf '%s\n' "$output" | tail -n +2 | cut -f1 | sort | tr '\n' '|')" = "a.txt|b d.txt|new.txt|" ]
}

@test "gh files: stage toggles, stage-all toggles, the branch line is not a file" {
	git_repo
	echo more >> a.txt; echo new > new.txt
	gh _git stage - a.txt
	[ "$(git status --porcelain=v1 -- a.txt)" = "M  a.txt" ]
	gh _git stage a.txt
	[ "$(git status --porcelain=v1 -- a.txt)" = " M a.txt" ]
	gh _git stageall
	[ -z "$(git status --porcelain=v1 | grep -v '^[MA] ')" ]
	gh _git stageall
	[ -z "$(git status --porcelain=v1 | grep '^[MA]')" ]
}

@test "gh files: a commit wants a Conventional Commits message, or a yes for anything else" {
	git_repo
	echo more >> a.txt
	printf '%s\n' y 'did stuff' n | gh _git commit
	[ "$(git rev-list --count HEAD)" = 1 ]
	echo 'fix(a): more' | gh _git commit
	[ "$(git log -1 --format=%s)" = 'fix(a): more' ]
}

@test "gh files: discard restores tracked files and moves new ones to the trash" {
	git_repo
	echo junk >> a.txt; echo tmp > new.txt
	echo y | XDG_DATA_HOME="$tmp/xdg" gh _git discard a.txt new.txt
	[ "$(cat a.txt)" = a ]
	[ ! -e new.txt ]
	[ -f "$tmp/xdg/Trash/files/new.txt" ]
}

@test "gh log / branches: keyed by hash and branch name, origin/HEAD left out" {
	git_repo
	git branch topic
	git update-ref refs/remotes/origin/main HEAD
	git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	run gh _rows log
	[ "$(printf '%s\n' "$output" | head -n 1 | cut -f1)" = "$(git rev-parse --short HEAD)" ]
	run gh _rows branches
	[ "$(printf '%s\n' "$output" | cut -f1 | sort | tr '\n' ' ')" = "main origin/main topic " ]
}

@test "gh branches: a remote branch is checked out as a tracking branch" {
	git_repo
	git remote add origin https://example.invalid/r.git
	git update-ref refs/remotes/origin/feat HEAD
	gh _git switch origin/feat
	[ "$(git branch --show-current)" = feat ]
	[ "$(git rev-parse --abbrev-ref 'feat@{upstream}')" = origin/feat ]
}

# --- hf -------------------------------------------------------------------

@test "hf: commands of the real hf pass through, hf cache with arguments too" {
	printf '#!/bin/sh\nprintf "real hf:"; for a; do printf " [%%s]" "$a"; done; echo\n' > "$tmp/real/hf"
	chmod +x "$tmp/real/hf"
	run hf download gpt2 config.json
	[ "$output" = "real hf: [download] [gpt2] [config.json]" ]
	run hf cache ls
	[ "$output" = "real hf: [cache] [ls]" ]
}

@test "hf: without the real hf, its commands are a clean error" {
	min_path hf
	PATH="$tmp/min" run -127 hf auth login
	[[ "$output" == *"not installed"* ]]
}
