#!/bin/sh
# Entrypoint wrapper for the Vintage Travel Mura CMS image.
#
# Hands off to the base lucee/lucee "-nginx" image's own startup command
# (supervisord, managing nginx + Tomcat/Lucee) via `exec "$@"` - this script
# never replaces it, it just optionally does some work first.
#
# When MURA_WARMUP=true, it runs Mura's documented warm-up sequence in the
# background once the server answers: a plain GET / (forces Lucee to compile
# the application) followed by GET /?appreload&applydbupdates (applies any
# pending Mura database updates). This mirrors the sequence in
# core/docker/local-demo/build/mura-run.sh. It is opt-in and off by default
# so `docker run` against an image with no datasource configured yet doesn't
# retry forever - MURA_DATASOURCE being unset just means Mura's own setup
# wizard is what answers GET /.
set -eu

MURA_WARMUP="${MURA_WARMUP:-false}"
MURA_WARMUP_HOST="${MURA_WARMUP_HOST:-127.0.0.1}"
MURA_WARMUP_TIMEOUT="${MURA_WARMUP_TIMEOUT:-180}"

mura_warmup() {
  waited=0

  # Wait for nginx/Lucee to accept connections before hitting Mura.
  while ! wget -q -O /dev/null "http://${MURA_WARMUP_HOST}/" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "${waited}" -ge "${MURA_WARMUP_TIMEOUT}" ]; then
      echo "mura-entrypoint: warm-up gave up waiting for http://${MURA_WARMUP_HOST}/ after ${MURA_WARMUP_TIMEOUT}s" >&2
      return 1
    fi
    sleep 1
  done

  echo "mura-entrypoint: warm-up - GET / (compile application)"
  wget -q -O /dev/null "http://${MURA_WARMUP_HOST}/" || true

  echo "mura-entrypoint: warm-up - GET /?appreload&applydbupdates"
  wget -q -O /dev/null "http://${MURA_WARMUP_HOST}/?appreload&applydbupdates" || true

  echo "mura-entrypoint: warm-up complete"
}

if [ "${MURA_WARMUP}" = "true" ]; then
  mura_warmup &
fi

exec "$@"
