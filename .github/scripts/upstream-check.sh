#!/usr/bin/env bash
# Is there anything newer upstream than what this repo pins, for the dependencies
# Dependabot can't watch (.github/dependabot.yml covers the rest)?
#   - Colloid-kde: new commits on main (it has no releases)
#   - Colloid icons (for the cursors) and GTK theme: a newer release tag
#   - Panel Colorizer: a newer release tag
#   - Ventoy: a newer release, with its tarball's SHA-256 checked against the one
#     Ventoy publishes
# It never changes a pin: it reports, with the lines to paste.
#
#   .github/scripts/upstream-check.sh            print what's newer (safe anywhere)
#   .github/scripts/upstream-check.sh --issues   open or update one issue per finding
#                                                (needs gh and GH_TOKEN; the weekly
#                                                upstream-check workflow runs this)
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
theme_defaults=$root/config/ansible/roles/theme/defaults/main.yml
widgets_defaults=$root/config/ansible/roles/plasma_widgets/defaults/main.yml
build_usb=$root/installer/build-usb.sh
issues=0
[[ ${1:-} == --issues ]] && issues=1

var() { sed -n "s/^$1: *\([^ #]*\).*/\1/p" "${2:-$theme_defaults}"; }
newer_version() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$2" ]]; }

# report TITLE BODY: print it, and with --issues open an issue or update the open one
# with the same title (so a weekly run never piles up duplicates).
report() {
  local title=$1 body=$2 num
  printf '\n== %s\n%s\n' "$title" "$body"
  (( issues )) || return 0
  body+=$'\n\n---\n_Opened by `.github/scripts/upstream-check.sh` (the weekly upstream-check workflow)._'
  num=$(gh api "repos/$GITHUB_REPOSITORY/issues?state=open&per_page=100" \
          --jq ".[] | select(.pull_request == null and .title == \"$title\") | .number" | head -n1)
  if [[ -n $num ]]; then
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/$num" -f body="$body" --jq '"Updated \(.html_url)"'
  else
    gh api "repos/$GITHUB_REPOSITORY/issues" -f title="$title" -f body="$body" --jq '"Opened \(.html_url)"'
  fi
}

# ---- Colloid-kde: compare the pin with the head of main
kde_repo=$(var theme_colloid_kde_repo) kde_pin=$(var theme_colloid_kde_version)
kde_head=$(git ls-remote "$kde_repo" refs/heads/main | cut -f1)
if [[ -n $kde_head && $kde_head != "$kde_pin" ]]; then
  report "Upstream: Colloid-kde has new commits" "Colloid-kde has no releases; its \`main\` has moved on from the pinned commit.

- Changes: $kde_repo/compare/$kde_pin...$kde_head
- To upgrade, set in \`config/ansible/roles/theme/defaults/main.yml\`:
  \`theme_colloid_kde_version: $kde_head\`
- Then run the VM test (\`vm/test-vm.sh\`, or the VM workflow on the branch) before merging."
fi

# ---- Colloid icons and GTK theme: the newest release tag (dated, so they sort)
for part in icons gtk; do
  repo=$(var "theme_colloid_${part}_repo") pin=$(var "theme_colloid_${part}_version")
  tags=$(git ls-remote --tags "$repo")
  latest=$(sed -n 's|.*refs/tags/\([^^]*\)$|\1|p' <<<"$tags" | sort -V | tail -n1)
  [[ -n $latest ]] || continue
  # An annotated tag's commit is on its peeled ^{} line.
  commit=$(awk -v t="refs/tags/$latest^{}" '$2 == t {print $1}' <<<"$tags")
  [[ -n $commit ]] || commit=$(awk -v t="refs/tags/$latest" '$2 == t {print $1}' <<<"$tags")
  if [[ $commit != "$pin" ]]; then
    report "Upstream: Colloid $part has a new release" "A newer release tag than the pinned commit: **$latest**.

- Release: $repo/releases/tag/$latest (changes: $repo/compare/$pin...$commit)
- To upgrade, set in \`config/ansible/roles/theme/defaults/main.yml\`:
  \`theme_colloid_${part}_version: $commit   # tag $latest\`
- Then run the VM test before merging."
  fi
done

# ---- Panel Colorizer: the newest release tag (vX.Y.Z)
repo=$(var plasma_widgets_colorizer_repo "$widgets_defaults") pin=$(var plasma_widgets_colorizer_version "$widgets_defaults")
tags=$(git ls-remote --tags "$repo")
latest=$(sed -n 's|.*refs/tags/\(v[0-9][^^]*\)$|\1|p' <<<"$tags" | sort -V | tail -n1)
if [[ -n $latest ]]; then
  commit=$(awk -v t="refs/tags/$latest^{}" '$2 == t {print $1}' <<<"$tags")
  [[ -n $commit ]] || commit=$(awk -v t="refs/tags/$latest" '$2 == t {print $1}' <<<"$tags")
  if [[ $commit != "$pin" ]]; then
    report "Upstream: Panel Colorizer has a new release" "A newer release tag than the pinned commit: **$latest**.

- Release: $repo/releases/tag/$latest (changes: $repo/compare/$pin...$commit)
- To upgrade, set in \`config/ansible/roles/plasma_widgets/defaults/main.yml\`:
  \`plasma_widgets_colorizer_version: $commit   # tag $latest\`
- Its settings in \`config/home/modules/plasma.nix\` are merged over its defaults; check the changelog for renamed ones.
- Then run the VM test before merging."
  fi
fi

# ---- Ventoy: the latest release, with its SHA-256 checked
cur=$(sed -n 's/^VENTOY_VERSION="\([^"]*\)".*/\1/p' "$build_usb")
if command -v gh >/dev/null && [[ -n ${GH_TOKEN:-} ]]; then
  release=$(gh api repos/ventoy/Ventoy/releases/latest)
else
  release=$(curl -fsSL https://api.github.com/repos/ventoy/Ventoy/releases/latest)
fi
tag=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"$release")
new=${tag#v}
if newer_version "$cur" "$new"; then
  tarball="ventoy-${new}-linux.tar.gz"
  base="https://github.com/ventoy/Ventoy/releases/download/${tag}"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
  sha=$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)
  # Ventoy publishes the hashes as a release asset (sha256.txt) and in the notes.
  published=$( { curl -fsSL "$base/sha256.txt" 2>/dev/null || true
                 python3 -c 'import json,sys; print(json.load(sys.stdin).get("body") or "")' <<<"$release"; } \
               | grep -F "$tarball" | grep -oE '[0-9a-f]{64}' | head -n1 || true)
  if [[ $published == "$sha" ]]; then
    check="✔ matches the SHA-256 Ventoy publishes for \`$tarball\`."
  elif [[ -n $published ]]; then
    check="✖ **does not match** the SHA-256 Ventoy publishes ($published). Don't upgrade until that's explained."
  else
    check="? Ventoy's published SHA-256 for \`$tarball\` wasn't found; compare it by hand with the release notes."
  fi
  report "Upstream: Ventoy $new is out" "Ventoy $new is out (pinned: $cur): https://github.com/ventoy/Ventoy/releases/tag/$tag

The downloaded tarball's SHA-256 is \`$sha\`: $check

To upgrade, set in \`installer/build-usb.sh\`:
\`\`\`bash
VENTOY_VERSION=\"$new\"
VENTOY_SHA256=\"$sha\"
\`\`\`
Then rebuild a stick with \`installer/build-usb.sh\` and try it (\`vm/test-vm.sh install --stick /dev/sdX\`)."
fi

echo
echo "Done."
