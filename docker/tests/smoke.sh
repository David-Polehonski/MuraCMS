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

# ==================================== 4. container / Lucee 6 regressions ====
#
# Regression guards for the defects found in the first downstream site build
# (see docker/README.md, "What the image guarantees"). They need `docker
# compose` access to the running stack - they write a scratch .cfm into the
# site directory inside the container, edit it, and read the container's logs -
# so they are skipped with SKIP_DOCKER=1, or when docker compose cannot see a
# service called COMPOSE_SERVICE (default "mura") from the current directory.

COMPOSE_SERVICE="${COMPOSE_SERVICE:-mura}"
SMOKE_SITE_DIR="${MURA_SMOKE_SITE_DIR:-/var/www/sites/$SITE_ID}"

dcx() { docker compose exec -T "$COMPOSE_SERVICE" sh -c "$1"; }

if [ "${SKIP_DOCKER:-0}" != "1" ] && command -v docker >/dev/null 2>&1 \
   && docker compose ps -q "$COMPOSE_SERVICE" 2>/dev/null | grep -q .; then

  head1 "Container and Lucee 6 regression checks (docker compose service: $COMPOSE_SERVICE)"

  # sites/Application.cfc answers "Access Restricted." to any template under a
  # site that is not index.cfm, a handful of named files, or something inside a
  # "remote" directory - so the scratch template lives in sites/<site>/remote/.
  SCRATCH="_smoke_${STAMP}.cfm"
  SCRATCH_PATH="$SMOKE_SITE_DIR/remote/$SCRATCH"
  SCRATCH_URL="$BASE_URL/sites/$SITE_ID/remote/$SCRATCH"
  trap 'dcx "rm -f $SCRATCH_PATH" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

  # The scratch template runs under Mura's own Application.cfc, so it can use
  # the live configBean and the Mura scope. It prints key=value lines.
  dcx "mkdir -p $SMOKE_SITE_DIR/remote" >/dev/null 2>&1
  sed "s/__STAMP__/$STAMP/g; s/__SITE__/$SITE_ID/g; s/__HOME__/$HOME_ID/g" <<'CFM' | dcx "cat > $SCRATCH_PATH"
<cfsetting showdebugoutput="false">
<cfcontent type="text/plain; charset=utf-8">
<cfset out=[]>
<cfset m=createObject("component","mura.MuraScope").init('__SITE__')>
<cfset cfg=application.configBean>
<cfset arrayAppend(out,"mode=" & cfg.getMode())>
<cfset arrayAppend(out,"marker=SMOKE_MARKER_1")>
<cfset arrayAppend(out,"inspect_template=" & getPageContext().getConfig().getInspectTemplate())>
<cfset envKey=structKeyExists(request.muraSysEnv,'MURA_ENCRYPTIONKEY') ? request.muraSysEnv.MURA_ENCRYPTIONKEY : ''>
<cfset arrayAppend(out,"key_len=" & len(cfg.getEncryptionKey()))>
<cfset arrayAppend(out,"key_matches_env=" & (len(envKey) ? lcase(envKey eq cfg.getEncryptionKey()) : 'unset'))>
<cfset iniPath=expandPath('/muraWRM/config/settings.ini.cfm')>
<cfset arrayAppend(out,"ini_has_mode_section=" & lcase(structKeyExists(getProfileSections(iniPath), cfg.getMode())))>
<cfset arrayAppend(out,"key_in_ini=" & lcase(len(getProfileString(iniPath, cfg.getMode(), 'encryptionkey')) gt 0))>
<cfset arrayAppend(out,"key_hash=" & left(hash(cfg.getEncryptionKey()),10))>
<cfset arrayAppend(out,"ini_key_hash=" & left(hash(getProfileString(iniPath, cfg.getMode(), 'encryptionkey')),10))>
<cftry>
	<cfset rs=m.getBean('content').getFeed().setSiteID('__SITE__').where().prop('releaseDate').isEQ('').getQuery()>
	<cfset arrayAppend(out,"feed_date_empty=ok:" & rs.recordcount)>
	<cfcatch><cfset arrayAppend(out,"feed_date_empty=ERROR:" & cfcatch.message)></cfcatch>
</cftry>
<cftry>
	<cfset rs=m.getBean('content').getFeed().setSiteID('__SITE__').where().prop('orderno').isEQ('').getQuery()>
	<cfset arrayAppend(out,"feed_numeric_empty=ok:" & rs.recordcount)>
	<cfcatch><cfset arrayAppend(out,"feed_numeric_empty=ERROR:" & cfcatch.message)></cfcatch>
