# Mura CMS on Lucee 6.2 LTS - Vintage Travel base image.
#
# Publishes a base image (vintagetravel/muracms:<version>) that downstream
# site repos FROM and then COPY their own site into /var/www/sites/<site>
# and any plugins into /var/www/plugins.
#
# Base: the official Lucee "-nginx" variant (nginx on :80 in front of
# Tomcat/Lucee on :8888 via supervisord - see
# https://github.com/lucee/lucee-dockerfiles). Chosen over the plain Tomcat
# image + Tuckey UrlRewriteFilter because overriding its nginx config turned
# out to be simple: the base image already documents (in its own
# nginx/default.conf, as a commented-out example) exactly the try_files
# front-controller rewrite Mura needs, so docker/nginx/default.conf below
# just enables it. That also gets nginx serving static assets directly
# instead of round-tripping them through Lucee, and keeps the Lucee admin
# blocked at the edge by default.
#
# Note: this base image's own Dockerfile declares
# `ONBUILD RUN rm -rf /var/www/*`. That trigger fires once, on THIS build
# (wiping the base image's placeholder /var/www content right after FROM,
# before the COPY below runs) - ONBUILD triggers are not inherited by a
# grandchild build, so a downstream `FROM vintagetravel/muracms:...` in the
# website project's own Dockerfile will NOT wipe /var/www again, which is
# exactly what lets it COPY sites/plugins in additively.
ARG LUCEE_TAG=6.2.8.20-nginx-tomcat11.0-jdk21-temurin-noble
FROM lucee/lucee:${LUCEE_TAG}

ARG MURA_VERSION=7.4.1
ARG VCS_REF
ARG BUILD_DATE

LABEL org.opencontainers.image.title="Mura CMS" \
      org.opencontainers.image.description="Mura CMS on Lucee 6.2 LTS (nginx + Tomcat/Lucee), base image for Vintage Travel site builds" \
      org.opencontainers.image.version="${MURA_VERSION}" \
      org.opencontainers.image.vendor="Vintage Travel" \
      org.opencontainers.image.source="https://github.com/David-Polehonski/MuraCMS" \
      org.opencontainers.image.licenses="GPL-2.0-with-exceptions" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

# Pin the Lucee admin password at build time; override with --build-arg or,
# preferably, at `docker run`/compose time with -e LUCEE_ADMIN_PASSWORD=...
# since ENV values baked into an image layer are visible via `docker history`.
ARG LUCEE_ADMIN_PASSWORD=please_override_at_runtime
ENV LUCEE_ADMIN_PASSWORD=${LUCEE_ADMIN_PASSWORD} \
    MURA_ORMENABLED=false \
    MURA_ALLOWAUTOUPDATES=false \
    MURA_WARMUP=false

# Custom server block: adds the Mura front-controller rewrite on top of the
# base image's Lucee proxy / admin-blocking rules (see docker/nginx/default.conf
# for what changed and why).
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf

# Application code. Respects the repo's .dockerignore (.git, docker/ itself,
# core/docker legacy material, core/tests, node_modules, *.zip, logs, etc).
#
# .dockerignore excludes docker/ wholesale but negates docker/entrypoint.sh,
# docker/nginx/ and docker/lucee/ so the explicit COPYs in this file can reach
# them - dockerignore filtering applies to the whole build context, so that
# negation also lets those files ride along into this COPY. The rm -rf below
# (next RUN) removes the resulting /var/www/docker so no build tooling ends
# up alongside the application content it's building.
COPY . /var/www

