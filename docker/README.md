# Mura CMS container image

This folder builds the base image Vintage Travel publishes for Mura CMS on
Lucee 6.2 LTS: `vintagetravel/muracms:<version>` (e.g. `7.4.1`). Website
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
docker build -t vintagetravel/muracms:7.4.1 -f docker/Dockerfile .
```

Useful build args:

| Arg | Default | Purpose |
| --- | --- | --- |
| `LUCEE_TAG` | `6.2.8.20-nginx-tomcat11.0-jdk21-temurin-noble` | Base image tag |
| `MURA_VERSION` | `7.4.1` | Stamped into the `org.opencontainers.image.version` label |
| `LUCEE_ADMIN_PASSWORD` | `please_override_at_runtime` | Baked-in fallback; always override at `docker run`/compose time instead (see below) - a build-arg default ends up visible in `docker history` |
| `VCS_REF`, `BUILD_DATE` | unset | OCI labels, e.g. `--build-arg VCS_REF=$(git rev-parse HEAD) --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)` |

## Local development stack

```sh
cp .env.example .env   # then edit the passwords and MURA_ENCRYPTIONKEY
docker compose up --build
```

This starts (compose project name `murabase`):

- `mssql` - SQL Server 2022, healthchecked with `sqlcmd` before `mura` is
  allowed to start (`depends_on: condition: service_healthy`; the check
  tries `/opt/mssql-tools18/bin/sqlcmd -C` first and falls back to
  `/opt/mssql-tools/bin/sqlcmd`, so both current and older `2022-latest`
  builds work), data in the named volume `mssql_data`, published on the
  loopback interface only (`MSSQL_PORT`, default `1433`).
- `mura` - built from `docker/Dockerfile`, published on `http://localhost/`
  by default (port `80`, controlled by `MURA_HTTP_PORT` - see below), in
  **development** mode (`MURA_MODE`), with `sites/`, `plugins/`, `themes/`,
  `modules/` and `config/` bind-mounted from the repo so edits show up
  without a rebuild (see [Making edits show up](#making-edits-show-up-inspecttemplate)).

First run: because `MURA_DATASOURCE` is set, Mura's unattended setup
(`core/appcfc/setup_check.cfm`) creates the database and runs the install
wizard automatically the first time it's asked - in either mode. By default
`MURA_WARMUP=true` triggers that itself: `docker/entrypoint.sh` waits for
nginx/Lucee to accept connections, then makes a `GET /` (compiles the
application and, since no site domain is recorded yet, is the request Mura's
setup uses to record the default site's domain) followed by
`GET /?appreload&applydbupdates` (applies pending updates) - both from
*inside* the container, against `http://localhost/` (`MURA_WARMUP_HOST`), in
the background shortly after boot, so `docker compose logs -f mura` will show
it happening without you needing to open a browser first. Once it settles,
log in to `/admin` with `MURA_ADMIN_USERNAME` / `MURA_ADMIN_PASSWORD`.

### `MURA_HTTP_PORT` and `MURA_PORT`

Mura stores a site's domain **without a port** (`contentServer.cfc`'s
`bindToDomain()` strips it before matching) and appends the `port` ini key -
`MURA_PORT` - when it builds an absolute URL (80 and 443 render as nothing).
The unattended setup records the default site's domain from the warm-up
request, i.e. `localhost`, so a browser at `http://localhost:<port>/` matches
the site as long as `MURA_PORT` is that same port. `docker-compose.yml`
therefore sets `MURA_PORT: ${MURA_HTTP_PORT:-80}` - change `MURA_HTTP_PORT`
in `.env` and both move together. A downstream compose file should do the
same.

In **production** mode Mura additionally 301-redirects any request whose host
is not one of the site's domains (`standardWrongDomainValidator`), and the
`Location` it builds carries `MURA_PORT`. Inside the container nothing listens
on that host:port, which is why the entrypoint's warm-up probes as
`localhost` (the recorded domain), follows at most 3 redirects, and treats a
redirect that does not resolve as "warm-up done, domain mismatch": you will
see two `mura-entrypoint: warm-up - ... still redirecting ...` lines naming
the target and the fix (set `MURA_WARMUP_HOST` to the site's domain, or add
the probe host as a domain alias in Site Settings). The warm-up work itself -
compiling the application, running setup, applying db updates - happens
before Mura redirects, so nothing is lost; the log line is there so the
mismatch is visible instead of a silent infinite loop.

### `MURA_MODE` on a clean database

`MURA_MODE=development` (the compose default) works from an empty database:
the unattended setup now runs regardless of mode, and if
`config/settings.ini.cfm` has no `[development]` section Mura clones
`[production]` into one on first start (the template and the setup only ever
write `[production]`), so `iniSections[mode]` always exists and the mode
inherits a full set of values. Switch to `production` to see the domain
redirect and cached plugin display objects a deployed site has.

### `MURA_ENCRYPTIONKEY` is required

Everything Mura encrypts - plugin settings, stored credentials - is keyed on
`encryptionkey`. Set it (`.env.example` carries a dev value; `openssl rand
-base64 24` makes a real one). If it is empty Mura generates a key **and
persists it** to `config/settings.ini.cfm` (with a warning in the log), so a
container that keeps its `config/` keeps its key; but a key that lives only in
a container's writable layer disappears with the container, and Mura fails
hard at start-up if it cannot persist one at all. A restored production
database needs the key it was written with - it is not in this repository.

This stack is dev-only: plain HTTP, `MURA_SECURECOOKIES=false` (see
[TLS and secure cookies](#tls-and-secure-cookies)), and passwords sourced
from a git-ignored `.env` (`.env.example` documents every key it needs; do
not reuse these values anywhere real).

## Logs

Lucee 6.2 in this image runs in **single** mode: its logs are written under
`/opt/lucee/server/lucee-server/context/logs/`, not `/opt/lucee/web/logs/`
(which earlier versions of this image symlinked, so nothing ever reached
`docker logs`). Now:

- `application.log` and `exception.log` in the server context are symlinks to
  `/dev/stdout`, so `writeLog(application=true)` / `cflog` / Lucee exceptions
  stream straight into `docker compose logs mura` (the old web-context links
  are kept too, in case a future Lucee tag brings back a web context);
- the `application` logger's level is raised from the stock image's `error`
  to `info` (`docker/lucee/cfconfig.d/10-inspect-template.json`) - at `error`
  a plain `writeLog(text=...)` (type *information*) was discarded before it
  reached the file at all, symlink or not;
- every other `*.log` in that directory - Lucee's `scheduler`, `mail`,
  `datasource`, `deploy` logs, and any file a plugin creates with
  `writeLog(file="MyPlugin")` - is tailed to stdout by the entrypoint,
  prefixed `lucee/<name>:` (new files are picked up within 10 s; existing
  content is not replayed). `MURA_LOG_TAIL=false` turns this off;
  `MURA_LOG_TAIL_EXCLUDE` (default `out,err`, Lucee's copies of
  System.out/err) lists names never tailed.

`docker/tests/smoke.sh` checks that a log line written by a request appears in
`docker compose logs`.

## Making edits show up (inspectTemplate)

Lucee compiles CFML to bytecode and only re-reads a source file when its
`inspectTemplate` setting says so. The stock Lucee image ships no value, and
its built-in default (`auto`) never picked up an edited bind-mounted template
in this image - only `supervisorctl restart lucee` did; Mura's `?appreload`
does not help because it reloads Mura's application, not Lucee's compiled
template pool.

The image sets `"inspectTemplate": "${LUCEE_INSPECT_TEMPLATE:once}"` in
Lucee's configuration (Lucee 6.2.8 resolves the placeholder from the
environment at start-up - verified), so:

| `LUCEE_INSPECT_TEMPLATE` | Behaviour |
| --- | --- |
| `once` (default) | check a template's timestamp once per request - a saved file is served on the next request |
| `always` | check on every include; slowest |
| `never` | never re-read; **use this in production** and deploy by rebuilding the image |
| `auto` | Lucee's own heuristic, i.e. what the stock image did |

Things that still need more than a save: `Application.cfc`, an
`eventHandler.cfc` or a theme's `config.xml.cfm` need
`curl "http://localhost/?appreload=$MURA_APPRELOADKEY"`; anything a theme
caches itself (e.g. with Lucee's `cacheGet`/`cachePut`) needs that cache
cleared; and anything baked into the image needs `docker compose up -d
--build`. `docker/tests/smoke.sh` edits a template inside the running
container and checks the next request serves the edit.

## Lucee configuration (`/opt/mura/cfconfig.d/`)

Lucee keeps its whole configuration in one JSON document,
`/opt/lucee/server/lucee-server/context/.CFConfig.json`; in single mode there
is no web context and no deploy folder to drop overrides into. The image
ships `mura-merge-cfconfig` (`docker/lucee/merge-cfconfig.py`), which merges
every `/opt/mura/cfconfig.d/*.json` fragment into that document - at build
time, and again by the entrypoint on every boot - with a per-key shallow
merge for objects (`caches`, `mappings`, `dataSources`...: entries are added
to what is already there) and a straight replace for scalars
(`inspectTemplate`). Fragments apply in file-name order; a `"//"` key is
ignored so a fragment can carry its own documentation. The base image's own
fragment is `docker/lucee/cfconfig.d/10-inspect-template.json`.

A downstream image adds Lucee settings by copying a fragment in:

```Dockerfile
COPY docker/lucee/site.json /opt/mura/cfconfig.d/50-site.json
```

The most common need: **a theme that calls Lucee's unnamed `cacheGet` /
`cachePut` / `cacheIdExists` needs a default Object cache**, or every page
dies with *"there is no default object cache defined"*. Production
configures that by hand in the Lucee admin (an EHCache connection named
`dfCache` set as the default Object cache); a container has to ship it. This
fragment defines two in-JVM RAM caches and makes them the defaults (the
names match what the Vintage Travel SalesForceSync plugin's own
`setupCaches()` creates, so the plugin converges on them instead of adding a
second pair):

```json
{
  "caches": {
    "sfObjectCache": {
      "class": "lucee.runtime.cache.ram.RamCache",
      "custom": { "timeToLiveSeconds": 0, "timeToIdleSeconds": 0 },
      "readOnly": "false", "storage": "false"
    },
    "sfQueryCache": {
      "class": "lucee.runtime.cache.ram.RamCache",
      "custom": { "timeToLiveSeconds": 0, "timeToIdleSeconds": 0 },
      "readOnly": "false", "storage": "false"
    }
  },
  "cache": { "defaultObject": "sfObjectCache", "defaultQuery": "sfQueryCache" }
}
```

RamCache is right for a dev container (empty on every boot, so it cannot hide
content or template changes, and no cluster to replicate to); the EHCache
extension is installed in the image, so a production fragment can use
`org.lucee.extension.cache.eh.EHCache` for a `dfCache` instead.

## Extending this image (a website project)

```Dockerfile
FROM vintagetravel/muracms:7.4.1

# The site overlay. Mura provides sites/<siteid>/index.cfm per site and most
# site repos gitignore it, so create it from the default site's copy.
COPY sites/vintagetravel /var/www/sites/vintagetravel
RUN cp /var/www/sites/default/index.cfm /var/www/sites/vintagetravel/index.cfm \
 && mkdir -p /var/www/sites/vintagetravel/cache /var/www/sites/vintagetravel/assets

# Plugins go straight into /var/www/plugins. This image declares no VOLUME,
# so they are ordinary image files and a rebuilt plugin is what the next
# container sees - no staging directory or entrypoint copy needed.
COPY plugins/SalesForceSync /var/www/plugins/SalesForceEntityManager

# Lucee settings the site needs (see "Lucee configuration" above).
COPY docker/lucee/site.json /opt/mura/cfconfig.d/50-site.json

# Mura plus a real theme does not fit the base image's 64m/512m heap.
ENV LUCEE_JAVA_OPTS="-Xms512m -Xmx2g"
```

This works because `lucee/lucee`'s own Dockerfile registers
`ONBUILD RUN rm -rf /var/www/*`, which only fires once - during *this*
image's build, right after its `FROM`, wiping the base image's placeholder
`/var/www` before `vintagetravel/muracms`'s own `COPY . /var/www` runs.
ONBUILD triggers are not inherited by a grandchild build, so a website
project's own `FROM vintagetravel/muracms:7.4.1` does not wipe `/var/www`
again - it lands on top of the full Mura CMS tree already baked into the
base image, and the `COPY`s above add to it rather than replacing it.

Give the site its own datasource via the `MURA_*` env vars below rather than
editing `config/` inside the image, set `MURA_ENCRYPTIONKEY`, keep
`MURA_PORT` equal to the published port, and if the site's compose file
bind-mounts the site directory remember the mount hides the image's copy of
`sites/<siteid>/index.cfm` - create it on the host too (or in an entrypoint
wrapper that `exec`s `/usr/local/bin/mura-entrypoint.sh "$@"`).

### Volumes (a decision)

The image declares **no** `VOLUME`. Earlier versions declared
`/var/www/plugins` and `/var/www/sites/default/assets`; a `VOLUME` is
inherited by every downstream image and cannot be undone, and it froze the
plugins a site image `COPY`ed into `/var/www/plugins` inside an anonymous
volume created by the first container - rebuilt plugins were never seen
again, and the site image had to stage them elsewhere and copy them over the
volume in its entrypoint. Persist what you want to persist explicitly:
`docker-compose.yml` here bind-mounts `sites/`, `plugins/`, `themes/`,
`modules/` and `config/`; a site stack typically uses named volumes for
`sites/<siteid>/cache`, `sites/<siteid>/assets` and `/var/www/config`.

## Environment variable reference

Mura reads its `settings.ini` keys from `MURA_<UPPERCASEKEY>` environment
variables (`core/appcfc/applicationSettings.cfm`); the ones below are the
ones this image and its compose stack rely on directly. Any other
`settings.ini` key can be set the same way.

| Variable | Purpose |
| --- | --- |
| `LUCEE_ADMIN_PASSWORD` | Lucee server/web administrator password (native Lucee env var, not Mura-specific) |
| `LUCEE_INSPECT_TEMPLATE` | `once` (default) / `always` / `never` / `auto` - whether Lucee re-reads edited templates; `never` in production. See [Making edits show up](#making-edits-show-up-inspecttemplate) |
| `LUCEE_JAVA_OPTS` | JVM options; the base image's default is `-Xms64m -Xmx512m`, which a real site outgrows |
| `MURA_DATASOURCE` | Datasource name; **setting this is what switches on Mura's unattended Docker setup** |
| `MURA_DATABASE`, `MURA_DBTYPE`, `MURA_DBHOST`, `MURA_DBPORT`, `MURA_DBUSERNAME`, `MURA_DBPASSWORD` | Datasource connection details (`MURA_DBTYPE=mssql` for this stack) |
| `MURA_DBCONNECTIONSTRING`, `MURA_DBCLASS` | Use a full JDBC connection string instead of host/port/database |
| `MURA_ENCRYPTIONKEY` | **Required.** Key for everything Mura encrypts. See [above](#mura_encryptionkey-is-required) |
| `MURA_MODE` | `development` (compose default) or `production`; both work on a clean database. See [above](#mura_mode-on-a-clean-database) |
| `MURA_PORT` | The `port` ini key: what Mura appends to absolute URLs. Must equal the host port the site is published on; compose sets it from `MURA_HTTP_PORT`. See [above](#mura_http_port-and-mura_port) |
| `MURA_ADMIN_USERNAME`, `MURA_ADMIN_PASSWORD`, `MURA_ADMINEMAIL` | Mura CMS admin account created by unattended setup |
| `MURA_APPRELOADKEY` | Shared secret required on `?appreload` requests |
| `MURA_HTTP_PORT` | This stack's own compose variable (`docker-compose.yml`), not read by Mura or the image: host port the container's nginx (`:80`) is published on. Default `80`; also fed to Mura as `MURA_PORT` |
| `LUCEE_ADMIN_PORT`, `MSSQL_PORT` | Compose-only: loopback host ports for the Lucee administrator (`8888`) and SQL Server (`1433`) |
| `MURA_ORMENABLED` | Set `false` unless a plugin needs Hibernate ORM |
| `MURA_ALLOWAUTOUPDATES` | Set `false` - updates belong in the image build, not a running container |
| `MURA_SECURECOOKIES` | Set `false` for plain-HTTP dev; leave at Mura's default (effectively `true`) once TLS terminates in front of the site |
| `MURA_SITEIDINURLS`, `MURA_INDEXFILEINURLS` | Mura URL formatting flags |
| `MURA_WARMUP` | This image's own entrypoint flag (`docker/entrypoint.sh`), not a Mura setting: `true` runs the GET `/` + GET `/?appreload&applydbupdates` warm-up in the background after boot |
| `MURA_WARMUP_HOST`, `MURA_WARMUP_TIMEOUT` | Tune the warm-up's target host (default `localhost` - the domain the unattended setup records; not `127.0.0.1`) and how long it waits for the server to answer before giving up (default 180s) |
| `MURA_LOG_TAIL`, `MURA_LOG_TAIL_EXCLUDE` | Entrypoint: tail Lucee's other `*.log` files (and plugin logs) to stdout (default `true`; exclude list default `out,err`). See [Logs](#logs) |
| `MURA_CFCONFIG_DIR` | Entrypoint: where the Lucee config fragments live (default `/opt/mura/cfconfig.d`) |
| `MURA_UMASK` | Entrypoint: umask for Lucee/nginx (default `0022`, so nginx can serve what Lucee writes) |

## TLS and secure cookies

This image and `docker-compose.yml` are HTTP-only - nginx listens on :80,
there's no certificate handling here. Mura's cookies default to `Secure`,
which browsers silently drop over plain HTTP, so local dev sets
`MURA_SECURECOOKIES=false`. In any environment with a real hostname, put a
TLS-terminating reverse proxy / load balancer in front of this container
(nginx already forwards `X-Forwarded-Proto`) and leave `MURA_SECURECOOKIES`
unset so cookies stay `Secure`.

## Smoke tests

`docker/tests/smoke.sh` (see its README) exercises the front end, admin
login and a content create/render/delete round trip over HTTP, and - when
run from the compose directory with `docker compose` available - the
container-level guarantees above: Lucee log lines reach `docker compose
logs`, an edited template is served on the next request, `MURA_MODE` is
honoured on first boot, the encryption key is the configured one (or was
persisted), Lucee 6 empty-string date/numeric feed criteria return 200, the
warm-up finished without looping, the image declares no `VOLUME`, and the
mssql healthcheck is healthy.

## Mura core changes for Lucee 6 (fork-level)

These live in this fork rather than in site repos because they touch `core/`
and `admin/`, which the GPL exception forbids a plugin/theme from altering.
Each site is commented with the Lucee 6 reason.

| Where | What |
| --- | --- |
| `core/appcfc/onApplicationStart_include.cfm` | unattended setup runs in Docker regardless of `MURA_MODE`; a missing `[mode]` ini section is cloned from `[production]`; a blank encryption key is read back from the ini, or generated **and persisted** (warning logged; hard error if it cannot be written) |
| `core/mura/IniFile.cfc` | `set(..., force=true)` writes even under Docker; `cloneSection()` |
| `core/mura/content/feed/feedGateway.cfc` | `bindsAsNull()`: an empty criteria on a date/numeric column binds as NULL instead of throwing *can't cast [] to date value* |
| `core/mura/plugin/pluginManager.cfc` | blank `loadPriority` defaults to 5; plugin zip extraction failures are reported on the Plugins tab instead of leaving a half-written plugin |
| `core/mura/Zip.cfc` | `Extract()` honours `overwriteFiles`, so re-uploading a plugin replaces its files |
| `core/mura/user/userstrikes.cfc`, `core/mura/content/dataCollection/dataCollectionManager.cfc`, `core/modules/v1/nav/calendarNav/navTools.cfc` | blank dates guarded before typed binds |
| `core/mura/configBean.cfc` | `dbUpdates/*.cfm` applied in an explicitly sorted order (Lucee 6.2 ignored a directory listing's sort) |
| `admin/core/controllers/csettings.cfc` | a failed plugin deploy lands on the Plugins tab where the error is shown |

## Notes / decisions

- **nginx vs Tuckey**: the `-nginx` variant was used instead of the plain
  Tomcat image + Tuckey `UrlRewriteFilter` (`core/docker/build/urlrewrite.xml`).
  Overriding its config turned out to be a single-file swap
  (`docker/nginx/default.conf`), and it buys static-file serving off the
  JVM plus the Lucee admin being blocked at the edge by default.
- **No image volumes**: see [Volumes (a decision)](#volumes-a-decision).
- **Config merge at build *and* boot**: the build-time merge means a plain
  `docker run` with a different entrypoint still gets the base fragment; the
  boot-time merge means a downstream image only has to `COPY` a fragment,
  and the merge is idempotent so re-running it is harmless.
- **core/docker excluded**: the legacy blueriver/Lucee 5 docker material
  under `core/docker` is left in the repo for reference but excluded from
  the build context (`.dockerignore`) - it's superseded by this folder.
- **core/tests excluded**: also excluded from the build context to keep the
  published base image smaller; add it back in `.dockerignore` if a project
  wants `box testbox run` to work inside the container itself.
