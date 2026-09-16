#!/bin/sh
# Entrypoint wrapper for the Vintage Travel Mura CMS image.
#
# Hands off to the base lucee/lucee "-nginx" image's own startup command
# (supervisord, managing nginx + Tomcat/Lucee) via `exec "$@"` - this script
# never replaces it, it just does some work first:
#
#   1. sets a webroot-friendly umask (see below);
#   2. merges /opt/mura/cfconfig.d/*.json into Lucee's .CFConfig.json, so a
#      downstream image's Lucee settings (cache connections, inspectTemplate
#      ...) are in place before Lucee starts - see docker/Dockerfile;
#   3. when MURA_LOG_TAIL=true (default), tails every *.log Lucee or a plugin
#      writes under the server context's logs directory to stdout, so they
#      show up in `docker logs` next to application.log/exception.log (which
#      the Dockerfile symlinks to stdout directly);
#   4. when MURA_WARMUP=true, runs Mura's documented warm-up sequence in the
#      background once the server answers: a plain GET / (forces Lucee to
#      compile the application and, on a clean database, is the request Mura's
#      unattended setup uses) followed by GET /?appreload&applydbupdates
#      (applies any pending Mura database updates). It is opt-in and off by
#      default so `docker run` against an image with no datasource configured
#      yet doesn't retry forever.
set -eu

log() { echo "mura-entrypoint: $*"; }

# nginx workers run as www-data, while Tomcat/Lucee runs as root, and the base
# image's default umask (0027) makes everything Lucee creates root:root 0640
# inside 0750 directories. Mura generates content at runtime - uploaded assets
# and the resized image renditions under sites/<site>/cache/file, plus
# config/ and plugins/ - so with that umask nginx cannot read any of it: the
# static-file requests fall through try_files to the front controller and the
# site serves a Mura 404 page instead of the image. The Dockerfile's build-time
# chmod cannot help, because these directories do not exist until first boot.
#
# 0022 gives the conventional webroot permissions (dirs 0755, files 0644) so
# nginx can serve what Lucee writes. Override with MURA_UMASK if a deployment
# wants something stricter (and runs both processes as the same user).
#
# Both lines are needed: `umask` covers this script and anything supervisord
# starts directly, while UMASK is what Tomcat's own bin/catalina.sh reads -
# it unconditionally re-applies `umask 0027` unless UMASK is already set in
# the environment, so setting only the shell umask here would be undone the
# moment Lucee starts.
umask "${MURA_UMASK:-0022}"
UMASK="${MURA_UMASK:-0022}"
export UMASK

LUCEE_CFCONFIG="${LUCEE_CFCONFIG:-/opt/lucee/server/lucee-server/context/.CFConfig.json}"
LUCEE_LOG_DIR="${LUCEE_LOG_DIR:-/opt/lucee/server/lucee-server/context/logs}"
MURA_CFCONFIG_DIR="${MURA_CFCONFIG_DIR:-/opt/mura/cfconfig.d}"

MURA_LOG_TAIL="${MURA_LOG_TAIL:-true}"
# Comma-separated basenames (without .log) never tailed. out/err are Lucee's
# copies of System.out/err, which supervisord already streams from Tomcat.
MURA_LOG_TAIL_EXCLUDE="${MURA_LOG_TAIL_EXCLUDE:-out,err}"

MURA_WARMUP="${MURA_WARMUP:-false}"
# `localhost`, not 127.0.0.1: Mura's unattended setup records the default
# site's domain from the host of the first request it serves (rewriting
# 127.0.0.1 to localhost), and in production mode Mura 301s every request
# whose host is not one of the site's domains. Probing as 127.0.0.1 therefore
# matched nothing once a site was set up and, with MURA_PORT set, the redirect
# pointed at http://localhost:<MURA_PORT>/ - a port nothing listens on inside
# the container - which the previous `wget` followed for ever.
MURA_WARMUP_HOST="${MURA_WARMUP_HOST:-localhost}"
MURA_WARMUP_TIMEOUT="${MURA_WARMUP_TIMEOUT:-180}"

# ---------------------------------------------------------------- cfconfig ---

