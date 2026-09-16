#!/usr/bin/env bash
#
# Mura CMS container smoke test.
#
# Exercises the paths that actually break when the container, the nginx front
# controller or the Lucee/Mura configuration is wrong:
#
#   1. front end        - home page, front-controller rewrite, static assets,
#                         JSON API, and that Lucee internals stay blocked
#   2. admin login      - CSRF-token login round trip against a cookie jar,
#                         plus a report of the Set-Cookie flags
#   3. content lifecycle- create a page, render it on the front end, delete it
#
# Every check prints PASS or FAIL; the script exits non-zero if any failed.
#
# Usage:
#   BASE_URL=http://localhost ADMIN_USER=admin ADMIN_PASS=secret ./smoke.sh
#   ./smoke.sh http://localhost admin secret
#
# See docker/tests/README.md for how to point it at the compose stack.

set -uo pipefail

BASE_URL="${1:-${BASE_URL:-http://localhost}}"
ADMIN_USER="${2:-${ADMIN_USER:-admin}}"
ADMIN_PASS="${3:-${ADMIN_PASS:-}}"

# Mura's stock home node. Override if the site's root content id differs.
HOME_ID="${MURA_HOME_ID:-00000000000000000000000000000000001}"
SITE_ID="${MURA_SITE_ID:-default}"
CURL_TIMEOUT="${CURL_TIMEOUT:-120}"

BASE_URL="${BASE_URL%/}"

if [ -z "$ADMIN_PASS" ]; then
  echo "ERROR: ADMIN_PASS is required (env var or third argument)." >&2
  echo "Usage: BASE_URL=http://localhost ADMIN_USER=admin ADMIN_PASS=... $0" >&2
  exit 2
fi

WORK="$(mktemp -d)"
JAR="$WORK/cookies"
PASSED=0
FAILED=0
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- helpers ---

c_red=''; c_grn=''; c_yel=''; c_off=''
if [ -t 1 ]; then
  c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
fi