</cftry>
<cftry>
	<cfset em=cfg.getClassExtensionManager()>
	<cfset st=em.getSubTypeByName(type='Page',subtype='Default',siteid='__SITE__')>
	<cfif st.getIsNew()><cfset st.save()></cfif>
	<cfset es=st.getExtendSetBean()>
	<cfset es.setSiteID('__SITE__')><cfset es.setName('Smoke')><cfset es.load()>
	<cfif es.getIsNew()><cfset es.save()></cfif>
	<cfset at=es.getAttributeBean()>
	<cfset at.setSiteID('__SITE__')><cfset at.setName('smokeDate')><cfset at.load()>
	<cfif at.getIsNew()>
		<cfset at.setLabel('Smoke Date')><cfset at.setType('Date')><cfset at.setValidation('Date')><cfset at.save()>
	</cfif>
	<cfset em.purgeDefinitionsQuery()>
	<cfset node=m.getBean('content').set({siteid='__SITE__',parentid='__HOME__',type='Page',subtype='Default',title='Smoke Extend __STAMP__',approved=1,smokeDate=now()}).save()>
	<cfset rs=m.getBean('content').getFeed().setSiteID('__SITE__').where().prop('smokeDate').isEQ('').getQuery()>
	<cfset arrayAppend(out,"feed_extdate_empty=ok:" & rs.recordcount)>
	<cfset rs=m.getBean('content').getFeed().setSiteID('__SITE__').addParam(field='smokeDate',criteria='',condition='=',datatype='date').getQuery()>
	<cfset arrayAppend(out,"feed_extdate_typed_empty=ok:" & rs.recordcount)>
	<cfset rs=m.getBean('content').getFeed().setSiteID('__SITE__').where().prop('smokeDate').isGT(dateAdd('d',-1,now())).getQuery()>
	<cfset arrayAppend(out,"feed_extdate_value=ok:" & rs.recordcount)>
	<cfset node.delete()>
	<cfcatch><cfset arrayAppend(out,"feed_extdate_empty=ERROR:" & cfcatch.message & " " & cfcatch.detail)></cfcatch>
