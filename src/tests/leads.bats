#!/usr/bin/env bats
# leads against a tiny local http server (no real network): parse, dedupe, scoring, --min, skips, 403/429, dry run.

setup() {
	LEADS=$(cd "$BATS_TEST_DIRNAME/.." && pwd)/leads
	T=$BATS_TEST_TMPDIR
	F=$T/fix
	mkdir -p "$F" "$T/work" "$T/home"
	unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
	export no_proxy=127.0.0.1,localhost HOME=$T/home LEADS_DELAY=0
	cat > "$T/srv.py" << 'EOF'
import http.server, os, sys, urllib.parse
FIX = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        with open(os.path.join(FIX, "requests.log"), "a") as f:
            f.write("GET %s\tUA=%s\n" % (self.path, self.headers.get("User-Agent", "")))
        name = u.path.strip("/").replace("/", "_")
        code, ra = 200, None
        st = os.path.join(FIX, name + ".status")
        if os.path.exists(st):
            p = open(st).read().split()
            code, ra = int(p[0]), (p[1] if len(p) > 1 else None)
        path = os.path.join(FIX, name)
        if code == 200 and not os.path.exists(path):
            code = 404
        body = open(path, "rb").read() if code == 200 else b""
        self.send_response(code)
        if ra:
            self.send_header("Retry-After", ra)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(FIX, "port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
EOF
	python3 "$T/srv.py" "$F" 3>&- &
	SRV=$!
	for _ in $(seq 50); do [ -s "$F/port" ] && break; sleep 0.1; done
	P=$(cat "$F/port")
	export LEADS_BASE_HN=http://127.0.0.1:$P LEADS_BASE_REDDIT=http://localhost:$P LEADS_BASE_MASTODON=http://127.0.0.1:$P
	NOW=$(date +%s)
	OLD=$((NOW - 400 * 86400))
	# hn: a good question, a plain comment, a promo story, an old question
	cat > "$F/api_v1_search_by_date" << EOF
{"hits":[
 {"objectID":"101","created_at_i":$NOW,"author":"alice","title":"Ask HN: Looking for an alternative to sqlite viewer?","story_text":"<p>Anyone know a fast sqlite viewer? I need one.</p>"},
 {"objectID":"102","created_at_i":$NOW,"author":"bob","story_title":"Databases","comment_text":"sqlite is a file format &amp; a viewer is a thing"},
 {"objectID":"103","created_at_i":$NOW,"author":"carol","title":"Show HN: my fast sqlite viewer, we built it, use code HN for 50% off","story_text":"launching today"},
 {"objectID":"104","created_at_i":$OLD,"author":"dave","title":"Looking for a fast sqlite viewer?","story_text":""}
]}
EOF
	printf '%s\n' '{"data":{"children":[{"data":{"title":"Need a fast sqlite viewer, recommend one?","selftext":"sick of slow ones","author":"erin","permalink":"/r/sqlite/comments/abc/need/","created_utc":'"$NOW"'}}]}}' > "$F/search.json"
	cat > "$F/api_v1_timelines_tag_sqlite" << EOF
[{"id":"1","created_at":"2026-01-01T00:00:00.000Z","url":"https://m.example/@f/1","account":{"acct":"f@m.example"},"content":"<p>looking for a <b>viewer</b> for sqlite files</p>"},
 {"id":"2","created_at":"2026-01-01T00:00:00.000Z","url":"https://m.example/@g/2","account":{"acct":"g"},"content":"<p>sqlite news, nothing else</p>"},
 {"id":"3","created_at":"2026-01-01T00:00:00.000Z","url":"https://m.example/@h/3","account":{"acct":"h"},"content":"<p>viewer boost</p>","reblog":{"id":"9"}}]
EOF
	cat > "$F/feed.xml" << 'EOF'
<?xml version="1.0"?>
<rss version="2.0"><channel><title>t</title>
<item><title>Anyone know a sqlite viewer?</title><link>https://blog.example/1</link><description>need one</description><pubDate>Mon, 02 Jan 2023 10:00:00 GMT</pubDate></item>
<item><title>Gardening tips</title><link>https://blog.example/2</link><description>tomatoes</description></item>
</channel></rss>
EOF
	cat > "$F/atom.xml" << 'EOF'
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title>
<entry><title>Sqlite viewer wanted</title><link rel="alternate" href="https://atom.example/1"/><summary>how do I view sqlite</summary><updated>2024-05-01T10:00:00Z</updated><author><name>zed</name></author></entry>
</feed>
EOF
	cd "$T/work" || return
}

teardown() {
	kill "$SRV" 2> /dev/null || true
	wait "$SRV" 2> /dev/null || true
}

q() { printf '%b' "$1" > leads.queries; }
reqs() { if [ -f "$F/requests.log" ]; then wc -l < "$F/requests.log"; else echo 0; fi; }
score_of() { awk -F '\t' -v u="$1" '$5 == u { print $7 }' leads.tsv; }

@test "leads: --help prints the header" {
	run "$LEADS" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"leads run [-n]"* ]]
	[[ "$output" == *"Score (0-100"* ]]
}

