# Container smoke tests

`smoke.sh` is a dependency-free (bash + curl) check that a running Mura CMS
container is actually serving a working site — not just answering on port 80.
Mura has no meaningful automated test coverage, so this is the fastest way to
tell whether an image build, a base-image bump or an nginx/Lucee config change
has broken something end to end.

## What it checks

| Group | Checks |
| --- | --- |
| Front end and routing | `GET /` returns 200 with a `<title>`; an unknown path reaches **Mura's** 404 (proving nginx's `try_files` front-controller rewrite, not nginx's own 404); a content URL beginning with `lucee` is **not** swallowed by the Lucee-admin block; `/lucee/admin.cfm` **is** still blocked; a static asset under `/admin/assets/` is served by nginx; the JSON API returns JSON |
| Admin login | the login form loads and its CSRF tokens are scraped; the login POST round-trips against a cookie jar; `cArch.list` then returns *Site Content* with a Logout link; the same URL **without** cookies is refused (control, so a broken auth check can't produce a false pass). It also prints the `Set-Cookie` flags and warns when `Secure` cookies are issued over plain HTTP |
| Content lifecycle | creates a Page under the home node by re-posting the real admin form, confirms it renders on the front end with its body content, then deletes it via the site-manager tree's delete link and confirms it 404s |
| Container / Lucee 6 regressions (needs `docker compose`) | writes a scratch template into `sites/<site>/remote/` inside the container and reads it back: `configBean.getMode()` equals the container's `MURA_MODE` and the ini has that mode's section; the encryption key in use is `MURA_ENCRYPTIONKEY` (or, if that is unset, was generated and persisted to the ini); feed queries with an empty criteria on a date column, a numeric column and a Date extended attribute (created on the fly, plus a node that sets it) return 200; editing the template is served on the next request (inspectTemplate); a `writeLog(application=true)` line appears in `docker compose logs`; the server-context log symlinks exist; the entrypoint warm-up completed without giving up (a domain-mismatch redirect is reported as a NOTE); the image declares no `VOLUME`; the mssql healthcheck is healthy. Skipped with `SKIP_DOCKER=1` or when `docker compose ps <service>` finds nothing from the current directory |

Each check prints `PASS` or `FAIL`; the run ends with `passed=N failed=N` and
exits non-zero if anything failed, so it drops straight into CI.

The lifecycle test cleans up after itself. If the delete step cannot find the
node it says so and names the leftover page rather than failing silently.

## Running it

Against the local compose stack (`docker-compose.yml` publishes the container
on the host port it maps, and Mura redirects to the site's configured domain —
for the stock `default` site that is `localhost`):

```sh
docker compose up -d
BASE_URL=http://localhost \
ADMIN_USER=admin \
ADMIN_PASS="$(grep '^MURA_ADMIN_PASSWORD=' .env | cut -d= -f2-)" \
  bash docker/tests/smoke.sh
```

Positional arguments work too:

```sh
bash docker/tests/smoke.sh http://localhost admin 'your-password'
```

Against any other environment:

```sh
BASE_URL=https://staging.example.com ADMIN_USER=deploy ADMIN_PASS=... \
  bash docker/tests/smoke.sh
```

`ADMIN_PASS` is required; the script exits 2 without it rather than reporting
a misleading login failure. Nothing is written to the repo and no credentials
are echoed — only the first 8 characters of the CSRF token are printed.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `BASE_URL` | `http://localhost` | Site root; a trailing slash is trimmed |
| `ADMIN_USER` | `admin` | Mura admin username |
| `ADMIN_PASS` | *(required)* | Mura admin password |
| `MURA_SITE_ID` | `default` | Site id used for admin and API URLs |
| `MURA_HOME_ID` | `00000000000000000000000000000000001` | Content id of the home node the test page is created under |
| `CURL_TIMEOUT` | `120` | Per-request timeout in seconds |
| `COMPOSE_SERVICE` | `mura` | Compose service the container checks run `docker compose exec`/`logs` against; run the script from the compose project directory |
| `SKIP_DOCKER` | unset | `1` skips the container checks (e.g. when running the script from inside the container) |
| `MURA_SMOKE_SITE_DIR` | `/var/www/sites/<MURA_SITE_ID>` | Site directory inside the container the scratch template is written under (`remote/` is appended) |

## Notes

- **Use the site's own domain.** Mura 301-redirects any request whose host
  does not match the site's configured domain, so hitting the container on
  `http://127.0.0.1:8080` when the site's domain is `localhost` produces a
  redirect to `http://localhost/` that goes nowhere. Either publish the
  container on port 80 or set the site's domain to match the URL you test.
- **The page slug is derived, not looked up.** The lifecycle test assumes
  Mura's default filename rule (lower-case the title, hyphenate spaces). A site
  with a custom `onContentSave` that rewrites filenames will fail that check;
  that is a deliberate signal, not a bug in the script.
- **Plain-HTTP cookie warning.** With `MURA_SECURECOOKIES=false` the Lucee
  session cookie loses its `Secure` flag, but Mura's own cookies
  (`MXP_TRACKINGID`, `cfid`, `cftoken`, …) are still written `Secure;
  SameSite=None` by `core/mura/utility.cfc`. `curl` treats `localhost` as a
  secure context so the test still passes there; a browser on any other
  plain-HTTP origin will drop those cookies. The script prints a `NOTE` when it
  sees this.
- The script needs only `bash`, `curl`, `grep`, `sed` and `date` — no python,
  no jq.
