#!/usr/bin/env bash
# Maintainer tool: regenerate the update feed served by GitHub Pages.
#
#   tools/build-update-feed.sh
#
# Reads VERSION and the "## [x.y.z] - YYYY-MM-DD" headings in CHANGELOG.md
# and writes docs/update-check/:
#   latest.json      newest version, release date, links (scripts/check-update.sh)
#   v<old>.json      one per OLDER release: a Ghost Admin banner announcing the
#                    newest one (Ghost's update check fetches v<installed>.json)
# The current version gets no file, so Ghost's check finds a 404 and stays
# quiet. Run it in every release PR after bumping VERSION and CHANGELOG.md.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &> /dev/null && pwd)"
cd "${ROOT}"

REPO="${GHOSTBERRY_REPO:-dm807cam/ghostberry}"
OUT="docs/update-check"
INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash"
CHANGELOG_URL="https://github.com/${REPO}/blob/main/CHANGELOG.md"

die() { echo "❌ $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required."

current="$(tr -d '[:space:]' < VERSION)"
[[ "${current}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be x.y.z (got '${current}')."

# "## [1.2.0] - 2026-11-10" → "1.2.0 2026-11-10"
mapfile -t releases < <(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\] - ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1 \2/p' CHANGELOG.md)
(( ${#releases[@]} )) || die "No '## [x.y.z] - YYYY-MM-DD' headings in CHANGELOG.md."

released=""
for r in "${releases[@]}"; do
  [[ "${r%% *}" == "${current}" ]] && released="${r##* }"
done
[[ -n "${released}" ]] || die "CHANGELOG.md has no entry for VERSION ${current}."
newest="$(printf '%s\n' "${releases[@]%% *}" | sort -V | tail -n 1)"
[[ "${newest}" == "${current}" ]] || die "VERSION (${current}) isn't the newest CHANGELOG entry (${newest})."

mkdir -p "${OUT}"
rm -f "${OUT}"/v*.json

jq -n --arg v "${current}" --arg d "${released}" --arg c "${CHANGELOG_URL}" --arg i "${INSTALL_CMD}" \
  '{version: $v, released: $d, changelog: $c, install: $i}' > "${OUT}/latest.json"

count=0
for r in "${releases[@]}"; do
  old="${r%% *}"
  [[ "${old}" == "${current}" ]] && continue
  # Ghost: custom notification in the "all" group; the message id makes it
  # appear once per release and stay dismissed.
  jq -n --arg old "${old}" --arg new "${current}" --arg d "${released}" \
        --arg c "${CHANGELOG_URL}" --arg i "${INSTALL_CMD}" '
    {notifications: [{
      custom: 1,
      version: "all",
      created_at: ($d + "T00:00:00.000Z"),
      messages: [{
        id: ("ghostberry-" + $new),
        version: "all",
        type: "info",
        top: true,
        dismissible: true,
        content: ("<strong>Ghostberry " + $new + " is available</strong> (this site runs " + $old + "). "
                  + "<a href=\"" + $c + "\" target=\"_blank\" rel=\"noopener\">What&#8217;s new</a>. "
                  + "To update, run the install command again on your Raspberry Pi: <code>" + $i + "</code>")
      }]
    }]}' > "${OUT}/v${old}.json"
  count=$((count + 1))
done

echo "✅ ${OUT}/latest.json → ${current} (${released}); ${count} banner file(s) for older versions."