@test "leads: missing queries file is an error with an example" {
	run "$LEADS" run
	[ "$status" -ne 0 ]
	[[ "$output" == *"SOURCE<TAB>QUERY"* ]]
}

@test "leads: run -n prints the exact requests and makes none" {
	q 'hn\tneed a fast sqlite viewer\nreddit\talternative to sqlitebrowser\nmastodon\tsqlite viewer\n'
	run env LEADS_UA='test-ua/1' "$LEADS" run -n
	[ "$status" -eq 0 ]
	[[ "$output" == *"User-Agent: test-ua/1"* ]]
	[[ "$output" == *"GET http://127.0.0.1:$P/api/v1/search_by_date?query=need+a+fast+sqlite+viewer&tags=%28story%2Ccomment%29&hitsPerPage=30"* ]]
	[[ "$output" == *"GET http://localhost:$P/search.json?q=alternative+to+sqlitebrowser&sort=new&limit=30"* ]]
	[[ "$output" == *"GET http://127.0.0.1:$P/api/v1/timelines/tag/sqlite?limit=40"* ]]
	[ "$(reqs)" -eq 0 ]
	[ ! -e leads.tsv ]
	[ ! -e .leads-cache ]
}

@test "leads: hn parse, columns, comment url, UA header" {
	q 'hn\tneed a fast sqlite viewer\n'
	run env LEADS_UA='test-ua/2' "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"4 hits, 4 new"* ]]
	[ "$(head -1 leads.tsv)" = "$(printf 'date\tsource\tquery\tauthor\turl\ttitle\tscore')" ]
	[ "$(awk -F '\t' 'NR > 1 && NF != 7' leads.tsv | wc -l)" -eq 0 ]
	grep -q 'https://news.ycombinator.com/item?id=102' leads.tsv
	grep -q 'Re: Databases - sqlite is a file format & a viewer' leads.tsv
	grep -q 'UA=test-ua/2' "$F/requests.log"
}

@test "leads: second run dedupes by url and uses the cache (no new request)" {
	q 'hn\tneed a fast sqlite viewer\n'
	"$LEADS" run > /dev/null
	[ "$(reqs)" -eq 1 ]
	run "$LEADS" run
	[[ "$output" == *"0 new"* ]]
	[ "$(reqs)" -eq 1 ]
	[ "$(wc -l < leads.tsv)" -eq 5 ]
	# cache expired: refetch, still no duplicates
	run env LEADS_CACHE_TTL=0 "$LEADS" run
	[ "$(reqs)" -eq 2 ]
	[ "$(wc -l < leads.tsv)" -eq 5 ]
}

@test "leads: scoring order good > plain > promo, old question below the fresh one" {
	q 'hn\tfast sqlite viewer\n'
	"$LEADS" run > /dev/null
	good=$(score_of https://news.ycombinator.com/item?id=101)
	plain=$(score_of https://news.ycombinator.com/item?id=102)
	promo=$(score_of https://news.ycombinator.com/item?id=103)
	old=$(score_of https://news.ycombinator.com/item?id=104)
	[ "$good" -gt "$plain" ]
	[ "$plain" -gt "$promo" ]
	[ "$good" -gt "$old" ]
	[ "$good" -le 100 ]
	[ "$promo" -ge 0 ]
}

@test "leads: list is newest first, --min filters, open prints the url" {
	q 'hn\tfast sqlite viewer\n'
	"$LEADS" run > /dev/null
	run "$LEADS" list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == *"SCORE"* ]]
	[ "${#lines[@]}" -eq 5 ]
	# the 400-day-old row (4th in the file) is last
	[[ "${lines[4]}" == "   4 "* ]]
	good=$(score_of https://news.ycombinator.com/item?id=101)
	run "$LEADS" list --min "$good"
	[ "${#lines[@]}" -eq 2 ]
	[[ "${lines[1]}" == "   1 "* ]]
	run "$LEADS" open 1
	[ "$output" = "https://news.ycombinator.com/item?id=101" ]
	run "$LEADS" open 99
	[ "$status" -ne 0 ]
	run "$LEADS" open x
	[ "$status" -ne 0 ]
	run "$LEADS" list --min abc
	[ "$status" -ne 0 ]
}

@test "leads: reddit parse gives the permalink on reddit.com" {
	q 'reddit\tfast sqlite viewer\n'
	run "$LEADS" run
	[ "$status" -eq 0 ]
	grep -q 'https://www.reddit.com/r/sqlite/comments/abc/need/' leads.tsv
	grep -q 'sick of slow ones' leads.tsv
}

@test "leads: reddit 403 is reported, skipped, never retried, and remembered" {
	echo 403 > "$F/search.json.status"
	q 'reddit\tone sqlite\nreddit\ttwo sqlite\nhn\tfast sqlite viewer\n'
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"HTTP 403"* ]]
	[[ "$output" == *"Not retrying"* ]]
	[[ "$output" == *"4 hits, 4 new"* ]]
	[ "$(grep -c search.json "$F/requests.log")" -eq 1 ]
	run "$LEADS" run
	[[ "$output" == *"blocked until"* ]]
	[ "$(grep -c search.json "$F/requests.log")" -eq 1 ]
}

@test "leads: 429 honors Retry-After (and does not loop)" {
	printf '429 120\n' > "$F/search.json.status"
	q 'reddit\tone sqlite\nreddit\ttwo sqlite\n'
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"HTTP 429 (Retry-After 120s)"* ]]
	[[ "$output" == *"left alone for 120s"* ]]
	[ "$(reqs)" -eq 1 ]
	[ ! -e leads.tsv ]
}

