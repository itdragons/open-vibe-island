#!/bin/zsh
# Pulls upstream (Octane0411/open-vibe-island) changes into a disposable
# review branch on top of wg. Never merges into wg directly — you review
# the sync branch and merge it into wg yourself once it looks right.
#
# Requires: gh CLI, authenticated, with access to this fork.
#
# Known conflict-prone files (WG branding/signal-light changes vs. upstream):
#   - Assets/Brand/*                          (icon assets touched on both sides)
#   - scripts/package-app.sh                  (app_name / bundle_identifier defaults)
#   - the Info.plist heredoc in scripts/package-app.sh
#     (NSBluetoothAlwaysUsageDescription, SUFeedURL parameterization)
#
# Usage: zsh scripts/sync-upstream.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is dirty. Commit or stash changes first." >&2
    exit 1
fi

sync_branch="sync/wg-$(date +%Y%m%d)"

if git show-ref --verify --quiet "refs/heads/$sync_branch"; then
    echo "ERROR: branch $sync_branch already exists. Delete it or wait until tomorrow." >&2
    exit 1
fi

echo "--- Step 1: syncing origin/main with upstream ---"
if command -v gh >/dev/null 2>&1; then
    gh repo sync --branch main
else
    echo "gh CLI not found. Open the repo on github.com and click 'Sync fork' for main," >&2
    echo "then re-run this script." >&2
    exit 1
fi

echo "--- Step 2: fast-forwarding local main ---"
git fetch origin main
git checkout main
git merge --ff-only origin/main

echo "--- Step 3: creating $sync_branch from wg and merging main into it ---"
git checkout wg
git pull --ff-only origin wg
git checkout -b "$sync_branch"

if git merge main; then
    echo "Merge completed with no conflicts."
else
    cat >&2 <<EOF

Merge stopped with conflicts. Resolve them, then:
  git add <resolved files>
  git commit

Known conflict-prone files to double-check even if git didn't flag them:
  - Assets/Brand/*
  - scripts/package-app.sh
  - the Info.plist heredoc inside scripts/package-app.sh

After committing the merge, re-run the build check yourself:
  swift build
EOF
    exit 1
fi

echo "--- Step 4: build check ---"
swift build

cat <<EOF

Sync branch '$sync_branch' is merged and builds cleanly.
Review it, then merge into wg yourself:
  git checkout wg
  git merge $sync_branch
  git push origin wg
  git branch -d $sync_branch
EOF
