# Mura CMS container image

This folder builds the base image Vintage Travel publishes for Mura CMS on
Lucee 6.2 LTS: `vintagetravel/muracms:<version>` (e.g. `7.3.0`). Website
projects `FROM` it and add their own site/plugins on top - see
[Extending this image](#extending-this-image-a-website-project).

Base image: `lucee/lucee:6.2.8.20-nginx-tomcat11.0-jdk21-temurin-noble`
(nginx on port 80 in front of Tomcat/Lucee on 8888, managed by supervisord -
see [lucee/lucee-dockerfiles](https://github.com/lucee/lucee-dockerfiles)).
`docker/nginx/default.conf` replaces the stock server block to add Mura's
front-controller rewrite (`try_files $uri $uri/ /index.cfm$uri?$args`,
excluding `/lucee`, `/CFIDE`, `/lucee-server`, `/WEB-INF` and the Lucee
cfchart renderer, all of which stay blocked at the edge). Static files
(css/js/images/uploaded assets) are served by nginx directly.

## Build

```sh
docker build -t vintagetravel/muracms:7.3.0 -f docker/Dockerfile .
```

Useful build args:

| Arg | Default | Purpose |
| --- | --- | --- |
| `LUCEE_TAG` | `6.2.8.20-nginx-tomcat11.0-jdk21-temurin-noble` | Base image tag |
| `MURA_VERSION` | `7.3.0` | Stamped into the `org.opencontainers.image.version` label |
| `LUCEE_ADMIN_PASSWORD` | `please_override_at_runtime` | Baked-in fallback; always override at `docker run`/compose time instead (see below) - a build-arg default ends up visible in `docker history` |
| `VCS_REF`, `BUILD_DATE` | unset | OCI labels, e.g. `--build-arg VCS_REF=$(git rev-parse HEAD) --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)` |

## Local development stack

```sh
cp .env.example .env   # then edit the passwords
docker compose up --build
```

This starts:

- `mssql` - SQL Server 2022, healthchecked with `sqlcmd` before `mura` is
  allowed to start (`depends_on: condition: service_healthy`), data in the
  named volume `mssql_data`.
- `mura` - built from `docker/Dockerfile`, published on `http://localhost:8080`,
  with `sites/`, `plugins/`, `themes/`, `modules/` and `config/` bind-mounted
  from the repo so edits show up without a rebuild.

First run: because `MURA_DATASOURCE` is set, Mura's unattended setup
(`core/appcfc/setup_check.cfm`) creates the database and runs the install
wizard automatically the first time it's asked - `MURA_WARMUP=true` triggers
that by requesting `/` then `/?appreload&applydbupdates` itself in the
background shortly after boot, so `docker compose logs -f mura` will show it
happening without you needing to open a browser first. Once it settles, log
in to `/admin` with `MURA_ADMIN_USERNAME` / `MURA_ADMIN_PASSWORD`.

This stack is dev-only: plain HTTP, `MURA_SECURECOOKIES=false` (see
[TLS and secure cookies](#tls-and-secure-cookies)), and passwords sourced
from a git-ignored `.env` (`.env.example` documents every key it needs; do
not reuse these values anywhere real).

## Extending this image (a website project)

```Dockerfile
FROM vintagetravel/muracms:7.3.0

COPY sites/vintagetravel /var/www/sites/vintagetravel
COPY plugins /var/www/plugins
```

This works because `lucee/lucee`'s own Dockerfile registers
`ONBUILD RUN rm -rf /var/www/*`, which only fires once - during *this*
image's build, right after its `FROM`, wiping the base image's placeholder
`/var/www` before `vintagetravel/muracms`'s own `COPY . /var/www` runs.
ONBUILD triggers are not inherited by a grandchild build, so a website
project's own `FROM vintagetravel/muracms:7.3.0` does not wipe `/var/www`
again - it lands on top of the full Mura CMS tree already baked into the
base image, and the `COPY`s above add to it rather than replacing it.

Point the site's own `sites/Application.cfc` / site config at whatever
hostname(s) it needs, and give the site its own datasource via the
`MURA_*` env vars below rather than editing `config/` inside the image.

## Environment variable reference

Mura reads its `settings.ini` keys from `MURA_<UPPERCASEKEY>` environment
variables (`core/appcfc/applicationSettings.cfm`); the ones below are the
ones this image and its compose stack rely on directly. Any other
`settings.ini` key can be set the same way.

| Variable | Purpose |
| --- | --- |
| `LUCEE_ADMIN_PASSWORD` | Lucee server/web administrator password (native Lucee env var, not Mura-specific) |
| `MURA_DATASOURCE` | Datasource name; **setting this is what switches on Mura's unattended Docker setup** |
| `MURA_DATABASE`, `MURA_DBTYPE`, `MURA_DBHOST`, `MURA_DBPORT`, `MURA_DBUSERNAME`, `MURA_DBPASSWORD` | Datasource connection details (`MURA_DBTYPE=mssql` for this stack) |
| `MURA_DBCONNECTIONSTRING`, `MURA_DBCLASS` | Use a full JDBC connection string instead of host/port/database |
| `MURA_ADMIN_USERNAME`, `MURA_ADMIN_PASSWORD`, `MURA_ADMINEMAIL` | Mura CMS admin account created by unattended setup |
| `MURA_APPRELOADKEY` | Shared secret required on `?appreload` requests |
| `MURA_ORMENABLED` | Set `false` unless a plugin needs Hibernate ORM |
| `MURA_ALLOWAUTOUPDATES` | Set `false` - updates belong in the image build, not a running container |
| `MURA_SECURECOOKIES` | Set `false` for plain-HTTP dev; leave at Mura's default (effectively `true`) once TLS terminates in front of the site |
| `MURA_SITEIDINURLS`, `MURA_INDEXFILEINURLS` | Mura URL formatting flags |
| `MURA_WARMUP` | This image's own entrypoint flag (`docker/entrypoint.sh`), not a Mura setting: `true` runs the GET `/` + GET `/?appreload&applydbupdates` warm-up in the background after boot |
| `MURA_WARMUP_HOST`, `MURA_WARMUP_TIMEOUT` | Tune the warm-up's target host (default `127.0.0.1`) and how long it waits for the server to answer before giving up (default 180s) |

## TLS and secure cookies

This image and `docker-compose.yml` are HTTP-only - nginx listens on :80,
there's no certificate handling here. Mura's cookies default to `Secure`,
which browsers silently drop over plain HTTP, so local dev sets
`MURA_SECURECOOKIES=false`. In any environment with a real hostname, put a
TLS-terminating reverse proxy / load balancer in front of this container
(nginx already forwards `X-Forwarded-Proto`) and leave `MURA_SECURECOOKIES`
unset so cookies stay `Secure`.

## Notes / decisions

- **nginx vs Tuckey**: the `-nginx` variant was used instead of the plain
  Tomcat image + Tuckey `UrlRewriteFilter` (`core/docker/build/urlrewrite.xml`).
  Overriding its config turned out to be a single-file swap
  (`docker/nginx/default.conf`), and it buys static-file serving off the
  JVM plus the Lucee admin being blocked at the edge by default.
- **Volumes**: `/var/www/plugins` and `/var/www/sites/default/assets` are
  declared as image `VOLUME`s - sensible anonymous-volume points for a
  container run standalone; the compose stack instead bind-mounts
  `sites/`, `plugins/`, `themes/`, `modules/` and `config/` from the repo
  for live editing.
- **core/docker excluded**: the legacy blueriver/Lucee 5 docker material
  under `core/docker` is left in the repo for reference but excluded from
  the build context (`.dockerignore`) - it's superseded by this folder.
- **core/tests excluded**: also excluded from the build context to keep the
  published base image smaller; add it back in `.dockerignore` if a project
  wants `box testbox run` to work inside the container itself.