</cftry>
<cfset writeLog(application=true, text="smoke-log-__STAMP__")>
<cfset arrayAppend(out,"logged=smoke-log-__STAMP__")>
<cfoutput>#arrayToList(out, chr(10))#</cfoutput>
CFM

  # kv <file> <key> -> value of "key=..." in the scratch output
  kv() { grep "^$2=" "$1" | head -1 | cut -d= -f2- | tr -d '\r'; }

  code=$(get "$WORK/sm1" "$SCRATCH_URL" -L)
  [ "$code" = "200" ] && [ "$(kv "$WORK/sm1" marker)" = "SMOKE_MARKER_1" ]
  check "scratch template executes under Mura's Application.cfc" $? "http=$code url=$SCRATCH_URL"

  # --- (7) MURA_MODE works on a clean database ----------------------------
  want_mode=$(dcx 'printf %s "${MURA_MODE:-production}"' 2>/dev/null | tr -d '\r')
  got_mode=$(kv "$WORK/sm1" mode)
  [ -n "$got_mode" ] && [ "$got_mode" = "${want_mode:-production}" ]
  check "configBean.getMode() is '$want_mode' (MURA_MODE honoured on first boot)" $? "getMode()=$got_mode ini_has_[$want_mode]_section=$(kv "$WORK/sm1" ini_has_mode_section)"
  [ "$(kv "$WORK/sm1" ini_has_mode_section)" = "true" ]
  check "config/settings.ini.cfm has a [$want_mode] section" $? ""

  # --- (6) encryption key is explicit, or persisted ------------------------
  kme=$(kv "$WORK/sm1" key_matches_env); kii=$(kv "$WORK/sm1" key_in_ini); klen=$(kv "$WORK/sm1" key_len)
  kh=$(kv "$WORK/sm1" key_hash); ikh=$(kv "$WORK/sm1" ini_key_hash)
  if [ "$kme" = "unset" ]; then
    [ "$kii" = "true" ] && [ "${klen:-0}" -gt 0 ] && [ -n "$kh" ] && [ "$kh" = "$ikh" ]
    check "no MURA_ENCRYPTIONKEY: generated key is persisted to config/settings.ini.cfm and is the key in use" $? "key_len=$klen key_in_ini=$kii key_hash=$kh ini_key_hash=$ikh"
    note "MURA_ENCRYPTIONKEY is not set for this container - set it; a generated key only survives as long as config/ does."
  else
    [ "$kme" = "true" ]
    check "configBean uses MURA_ENCRYPTIONKEY from the environment" $? "key_len=$klen key_matches_env=$kme"
  fi

  # --- (8) Lucee 6 empty-string binds -------------------------------------
  for k in feed_date_empty feed_numeric_empty feed_extdate_empty feed_extdate_typed_empty feed_extdate_value; do
    v=$(kv "$WORK/sm1" "$k")
    case "$v" in ok:*) r=0 ;; *) r=1 ;; esac
    case "$k" in
      feed_date_empty)         d="feed: prop('releaseDate').isEQ('') does not throw (date bind)" ;;
      feed_numeric_empty)      d="feed: prop('orderno').isEQ('') does not throw (numeric bind)" ;;
      feed_extdate_empty)      d="feed: Date extended attribute with '' criteria does not throw" ;;
      feed_extdate_typed_empty) d="feed: typed (datatype=date) '' criteria binds as NULL" ;;
      feed_extdate_value)      [ "$v" = "ok:1" ] || r=1; d="feed: Date extended attribute finds the node it was set on" ;;
    esac
    check "$d" $r "$k=$v"
  done

  # --- (2) an edited template is re-read without a restart ----------------
  sleep 1
  dcx "sed -i 's/SMOKE_MARKER_1/SMOKE_MARKER_2/' $SCRATCH_PATH"
  code=$(get "$WORK/sm2" "$SCRATCH_URL" -L)
  [ "$code" = "200" ] && [ "$(kv "$WORK/sm2" marker)" = "SMOKE_MARKER_2" ]
  check "edited template is served on the next request (no Lucee restart)" $? "http=$code marker=$(kv "$WORK/sm2" marker) inspectTemplate=$(kv "$WORK/sm2" inspect_template) (0=always 1=once 2=never 8=auto)"

  # --- (1) Lucee log lines reach docker logs --------------------------------
  found=0
  for i in 1 2 3 4 5 6; do
    docker compose logs --no-color "$COMPOSE_SERVICE" 2>/dev/null > "$WORK/logs"
    grep -q "smoke-log-$STAMP" "$WORK/logs" && found=1 && break
    sleep 2
  done
  [ "$found" -eq 1 ]
  check "a writeLog(application=true) line appears in 'docker compose logs $COMPOSE_SERVICE'" $? "marker=smoke-log-$STAMP found=$found"
  syms=$(dcx 'ls -l /opt/lucee/server/lucee-server/context/logs/application.log /opt/lucee/server/lucee-server/context/logs/exception.log 2>/dev/null | grep -c /dev/stdout' | tr -d '\r')
  [ "${syms:-0}" -eq 2 ]
  check "server-context application.log and exception.log are symlinked to stdout" $? "symlinks=${syms:-0} of 2"

  # --- (4) warm-up finished and did not loop --------------------------------
  wc_done=$(grep -c 'mura-entrypoint: warm-up complete' "$WORK/logs")
  wc_gaveup=$(grep -c 'warm-up gave up' "$WORK/logs")
  wc_redir=$(grep -c 'still redirecting' "$WORK/logs")
  [ "${wc_done:-0}" -ge 1 ] && [ "${wc_gaveup:-0}" -eq 0 ]
  check "entrypoint warm-up completed (bounded redirects, no give-up)" $? "complete=$wc_done gaveUp=$wc_gaveup domainMismatch=$wc_redir"
  [ "${wc_redir:-0}" -eq 0 ] || note "warm-up saw a domain redirect - the site's recorded domain is not MURA_WARMUP_HOST; see the entrypoint log line for the fix."

  # --- (3) no inherited VOLUMEs --------------------------------------------
  cid=$(docker compose ps -q "$COMPOSE_SERVICE" | head -1)
  img=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)
  # Newer Docker engines drop a null Volumes key from the image config entirely,
  # so look for a populated "Volumes" object in the whole Config document.
  vols=$(docker image inspect --format '{{json .Config}}' "$img" 2>/dev/null | grep -o '"Volumes":{[^}]*}' | head -1)
  [ -z "$vols" ]
  check "image declares no VOLUME (nothing for a downstream image to inherit)" $? "image=$img volumes=${vols:-none}"

  # --- (5) mssql healthcheck ------------------------------------------------
  mcid=$(docker compose ps -q mssql 2>/dev/null | head -1)
  if [ -n "$mcid" ]; then
    hs=$(docker inspect --format '{{.State.Health.Status}}' "$mcid" 2>/dev/null)
    [ "$hs" = "healthy" ]
    check "mssql healthcheck (sqlcmd tools18 -C, falling back to tools) reports healthy" $? "health=$hs"
  fi

  dcx "rm -f $SCRATCH_PATH" >/dev/null 2>&1
else
  head1 "Container and Lucee 6 regression checks"
  note "skipped (SKIP_DOCKER=1, or 'docker compose ps $COMPOSE_SERVICE' finds nothing from this directory)"
fi

# ===================================================================== end ===

head1 "Summary"
printf 'passed=%d failed=%d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
