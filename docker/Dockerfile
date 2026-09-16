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

ARG MURA_VERSION=7.3.0
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
# .dockerignore excludes docker/ wholesale but negates docker/entrypoint.sh
# and docker/nginx/default.conf so the explicit COPYs above can reach them -
# dockerignore filtering applies to the whole build context, so that
# negation also lets those two files ride along into this COPY. The rm -rf
# below (next RUN) removes the resulting /var/www/docker so no build
# tooling ends up alongside the application content it's building.
COPY . /var/www

# Runtime-writable locations Mura needs at boot / during content editing.
# Several of these (config/*.cfm, sites/default/assets, sites/default/cache,
# plugins/) are .gitignored - Mura or its unattended Docker setup
# (core/appcfc/setup_check.cfm) writes/generates them on first boot, so a
# fresh checkout won't have them yet; create them so the ownership/permission
# chmod below actually reaches them. The base image runs Tomcat/nginx as
# root by default (this is not the "-nonroot" tag), so this is a portability
# safety net rather than a strict requirement today.
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
    mkdir -p /opt/lucee/web/logs; \
    ln -sf /dev/stdout /opt/lucee/web/logs/application.log; \
    ln -sf /dev/stdout /opt/lucee/web/logs/exception.log

COPY docker/entrypoint.sh /usr/local/bin/mura-entrypoint.sh
RUN chmod +x /usr/local/bin/mura-entrypoint.sh

# Sensible extension points for a downstream site image / local dev bind
# mounts: uploaded/rendered assets for the default site, and shared plugins.
VOLUME ["/var/www/plugins", "/var/www/sites/default/assets"]

EXPOSE 80

# Cheap-ish liveness check: any HTTP response on / means nginx is up and
# Lucee is executing CFML - a Mura setup page and a Mura error page both
# count, we're not asserting the app is fully configured.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
    CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1

ENTRYPOINT ["/usr/local/bin/mura-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