pass() { PASSED=$((PASSED + 1)); printf '%sPASS%s %s\n' "$c_grn" "$c_off" "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '%sFAIL%s %s\n' "$c_red" "$c_off" "$1"; }
info() { printf '     %s\n' "$1"; }
note() { printf '%sNOTE%s %s\n' "$c_yel" "$c_off" "$1"; }
head1() { printf '\n== %s\n' "$1"; }

# check <description> <condition-result:0|1> <evidence>
check() {
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
  [ -n "${3:-}" ] && info "$3"
  return 0
}

# get <outfile> <url> [curl args...] -> echoes HTTP status
get() {
  local out="$1" url="$2"; shift 2
  curl -sS -o "$out" -w '%{http_code}' --max-time "$CURL_TIMEOUT" "$@" "$url" 2>/dev/null || echo 000
}

# title_of <file> -> contents of the first <title> tag
title_of() {
  tr -d '\r\n' < "$1" | grep -o '<title>[^<]*</title>' | head -1 |
    sed 's/<title>//; s|</title>||'
}

# field_of <file> <name> -> value="..." of the named input, either attribute order
field_of() {
  local v
  v=$(grep -o "name=\"$2\"[^>]*value=\"[^\"]*\"" "$1" | head -1 | sed 's/.*value="//; s/"$//')
  [ -z "$v" ] && v=$(grep -o "value=\"[^\"]*\"[^>]*name=\"$2\"" "$1" | head -1 | sed 's/^value="//; s/".*//')
  printf '%s' "$v"
}

# form_block <file> <formname> -> the markup of that form only
form_block() {
  awk -v want="name=\"$2\"" '
    /<form/ && index($0, want) { inform = 1 }
    inform { print }
    inform && /<\/form>/ { exit }
  ' "$1"
}

# unescape_json_html <file> -> the markup carried inside Mura's {"html":"..."}
# AJAX responses, turned back into real HTML so it can be grepped line by line
unescape_json_html() {
  sed -e 's/\\"/"/g' -e 's/\\\//\//g' -e 's/\\n/\n/g' -e 's/\\t/\t/g' "$1"
}

# ------------------------------------------------------------------ banner ---

echo "Mura CMS smoke test"
echo "  BASE_URL   : $BASE_URL"
echo "  ADMIN_USER : $ADMIN_USER"
echo "  site / home: $SITE_ID / $HOME_ID"

# =================================================== 1. front end / routing ===

head1 "Front end and routing"

code=$(get "$WORK/home" "$BASE_URL/" -L)
t=$(title_of "$WORK/home")
[ "$code" = "200" ] && [ -n "$t" ]; check "GET / returns 200 with a title" $? "http=$code title=\"$t\""

# A path that does not exist must still reach Mura (proving the nginx
# try_files front-controller rewrite), and Mura must answer with its own 404
# page rather than nginx's built-in one.
code=$(get "$WORK/nf" "$BASE_URL/this-does-not-exist/" -L -D "$WORK/nfh")
t=$(title_of "$WORK/nf")
gen=$(grep -ci '^generator:.*mura' "$WORK/nfh" 2>/dev/null)
[ "$code" = "404" ] && [ "$gen" -ge 1 ]; check "unknown path reaches Mura's 404 (front-controller rewrite)" $? "http=$code title=\"$t\" MuraGeneratorHeader=$gen"

# A content-shaped URL beginning with "lucee" must NOT be swallowed by the
# nginx rule that blocks the Lucee admin (regression guard: that rule has to be
# anchored to a whole path segment, not a bare prefix match).
code=$(get "$WORK/lu" "$BASE_URL/lucee-not-a-real-page/" -L -D "$WORK/luh")
gen=$(grep -ci '^generator:.*mura' "$WORK/luh" 2>/dev/null)
[ "$gen" -ge 1 ]; check "content URL starting with 'lucee' reaches Mura, not blocked at the edge" $? "http=$code MuraGeneratorHeader=$gen"

# ...while the Lucee admin itself stays blocked.
code=$(get "$WORK/la" "$BASE_URL/lucee/admin.cfm")
[ "$code" = "404" ] || [ "$code" = "403" ]; check "Lucee admin is blocked at the edge" $? "http=$code"

code=$(get "$WORK/st" "$BASE_URL/admin/assets/js/mura.js" -D "$WORK/sth")
ctype=$(grep -i '^content-type:' "$WORK/sth" | tr -d '\r' | head -1 | sed 's/.*: *//')
size=$(wc -c < "$WORK/st" | tr -d ' ')
[ "$code" = "200" ] && [ "$size" -gt 1000 ]; check "static asset served (nginx)" $? "http=$code type=$ctype bytes=$size"

code=$(get "$WORK/api" "$BASE_URL/index.cfm/_api/json/v1/$SITE_ID/content/" -D "$WORK/apih")
ctype=$(grep -i '^content-type:' "$WORK/apih" | tr -d '\r' | head -1 | sed 's/.*: *//')
isjson=1; head -c 1 "$WORK/api" | grep -q '{' && isjson=0
[ "$code" = "200" ] && [ "$isjson" -eq 0 ]; check "JSON API responds with JSON" $? "http=$code type=$ctype"

# ====================================================== 2. admin login flow ===

head1 "Admin login"

rm -f "$JAR"
code=$(get "$WORK/login" "$BASE_URL/admin/index.cfm?muraAction=cLogin.main" -c "$JAR" -b "$JAR" -D "$WORK/loginh")
t=$(title_of "$WORK/login")
[ "$code" = "200" ] && echo "$t" | grep -qi 'login'; check "login form loads" $? "http=$code title=\"$t\""

# Report the cookie flags. Over plain HTTP, Secure cookies are dropped by real
# browsers on any origin that is not localhost, so this is worth seeing.
sec=$(grep -ic 'set-cookie:.*secure' "$WORK/loginh" 2>/dev/null)
ssite=$(grep -io 'samesite=[a-z]*' "$WORK/loginh" 2>/dev/null | sort -u | tr '\n' ' ')
note "Set-Cookie: $sec of $(grep -ic 'set-cookie:' "$WORK/loginh" 2>/dev/null) cookies carry Secure; SameSite values: ${ssite:-none seen}"
case "$BASE_URL" in
  https://*) : ;;
  *) [ "$sec" -gt 0 ] && note "BASE_URL is plain HTTP but Secure cookies are being set - browsers will drop these on any non-localhost origin." ;;
esac

CSRF=$(field_of "$WORK/login" csrf_token)
CSRFX=$(field_of "$WORK/login" csrf_token_expires)
RB=$(field_of "$WORK/login" rb)
CD=$(field_of "$WORK/login" compactDisplay)
[ -n "$CSRF" ] && [ -n "$CSRFX" ]; check "login CSRF tokens scraped" $? "csrf_token=${CSRF:0:8}... expires=$CSRFX"