# Runtime-writable locations Mura needs at boot / during content editing.
# Several of these (config/*.cfm, sites/default/assets, sites/default/cache,
# plugins/) are .gitignored - Mura or its unattended Docker setup
# (core/appcfc/setup_check.cfm) writes/generates them on first boot, so a
# fresh checkout won't have them yet; create them so the ownership/permission
# chmod below actually reaches them. The base image runs Tomcat/nginx as
# root by default (this is not the "-nonroot" tag), so this is a portability
# safety net rather than a strict requirement today.
#
# Logs: Lucee 6.2 in this image runs in "single" mode, so application.log and
# exception.log are written under /opt/lucee/server/lucee-server/context/logs
# - NOT /opt/lucee/web/logs, which earlier versions of this file symlinked
# (verified: a writeLog(application=true) line only ever landed in the
# server-context directory). Symlink the real files to stdout so they reach
# `docker logs`; the web-context links are kept in case a future Lucee tag
# goes back to a separate web context. Any other *.log Lucee or a plugin
# creates in that directory (e.g. a plugin's writeLog(file="MyPlugin")) is
# tailed to stdout by docker/entrypoint.sh (MURA_LOG_TAIL).
RUN set -eux; \
    rm -rf /var/www/docker; \
    mkdir -p \
        /var/www/config \
        /var/www/plugins \
        /var/www/sites/default/assets \
        /var/www/sites/default/cache \
    ; \
    chmod -R u+rwX,g+rwX,o+rwX \
        /var/www/config \
        /var/www/plugins \
        /var/www/sites \
        /var/www/themes \
        /var/www/modules \
    ; \
    mkdir -p /opt/lucee/web/logs /opt/lucee/server/lucee-server/context/logs; \
    ln -sf /dev/stdout /opt/lucee/web/logs/application.log; \
    ln -sf /dev/stdout /opt/lucee/web/logs/exception.log; \
    ln -sf /dev/stdout /opt/lucee/server/lucee-server/context/logs/application.log; \
    ln -sf /dev/stdout /opt/lucee/server/lucee-server/context/logs/exception.log

# Lucee configuration extension point.
#
# Lucee keeps its whole configuration in one JSON document; in this image's
# "single" mode that is /opt/lucee/server/lucee-server/context/.CFConfig.json
# and there is no separate web context or deploy folder to drop overrides
# into. mura-merge-cfconfig merges every /opt/mura/cfconfig.d/*.json fragment
# into that document (per-key shallow merge for objects such as "caches",
# straight replace for scalars). The base image's own fragments live in
# /opt/mura/cfconfig.base.d/ and are applied here, at build time, once.
# /opt/mura/cfconfig.d/ is left empty for downstream images: everything in it
# is merged by docker/entrypoint.sh on every boot, so a site image only has
# to `COPY my-lucee.json /opt/mura/cfconfig.d/50-site.json` to add cache
# connections, a default object cache, mappings, etc. Fragments are applied
# in name order; later ones win. Keeping the base fragment out of the
# boot-time directory means a downstream image that edits .CFConfig.json
# directly at build time (e.g. sets inspectTemplate to "never") is not
# overridden again at start-up.
#
# The base fragment sets inspectTemplate to "${LUCEE_INSPECT_TEMPLATE:once}":
# Lucee 6.2.8 resolves that placeholder from the environment (verified), so
# LUCEE_INSPECT_TEMPLATE=never|once|always|auto picks the behaviour per
# container. Without it Lucee's built-in default is "auto", under which an
# edited bind-mounted template was never re-read (only a Lucee restart
# helped). "once" re-checks a template's timestamp once per request - the
# right default for a base image that is mostly run in development; set
# LUCEE_INSPECT_TEMPLATE=never in production and deploy by rebuilding.
#
# The same fragment raises Lucee's "application" logger from the stock level
# "error" to "info": at "error" a plain writeLog(text=...) was discarded
# before it reached application.log at all, so the stdout symlink above never
# had anything to carry.
COPY docker/lucee/merge-cfconfig.py /usr/local/bin/mura-merge-cfconfig
COPY docker/lucee/cfconfig.d/ /opt/mura/cfconfig.base.d/
RUN set -eux; \
    chmod +x /usr/local/bin/mura-merge-cfconfig; \
    mura-merge-cfconfig /opt/lucee/server/lucee-server/context/.CFConfig.json /opt/mura/cfconfig.base.d/*.json; \
    mkdir -p /opt/mura/cfconfig.d

COPY docker/entrypoint.sh /usr/local/bin/mura-entrypoint.sh
RUN chmod +x /usr/local/bin/mura-entrypoint.sh

# No VOLUME declarations. Earlier versions declared /var/www/plugins and
# /var/www/sites/default/assets as image volumes; a VOLUME is inherited by
# every downstream image and cannot be undone, and it froze any plugins a
# site image COPYed into /var/www/plugins inside an anonymous volume created
# by the first container - rebuilt plugins were never seen again. Mount what
# you want to persist explicitly (docker-compose.yml does).

EXPOSE 80

# Cheap-ish liveness check: any HTTP response on / means nginx is up and
# Lucee is executing CFML - a Mura setup page, a Mura error page and Mura's
# domain redirect (wget exit 8 on a 3xx with --max-redirect=0) all count;
# we're not asserting the app is fully configured.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
    CMD wget -q -O /dev/null --max-redirect=0 http://127.0.0.1/ || [ $? -eq 8 ] || exit 1

ENTRYPOINT ["/usr/local/bin/mura-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
