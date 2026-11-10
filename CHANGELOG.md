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