code=$(curl -sS -o "$WORK/lpost" -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
  -c "$JAR" -b "$JAR" -X POST "$BASE_URL/admin/index.cfm" \
  --data-urlencode "muraAction=cLogin.login" \
  --data-urlencode "isAdminLogin=true" \
  --data-urlencode "username=$ADMIN_USER" \
  --data-urlencode "password=$ADMIN_PASS" \
  --data-urlencode "csrf_token=$CSRF" \
  --data-urlencode "csrf_token_expires=$CSRFX" \
  --data-urlencode "rb=$RB" \
  --data-urlencode "compactDisplay=$CD" 2>/dev/null || echo 000)
info "login POST http=$code"

code=$(get "$WORK/arch" "$BASE_URL/admin/index.cfm?muraAction=cArch.list&siteid=$SITE_ID" -b "$JAR" -c "$JAR" -L)
t=$(title_of "$WORK/arch")
logout=$(grep -ci 'logout' "$WORK/arch" 2>/dev/null)
[ "$code" = "200" ] && echo "$t" | grep -qi 'site content' && [ "$logout" -ge 1 ]
check "authenticated admin reaches Site Content" $? "http=$code title=\"$t\" logoutLinks=$logout"

# Control: the same URL with no cookies must NOT come back as Site Content.
code=$(get "$WORK/anon" "$BASE_URL/admin/index.cfm?muraAction=cArch.list&siteid=$SITE_ID")
[ "$code" != "200" ] || ! title_of "$WORK/anon" | grep -qi 'site content'
check "unauthenticated request is refused (control)" $? "http=$code title=\"$(title_of "$WORK/anon")\""

if [ "$FAILED" -gt 0 ]; then
  head1 "Summary"
  echo "Login did not complete; skipping the content lifecycle checks."
  printf 'passed=%d failed=%d\n' "$PASSED" "$FAILED"
  exit 1
fi

# =================================================== 3. content lifecycle ====

head1 "Content lifecycle (create / render / delete)"

STAMP="$(date +%s)"
TITLE="Smoke Test Page $STAMP"
# Mura derives the filename by lower-casing the title and hyphenating spaces.
SLUG="smoke-test-page-$STAMP"
MARKER="smoke-marker-$STAMP"

code=$(get "$WORK/newform" \
  "$BASE_URL/admin/index.cfm?muraAction=cArch.edit&type=Page&parentid=$HOME_ID&siteid=$SITE_ID" \
  -b "$JAR" -c "$JAR" -L)
form_block "$WORK/newform" contentForm > "$WORK/cform"
nfields=$(grep -c '<input' "$WORK/cform" 2>/dev/null)
[ "$code" = "200" ] && [ "$nfields" -gt 10 ]
check "new-page form loads" $? "http=$code inputs=$nfields"