mura_merge_cfconfig() {
  if [ ! -d "${MURA_CFCONFIG_DIR}" ]; then
    return 0
  fi
  set -- "${MURA_CFCONFIG_DIR}"/*.json
  if [ ! -e "$1" ]; then
    return 0
  fi
  if [ ! -w "${LUCEE_CFCONFIG}" ]; then
    log "WARNING: ${LUCEE_CFCONFIG} is not writable - skipping the merge of ${MURA_CFCONFIG_DIR}/*.json" >&2
    return 0
  fi
  if ! mura-merge-cfconfig "${LUCEE_CFCONFIG}" "$@"; then
    log "WARNING: merging ${MURA_CFCONFIG_DIR}/*.json into ${LUCEE_CFCONFIG} failed - Lucee starts with the configuration baked into the image" >&2
  fi
}

# ---------------------------------------------------------------- log tail ---

# application.log and exception.log are symlinks to /dev/stdout (Dockerfile).
# Anything else in the directory - Lucee's scheduler/mail/datasource logs, or a
# plugin's writeLog(file="MyPlugin") - is a real file, and new ones can appear
# at any time, so poll for them and follow each with `tail -F`, prefixed with
# its name. Existing content is not replayed (-n 0); only new lines stream.
mura_log_tail() {
  tailed=" "
  while :; do
    for f in "${LUCEE_LOG_DIR}"/*.log; do
      [ -f "$f" ] || continue
      [ -L "$f" ] && continue
      case "${tailed}" in *" $f "*) continue ;; esac
      name=$(basename "$f" .log)
      case ",${MURA_LOG_TAIL_EXCLUDE}," in *",${name},"*) tailed="${tailed}${f} "; continue ;; esac
      tail -n 0 -F "$f" 2>/dev/null | sed -u "s|^|lucee/${name}: |" &
      tailed="${tailed}${f} "
    done
    sleep 10
  done
}

# ----------------------------------------------------------------- warm-up ---

# http_status <url> -> prints "<last status code> <last Location header>",
# following at most 3 redirects. Any 3xx left as the *last* status means the
# chain did not resolve within the container: Mura is redirecting to a host
# (or host:port) we cannot reach from in here, i.e. a domain mismatch.
http_status() {
  wget -q -O /dev/null --server-response --max-redirect=3 --tries=1 "$1" 2>&1 |
    awk '/^  HTTP\//{code=$2} /^  [Ll]ocation:/{loc=$2} END{print code, loc}'
}

# warm_get <label> <url>: one warm-up request, classified in the log.
warm_get() {
  set -- "$1" "$2" $(http_status "$2")
  label="$1"; url="$2"; code="${3:-}"; loc="${4:-}"
  case "${code}" in
    30[12378])
      log "warm-up - ${label} -> ${code} to ${loc:-?} (still redirecting after 3 hops)."
      log "warm-up - Mura reached the application but the site's recorded domain is not '${MURA_WARMUP_HOST}', so in production mode it redirects the request away (to a host/port nothing answers on inside the container). The warm-up work itself has happened; to silence this set MURA_WARMUP_HOST to the site's domain, or add '${MURA_WARMUP_HOST}' as a domain alias in Site Settings."
      ;;
    "")
      log "warm-up - ${label} -> no HTTP response from ${url}" >&2
      ;;
    *)
      log "warm-up - ${label} -> ${code}"
      ;;
  esac
}

mura_warmup() {
  waited=0

  # Wait for Lucee to answer (any status, redirects included). nginx starts
  # before Tomcat and answers 502/503/504 on its own until Lucee is listening,
  # so those do not count.
  while :; do
    set -- $(http_status "http://${MURA_WARMUP_HOST}/")
    case "${1:-}" in
      "" | 502 | 503 | 504) ;;
      *) break ;;
    esac
    waited=$((waited + 1))
    if [ "${waited}" -ge "${MURA_WARMUP_TIMEOUT}" ]; then
      log "warm-up gave up waiting for http://${MURA_WARMUP_HOST}/ after ${MURA_WARMUP_TIMEOUT}s" >&2
      return 1
    fi
    sleep 1
  done

  warm_get "GET / (compile application)" "http://${MURA_WARMUP_HOST}/"
  warm_get "GET /?appreload&applydbupdates" "http://${MURA_WARMUP_HOST}/?appreload&applydbupdates"

  log "warm-up complete"
}

# -------------------------------------------------------------------- main ---

mura_merge_cfconfig

if [ "${MURA_LOG_TAIL}" = "true" ]; then
  mura_log_tail &
fi

if [ "${MURA_WARMUP}" = "true" ]; then
  mura_warmup &
fi

exec "$@"
