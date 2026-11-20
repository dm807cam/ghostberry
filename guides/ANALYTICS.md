# Web analytics (Umami)

Ghostberry can run [Umami](https://umami.is), an open-source web analytics
tool, next to your blog and connect the two for you. You get visitors, page
views, top posts, referrers, countries and devices on a dashboard of your own.

- **No cookies.** Umami doesn't store anything in the reader's browser and
  doesn't build profiles, so most blogs don't need a consent banner for it.
  (Check what applies where you live.)
- **The data stays on your Pi.** Nothing goes to Google or another company.
- **Backed up with everything else.** The nightly backup includes it, and
  `restore.sh` puts it back.

Ghost 6 also has its own web analytics, but it needs Ghost's hosted Tinybird
service, which Ghostberry doesn't set up. Umami takes its place.

## What it costs

- **Memory:** about 160 MB in use (Umami ~140 MB, its Postgres ~20 MB), capped
  at 384 MB and 160 MB. It fits on a 2 GB Pi next to Ghost, but leaves little
  room; a Pi with 4 GB or more is comfortable.
- **One more hostname** on your Cloudflare Tunnel, e.g. `stats.example.com`.
  Readers' browsers load Umami's script from it, and you open the dashboard
  there. Umami needs its own hostname, so it can't share your blog's.

## Turn it on

### 1. Add a route on your tunnel

In the [Cloudflare dashboard](https://dash.cloudflare.com/?to=/:account/tunnels):
**Networking → Tunnels → ghostberry → Routes → Add route → Published application**

- **Subdomain / Domain:** `stats` + `example.com`
- **Service URL:** `http://umami:3000`

Use a hostname **one level** below your domain: `stats.example.com`, not
`stats.blog.example.com`. Cloudflare's free certificate only covers one level
(`*.example.com`), so browsers would refuse the deeper one.

### 2. Run the installer with analytics on

New installs ask **"Set up analytics now?"**. On an existing install, re-run
the install command and say yes, or switch it on directly:

```bash
cd /opt/ghostberry
ANALYTICS=umami ./setup.sh && docker compose up -d
./scripts/analytics.sh connect
```

For an unattended install, add `ANALYTICS=umami` (and optionally
`ANALYTICS_URL=https://stats.example.com`) to the install command's variables.

**What `connect` does:**

1. Starts Umami, and replaces Umami's well-known default login (`admin` /
   `umami`) with a generated password stored in `.env`.
2. Creates a website in Umami for your blog's hostname (or finds the one it
   made before).
3. Adds Umami's script to **Ghost Admin → Settings → Code injection → Site
   header**, between `<!-- ghostberry:analytics -->` markers. Anything else
   you have there stays as it is. Ghost restarts once to load it.

It is safe to run again: every install and update runs it, and it only
changes something when something is missing.

### 3. Open the dashboard

```bash
./scripts/analytics.sh login
```

prints the address, the user (`admin`) and the password. In Umami you can
change the password (profile → Settings → Security), add more users, or share
a read-only dashboard link. If you change the admin password, put the new one
in `.env` as `UMAMI_ADMIN_PASSWORD`, so `connect` can still sign in.

## Daily use

```bash
./scripts/analytics.sh status       # containers, Ghost's script, public address
./scripts/analytics.sh login        # dashboard address and login
./scripts/analytics.sh connect      # re-add the script, e.g. after you deleted it
./scripts/analytics.sh secure       # only replace Umami's default login
./scripts/analytics.sh disconnect   # take the script out of Ghost
```

**Your own visits.** To leave them out, open your blog, open the browser's
developer console and run `localStorage.setItem('umami.disabled', 1)`. That
browser is then never counted.

**Previews don't count.** The script is set to count only your blog's own
hostname (`data-domains`), so visits to the site under another address are
ignored.

## Turn it off

```bash
ANALYTICS=none ./setup.sh && docker compose up -d --remove-orphans
./scripts/analytics.sh disconnect
```

This stops Umami and takes its script out of Ghost. The statistics are kept in
the `umami_db` Docker volume, so switching back on picks them up again. You
can also delete the tunnel route. To delete the statistics too:

```bash
docker volume ls | awk '/umami_db/ {print $2}' | xargs -r docker volume rm
```

## How it fits together

```
reader's browser ──https──► Cloudflare ──tunnel──► cloudflared ─┬─► ghost:2368   (blog.example.com)
                                                               └─► umami:3000   (stats.example.com)
                                                                      │
                                                     analytics network (no internet)
                                                                      │
                                                                  umami_db (Postgres)
```

- Umami and its database are the `analytics` Compose profile, like the
  built-in mail server is the `mail` profile. `setup.sh` keeps
  `COMPOSE_PROFILES` in step with `ANALYTICS`.
- Nothing is published on the Pi's own ports. The database sits on its own
  Docker network without internet access; only Umami can reach it.
- Readers' addresses come from Cloudflare's `CF-Connecting-IP` header. Umami
  uses them to count unique visitors and look up the country, and doesn't
  store them.
- Umami's own telemetry and update check are off. Ghostberry releases pin and
  update its version like every other image.
- Sign-in uses Umami's own accounts. For extra protection you can put the
  dashboard behind [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/applications/),
  but leave `/script.js` and `/api/send` open, or no visits are counted.

## Troubleshooting

**`status` says the public address is NOT reachable.** The tunnel route is
missing or points elsewhere. Check step 1, then
`curl -I https://stats.example.com/api/heartbeat`. It can take a minute after
you add the route.

**No visits show up.**

- Open your blog with the browser's developer tools on the Network tab. You
  should see `script.js` and a `send` request to your stats hostname. Ad and
  tracker blockers (uBlock Origin, Brave) often block Umami, so test in a
  browser without one. Some of your readers will block it too, so the numbers
  are a lower bound.
- `./scripts/analytics.sh status` should show that Ghost loads the script.
  If not, run `./scripts/analytics.sh connect`.

**`connect` can't log in to Umami.** The password in `.env` no longer
matches. Put the current admin password in `.env` as `UMAMI_ADMIN_PASSWORD`.

**Umami won't start.** `docker compose logs --tail=50 umami umami_db`. On a
2 GB Pi, check memory with `docker stats` and see
[Out of memory](TROUBLESHOOTING.md#out-of-memory).
