# Email

Ghost sends two kinds of email:

| Kind | Examples | How Ghost sends it | Ghostberry covers it? |
|---|---|---|---|
| **Transactional** | staff invites, password resets, member sign-up / sign-in links, comment notifications | SMTP (`mail__*` config) | ✅ built-in server or any SMTP provider |
| **Bulk / newsletters** | "email this post to subscribers" | **Mailgun API only** | ❌ needs a Mailgun account (Ghost Admin → Settings → Mailgun) |

Without transactional email Ghost still serves the site, but you can't
invite staff, reset a password, or let members sign in. So Ghostberry turns
it on at install time.

## The three modes

`setup.sh` (and the one-shot installer) asks which one you want. The
choice is stored as `MAIL_MODE` in `.env`.

| `MAIL_MODE` | What runs | Use it when |
|---|---|---|
| `builtin` *(default)* | `ghost_mail` container: [maddy](https://maddy.email), a send-only relay that DKIM-signs everything | You want email to work right away without signing up anywhere |
| `smtp` | nothing extra; Ghost talks to your provider directly | You already have Postmark / Brevo / SES / Fastmail / Gmail-app-password credentials |
| `none` | nothing | You'll set it up later |

Switch any time:

```bash
cd /opt/ghostberry
MAIL_MODE=builtin ./setup.sh          # or smtp / none
docker compose up -d --remove-orphans
```

## How the built-in server works

```
Ghost ──SMTP:2525──▶ ghost_mail (maddy) ──DKIM sign──▶ queue ──▶ recipient MX :25
                       private "mail"                         └──▶ or your relay :587
                       network only
```

- **Send-only.** No ports are published and the Cloudflare Tunnel doesn't
  carry SMTP, so nothing on the internet can reach it. It never receives mail.
- **Only Ghost can use it.** It listens on a private Docker network that only
  the Ghost container joins. It also rejects any sender outside
  `MAIL_DOMAIN`, so even a compromised container can't spoof other domains.
- **DKIM out of the box.** On first start it generates a 2048-bit key in the
  `mail_data` volume and signs every message. `backup.sh` saves the key, so
  restoring doesn't mean republishing DNS.
- **Queue and retry.** If a receiving server is down or greylists you, the
  message is retried with backoff (up to 12 attempts) instead of being lost.
  Ghost on its own gives up after one try.
- **Small.** About 6 MB RAM idle (capped at 64 MB), and a 31 MB image. It
  runs with a read-only root filesystem, every Linux capability dropped, and
  `no-new-privileges`.

Two delivery paths, chosen by whether `MAIL_RELAY_HOST` is set:

1. **Direct** (`mail/maddy.conf`): looks up each recipient's MX and delivers
   on port 25, using TLS where offered (MTA-STS and DANE are honoured).
2. **Relay / smarthost** (`mail/maddy-relay.conf`): signs with *your* DKIM
   key, then hands the message to a provider over STARTTLS with a username and
   password.

### Should I use direct delivery or a relay?

Be realistic about a Pi on a home connection:

- **Many ISPs block outbound port 25.** `setup.sh` checks this for you and
  offers the relay option if it's blocked.
- **Home IP ranges are on blocklists** (e.g. Spamhaus PBL), and Gmail and
  Outlook weigh IP reputation heavily. DKIM-signed mail from a home IP *can*
  be delivered, but it often lands in spam.
- **SPF needs a stable IP.** Your blog's A record points at Cloudflare, not
  your house, so SPF has to list your home IP explicitly, and that breaks
  when it changes. DKIM alone still passes DMARC, but it's one fewer signal.

**Use direct delivery** if you have a static IP with a proper reverse DNS
(PTR) record, or for testing. **Use a relay** for anything you rely on. Free
tiers are plenty for transactional mail:

| Provider | Free tier (check current terms) | Relay host |
|---|---|---|
| Brevo | 300/day | `smtp-relay.brevo.com:587` |
| SMTP2GO | 1,000/month | `mail.smtp2go.com:587` |
| Resend | 3,000/month | `smtp.resend.com:587` |
| Mailjet | 200/day | `in-v3.mailjet.com:587` |
| Amazon SES | pay-as-you-go, very cheap | `email-smtp.<region>.amazonaws.com:587` |

Set it up:

```bash
cd /opt/ghostberry
MAIL_RELAY_HOST=smtp-relay.brevo.com MAIL_RELAY_USER=you@example.com \
MAIL_RELAY_PASSWORD=xkeysib-... ./setup.sh
docker compose up -d
```

The relay only supports STARTTLS (587 / 2525), not implicit TLS on 465, and
the username/password must not contain whitespace (API keys never do).

## DNS records

Once the stack is running:

```bash
./scripts/mail.sh dns
```

This prints the exact records for your domain and checks whether each one is
already live:

| Record | Name | Value |
|---|---|---|
| DKIM | `ghost._domainkey.<domain>` | `v=DKIM1; k=rsa; p=…` (generated for you) |
| SPF | `<domain>` | direct: `v=spf1 ip4:<your IP> ~all` · relay: your provider's `include:` |
| DMARC | `_dmarc.<domain>` | `v=DMARC1; p=none; adkim=r; aspf=r` |

In Cloudflare these are ordinary **TXT** records (the orange-cloud proxy
toggle doesn't apply to TXT). A name may have only **one** `v=spf1` record,
so merge with any existing one. Once a test message shows `dkim=pass`, tighten
DMARC to `p=quarantine`.

When you use a relay, also complete that provider's domain verification.
Most ask for their own DKIM/SPF records as well, which is fine: a message can
carry more than one DKIM signature.

## Testing

```bash
./scripts/mail.sh test you@gmail.com   # sends through Ghost's own mail settings
./scripts/mail.sh status               # container health, queue size, recent log
```

`test` runs inside the Ghost container with Ghost's own nodemailer and
`mail__*` settings, so if it works, Ghost can send too. In Gmail, open the
message → ⋮ → **Show original** and check `DKIM: PASS` and `DMARC: PASS`.
[mail-tester.com](https://www.mail-tester.com) gives a more detailed score.

## Troubleshooting

| Symptom (`./scripts/mail.sh status` / `docker compose logs mail`) | Cause → fix |
|---|---|
| `dial tcp …:25: connect: connection refused` / `i/o timeout`, "will retry" | ISP blocks port 25 → configure a relay |
| `553 5.7.1 Sender domain not allowed` | Ghost's sender isn't `@MAIL_DOMAIN`. Check `MAIL_FROM`, and the sender addresses in Ghost Admin → Settings → Email / Portal |
| `535 … authentication failed` (relay) | Wrong `MAIL_RELAY_USER` / `MAIL_RELAY_PASSWORD`; many providers want an API key, not your login password |
| Gmail `550-5.7.25 … PTR record` / `421 … unsolicited` | Home IP reputation/PTR → use a relay |
| Mail arrives in spam | Publish SPF + DMARC, use a relay, and send from your blog's real domain |
| Ghost logs `Failed to send email` with `ECONNREFUSED mail:2525` | Mail container not running → `docker compose ps`; check `COMPOSE_PROFILES=mail` in `.env` |

## Why maddy? (research notes, November 2026)

Requirements: runs next to Ghost + MySQL on a 2 GB Pi, arm64 image, DKIM
signing with automatic key generation, can relay through a smarthost, no
inbound ports, actively maintained, configurable from `.env`.

| Option | Type | Idle RAM | Image | Notes |
|---|---|---|---|---|
| **maddy 0.9.7** (chosen) | Go single binary; SMTP, DKIM, queue, MTA-STS/DANE | **~6 MB** (measured) | 31 MB compressed | Generates DKIM keys itself; one small config file; arm64 image on GHCR; active releases |
| Postfix via `bokysan/docker-postfix` 5.2 | Postfix + rspamd for DKIM | ~296 MB (measured) | 92–135 MB compressed | Battle-tested and very configurable, but rspamd costs about 50× the RAM |
| Stalwart 1.0 | Rust all-in-one (SMTP/IMAP/JMAP, web admin) | ~100–200 MB | larger | Modern and excellent, but a full mailbox server: far more than Ghost needs |
| mox | Go all-in-one mail server | ~512 MB recommended | — | Secure-by-default and modern, but wants to own the domain's mail and inbound :25/:443; the author doesn't recommend Docker |
| docker-mailserver / Mailcow | Postfix + Dovecot + filtering stacks | 1–2 GB+ | large | Built for hosting mailboxes, far too heavy here |
| Ghost's own "direct" transport | nodemailer, no relay | 0 | — | No DKIM, no queue or retries; mail is usually rejected |

maddy was the only option that does exactly what Ghost needs (sign, queue,
deliver or relay) and nothing more, in a footprint that won't matter on a Pi.

### What about newsletters?

As of November 2026 Ghost still sends bulk newsletters **only** through the
Mailgun API. That isn't SMTP, so neither the built-in server nor an SMTP
provider can do it. Options:

- Connect Mailgun in Ghost Admin → Settings → Mailgun (pay-as-you-go).
- Use a proxy that speaks the Mailgun API and forwards to another provider
  (e.g. Amazon SES). These are third-party projects, and Ghostberry doesn't
  bundle one.

Ghost has discussed pluggable bulk providers on its forum, so check the Ghost
changelog before you pick.