# Re-post the field set a browser would send: every submittable input, plus the
# selected option of each <select>. Fields we set ourselves below are skipped
# here so they cannot be posted twice.
#
# isLocked is deliberately excluded: it is rendered as an unchecked checkbox,
# so a browser never sends it, but echoing it back checks the node out and Mura
# then hides the delete control - which would strand the test page.
awk '
  function attr(s, name,   m) {
    m = s
    if (match(m, name "=\"[^\"]*\"") == 0) return ""
    m = substr(m, RSTART, RLENGTH)
    sub(name "=\"", "", m); sub(/"$/, "", m)
    return m
  }
  function skip(n) {
    return (n == "" || n == "title" || n == "menuTitle" || n == "htmlTitle" ||
            n == "body" || n == "summary" || n == "approved" || n == "action" ||
            n == "isLocked" || n == "unlockfilewithnew" || n == "unlocknodewithpublish")
  }
  {
    line = $0

    # --- inputs (one or more per line) ---
    rest = line
    while (match(rest, /<input[^>]*>/)) {
      tag = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      type = tolower(attr(tag, "type"))
      if (type == "file" || type == "submit" || type == "button" || type == "image" || type == "reset") continue
      n = attr(tag, "name")
      if (skip(n)) continue
      if ((type == "checkbox" || type == "radio") && tag !~ /[[:space:]]checked/) continue
      print n "\t" attr(tag, "value")
    }

    # --- selects: remember the open tag, resolve on </select> ---
    if (match(line, /<select[^>]*>/)) {
      tag = substr(line, RSTART, RLENGTH)
      selname = attr(tag, "name")
      insel = 1; chosen = ""; firstopt = ""; havefirst = 0
    }
    if (insel && match(line, /<option[^>]*>/)) {
      otag = substr(line, RSTART, RLENGTH)
      oval = attr(otag, "value")
      if (!havefirst) { firstopt = oval; havefirst = 1 }
      if (otag ~ /selected/) chosen = oval
    }
    if (insel && line ~ /<\/select>/) {
      if (!skip(selname) && selname != "")
        print selname "\t" (chosen != "" ? chosen : firstopt)
      insel = 0
    }
  }
' "$WORK/cform" > "$WORK/args"

CURLARGS=()
while IFS=$'\t' read -r n v; do
  [ -z "$n" ] && continue
  CURLARGS+=(--data-urlencode "$n=$v")
done < "$WORK/args"
CURLARGS+=(--data-urlencode "title=$TITLE")
CURLARGS+=(--data-urlencode "menuTitle=$TITLE")
CURLARGS+=(--data-urlencode "htmlTitle=$TITLE")
CURLARGS+=(--data-urlencode "summary=created by docker/tests/smoke.sh")
CURLARGS+=(--data-urlencode "body=<p>$MARKER</p>")
CURLARGS+=(--data-urlencode "approved=1")
CURLARGS+=(--data-urlencode "action=add")
# The form's own defaults leave a freshly created node checked out (isLocked=1),
# and Mura hides the delete control for a locked node - which would strand the
# test page. Ask for it to be released as part of the save.
CURLARGS+=(--data-urlencode "unlockfilewithnew=true")
CURLARGS+=(--data-urlencode "unlocknodewithpublish=true")

code=$(curl -sS -o "$WORK/created" -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
  -b "$JAR" -c "$JAR" -X POST "$BASE_URL/admin/index.cfm" "${CURLARGS[@]}" 2>/dev/null || echo 000)
[ "$code" = "302" ] || [ "$code" = "200" ]
check "create page POST accepted" $? "http=$code title=\"$TITLE\""

# The page must now render on the front end, with its body content.
code=$(get "$WORK/fe" "$BASE_URL/$SLUG/" -L)
t=$(title_of "$WORK/fe")
hasmarker=$(grep -c "$MARKER" "$WORK/fe" 2>/dev/null)
[ "$code" = "200" ] && [ "$hasmarker" -ge 1 ]
check "page renders on the front end at /$SLUG/" $? "http=$code title=\"$t\" bodyMarker=$hasmarker"

# Find the node in the site-manager tree and follow its delete link (which
# carries the per-node CSRF tokens Mura requires).
code=$(get "$WORK/tree" \
  "$BASE_URL/admin/index.cfm?muraAction=cArch.loadsitemanager&siteid=$SITE_ID&parentid=$HOME_ID" \
  -b "$JAR" -c "$JAR" -L)

# The site manager answers with {"html":"...escaped markup..."}, so unescape it
# first, then pick out the delete link belonging to *our* node: take the window
# of markup that follows the node's own filename and use the first deleteall
# URL inside it. Doing it positionally avoids deleting somebody else's page
# when the tree already has other children.
unescape_json_html "$WORK/tree" | tr '\n' ' ' > "$WORK/tree.html"
DEL=$(awk -v slug="/$SLUG/" '
  {
    p = index($0, slug)
    if (p == 0) exit
    rest = substr($0, p)
    q = index(rest, "action=deleteall")
    if (q == 0) exit
    # Walk back from the deleteall marker to the start of its query string.
    head = substr(rest, 1, q - 1)
    s = 0
    while (1) {
      n = index(substr(head, s + 1), "?muraAction=cArch.update")
      if (n == 0) break
      s = s + n
    }
    if (s == 0) exit
    url = substr(rest, s)
    # Cut at the first character that cannot appear in the href.
    sub(/["'"'"'<> \\].*/, "", url)
    print url
  }' "$WORK/tree.html" | sed 's/&amp;/\&/g')
CID=$(printf '%s' "$DEL" | grep -o 'contentid=[^&]*' | head -1 | sed 's/contentid=//')
[ -n "$DEL" ]; check "delete link located in the site-manager tree" $? "contentid=${CID:-none}"

if [ -n "$DEL" ]; then
  code=$(get "$WORK/del" "$BASE_URL/admin/$DEL" -b "$JAR" -c "$JAR" -L)
  info "delete http=$code"
  code=$(get "$WORK/gone" "$BASE_URL/$SLUG/" -L)
  hasmarker=$(grep -c "$MARKER" "$WORK/gone" 2>/dev/null)
  [ "$code" = "404" ] && [ "$hasmarker" -eq 0 ]
  check "page is gone from the front end after delete" $? "http=$code bodyMarker=$hasmarker"
else
  fail "page deleted (skipped - no delete link)"
  note "The test page '$TITLE' may still exist; remove it from the admin."
fi

# ===================================================================== end ===

head1 "Summary"
printf 'passed=%d failed=%d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