@test "leads: x, linkedin and friends are named once and cause no request" {
	q 'twitter\tsqlite viewer\ntwitter\tmore\nlinkedin\tsqlite\nfacebook\tx\ninstagram\ty\nx\tz\n'
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[ "$(grep -c '^twitter: no free official access' <<< "$output")" -eq 1 ]
	[[ "$output" == *"linkedin: no free official access"* ]]
	[[ "$output" == *"facebook: no free official access"* ]]
	[ "$(reqs)" -eq 0 ]
}

@test "leads: mastodon without an instance is skipped, with one it filters words and boosts" {
	q 'mastodon\tsqlite viewer\n'
	run env -u LEADS_BASE_MASTODON "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"LEADS_MASTODON is not set"* ]]
	[ "$(reqs)" -eq 0 ]
	run "$LEADS" run
	[[ "$output" == *"1 hits, 1 new"* ]]
	grep -q 'https://m.example/@f/1' leads.tsv
	[ "$(grep -c '@g/2' leads.tsv)" -eq 0 ]
	[ "$(grep -c '@h/3' leads.tsv)" -eq 0 ]
}

@test "leads: mastodon 401 (instance wants a login) is skipped once" {
	echo 401 > "$F/api_v1_timelines_tag_sqlite.status"
	q 'mastodon\tsqlite viewer\nmastodon\tsqlite other\n'
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"HTTP 401"* ]]
	[ "$(reqs)" -eq 1 ]
}

@test "leads: rss (RSS and Atom) is filtered by query words" {
	q "rss\thttp://127.0.0.1:$P/feed.xml sqlite viewer\nrss\thttp://127.0.0.1:$P/atom.xml sqlite\n"
	run "$LEADS" run
	[ "$status" -eq 0 ]
	grep -q 'https://blog.example/1' leads.tsv
	[ "$(grep -c 'https://blog.example/2' leads.tsv)" -eq 0 ]
	grep -q 'https://atom.example/1' leads.tsv
	[ "$(awk -F '\t' '$5 == "https://atom.example/1" { print $4 }' leads.tsv)" = zed ]
}

@test "leads: rss with a DOCTYPE is refused" {
	printf '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "b">]><rss><channel><item><title>t</title><link>http://x/1</link></item></channel></rss>' > "$F/bad.xml"
	q "rss\thttp://127.0.0.1:$P/bad.xml\n"
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"refused"* ]]
	[ ! -e leads.tsv ]
}

@test "leads: comment lines, bad lines and unknown sources do not stop the run" {
	q '# comment\n\nbogus line\nfoo\tbar\nhn\tfast sqlite viewer\n'
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"need SOURCE<TAB>QUERY"* ]]
	[[ "$output" == *"unknown source"* ]]
	[[ "$output" == *"4 new leads"* ]]
}

@test "leads: LEADS_QUERIES points at another file" {
	printf 'hn\tfast sqlite viewer\n' > "$T/other.q"
	run env LEADS_QUERIES="$T/other.q" "$LEADS" run
	[[ "$output" == *"4 new leads"* ]]
}

