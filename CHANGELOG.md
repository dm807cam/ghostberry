# Changelog

Every Ghostberry release is listed here. Installs show a banner in Ghost Admin
and email the blog's admins when a newer release is out; to update, re-run the
install command:

```bash
curl -fsSL https://raw.githubusercontent.com/dm807cam/ghostberry/main/install.sh | sudo bash
```

<!--
Releasing (maintainers): bump VERSION, add a "## [x.y.z] - YYYY-MM-DD" entry
at the top, run tools/build-update-feed.sh, and commit the regenerated
docs/update-check/ files in the same PR. Patch = version/security bumps and
fixes, minor = new features, major = changes that need manual steps.
-->

## [1.0.1] - 2026-11-16

Security update. Re-run the install command to get it; your blog is backed up
first, as always.

If you set `GHOST_IMAGE` or `CLOUDFLARED_IMAGE` in `.env` yourself, those lines
win over this release and are not updated: delete them, then re-run the install
command. The installer now warns when such a line is older than the release's
version.

### Security
- **Ghost 6.75.0 → 6.77.0.** Fixes eleven Ghost security advisories published
  on 13 November 2026, including a high-severity bypass of Ghost's sign-in
  brute-force protection
  ([GHSA-fxxr-gqx3-p253](https://github.com/TryGhost/Ghost/security/advisories/GHSA-fxxr-gqx3-p253)),
  members-only content exposed through the Content API
  ([GHSA-994c-84qf-j7q9](https://github.com/TryGhost/Ghost/security/advisories/GHSA-994c-84qf-j7q9)),
  deleted or hidden comments readable through the comments API
  ([GHSA-9c5c-w94h-xp32](https://github.com/TryGhost/Ghost/security/advisories/GHSA-9c5c-w94h-xp32)),
  revenue numbers visible to all staff
  ([GHSA-vh3j-4gg7-7vjw](https://github.com/TryGhost/Ghost/security/advisories/GHSA-vh3j-4gg7-7vjw)),
  and brute-forcing of a private site's access code
  ([GHSA-q58f-57cg-xfw5](https://github.com/TryGhost/Ghost/security/advisories/GHSA-q58f-57cg-xfw5)).
  If your site is private, visitors enter the access code once more after
  the update. Full list:
  [Ghost security advisories](https://github.com/TryGhost/Ghost/security/advisories).
  Release notes: [6.76.0](https://github.com/TryGhost/Ghost/releases/tag/v6.76.0),
  [6.77.0](https://github.com/TryGhost/Ghost/releases/tag/v6.77.0).
- **cloudflared 2026.10.7 → 2026.11.0.** Fixes a way to slip past Cloudflare
  Access with crafted URL parameters, and moves to Go 1.27.4
  ([release notes](https://github.com/cloudflare/cloudflared/blob/2026.11.0/RELEASE_NOTES)).

## [1.0.0] - 2026-11-10

First versioned release.

### Added
- **Update notices:** a banner in Ghost Admin plus one email to the blog's
  Owner and Administrators when a newer Ghostberry release is out
  (`UPDATE_NOTICES=off` to disable). Re-running the install command is now
  the one way to update; `scripts/update.sh` is gone.
- **Exact image versions** pinned in `docker-compose.yml`: Ghost 6.75.0,
  MySQL 8.0.46, cloudflared 2026.10.7, maddy 0.9.7, rclone 1.76.0. Each
  release moves every install to the same tested set.
- **Off-site backups to Cloudflare R2** (`OFFSITE=r2`, `scripts/offsite.sh`).
- **Built-in send-only mail server** (maddy) with DKIM, so Ghost's sign-in
  links and password resets work from the first boot (`scripts/mail.sh`).
- Redesigned website.

### Changed
- Ghost 5 → Ghost 6. Installs on the old `ghost:5-alpine` default move
  automatically (after a backup).
- `.env` no longer stores image versions unless you override one on purpose,
  so releases can actually update them.

### Fixed
- `backup.sh` always exited with an error when encryption was on, which made
  updates abort.
- `restore.sh` failed halfway (Ghost's sticky content folder).
- Disaster recovery didn't keep the old backup encryption key.
- Several installer and `setup.sh` re-run bugs (SMTP port prompt, settings
  passed as environment variables being ignored, changes not applied).
