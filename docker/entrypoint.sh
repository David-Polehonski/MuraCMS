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