@test "leads: shellcheck clean" {
	run shellcheck -S warning "$LEADS"
	[ "$status" -eq 0 ]
	run shellcheck -S warning -s bats "$BATS_TEST_FILENAME"
	[ "$status" -eq 0 ]
}

# rawsrv MODE: a socket server on a free port; mode bad = answers garbage, hang = accepts and says nothing
rawsrv() {
	cat > "$T/raw.py" << 'EOF'
import os, socket, sys, time
mode, portfile, logfile = sys.argv[1:4]
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(portfile, "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    open(logfile, "a").write("conn\n")
    if mode == "bad":
        c.recv(4096); c.sendall(b"this is not http\r\n\r\n"); c.close()
    else:
        time.sleep(60)
EOF
	python3 "$T/raw.py" "$1" "$T/rawport" "$T/rawlog" 3>&- &
	RAW=$!
	for _ in $(seq 50); do [ -s "$T/rawport" ] && break; sleep 0.1; done
	RP=$(cat "$T/rawport")
}

@test "leads: a server that is not speaking http skips that query and keeps the earlier leads" {
	rawsrv bad
	q 'hn\tneed a fast sqlite viewer\nreddit\talternative\n'
	run env LEADS_BASE_REDDIT=http://127.0.0.1:$RP "$LEADS" run
	kill "$RAW" 2> /dev/null || true
	[ "$status" -eq 0 ]
	[[ "$output" != *Traceback* ]]
	[[ "$output" == *"4 new"* && "$output" == *"skipped"* ]]
	[ "$(wc -l < leads.tsv)" -eq 5 ]
}

@test "leads: a json answer of the wrong shape skips that query, no traceback" {
	printf '%s\n' '{"hits":["a string","another"]}' > "$F/api_v1_search_by_date"
	q 'hn\tneed a fast sqlite viewer\nrss\thttp://127.0.0.1:'"$P"'/feed.xml sqlite viewer\n'
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" != *Traceback* ]]
	[[ "$output" == *"unexpected response"* ]]
	[[ "$output" == *"1 new"* ]]
}

@test "leads: leads found before a kill are already on disk" {
	rawsrv hang
	q 'hn\tneed a fast sqlite viewer\nreddit\talternative\n'
	env LEADS_BASE_REDDIT=http://127.0.0.1:$RP "$LEADS" run > "$T/out" 2>&1 &
	L=$!
	for _ in $(seq 100); do [ -s "$T/rawlog" ] && break; sleep 0.1; done
	[ -s "$T/rawlog" ]
	for c in $(pgrep -P "$L"); do kill -TERM "$c" 2> /dev/null || true; done
	wait "$L" 2> /dev/null || true
	kill "$RAW" 2> /dev/null || true
	[ "$(wc -l < leads.tsv)" -eq 5 ]
}

@test "leads: an unwritable leads.tsv fails before any request" {
	q 'hn\tneed a fast sqlite viewer\n'
	run env LEADS_TSV="$T/nodir/leads.tsv" "$LEADS" run
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot write"* && "$output" != *Traceback* ]]
	[ "$(reqs)" -eq 0 ]
}

@test "leads: a feed with a DOCTYPE only inside CDATA is not refused" {
	cat > "$F/cdata.xml" << 'EOF'
<?xml version="1.0"?>
<rss version="2.0"><channel><title>t</title>
<item><title>Anyone know a sqlite viewer?</title><link>https://blog.example/c1</link><description><![CDATA[<!DOCTYPE html><p>need one</p>]]></description></item>
</channel></rss>
EOF
	q 'rss\thttp://127.0.0.1:'"$P"'/cdata.xml sqlite viewer\n'
	run "$LEADS" run
	[[ "$output" == *"1 new"* ]]
}

@test "leads: a BOM and bad bytes in leads.queries or leads.tsv do not crash it" {
	printf '\xef\xbb\xbfhn\tneed a fast sqlite viewer\n# caf\xe9 \xff\n' > leads.queries
	printf 'date\tsource\tquery\tauthor\turl\ttitle\tscore\nx\thn\tq\ta\thttp://old\tcaf\xe9\t1\n' > leads.tsv
	run "$LEADS" run
	[ "$status" -eq 0 ]
	[[ "$output" != *Traceback* && "$output" != *"unknown source"* ]]
	[[ "$output" == *"4 new"* ]]
}

@test "leads: a non-numeric LEADS_DELAY is a one-line error" {
	q 'hn\tx\n'
	run env LEADS_DELAY=abc "$LEADS" run
	[ "$status" -ne 0 ]
	[[ "$output" == *"LEADS_DELAY must be a number"* && "$output" != *Traceback* ]]
}
