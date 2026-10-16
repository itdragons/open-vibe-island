# WG 发布流水线与上游同步 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the `wg` fork its own release pipeline that builds and publishes "WG Open Island" installers (unsigned, ad-hoc-signed, with a working in-app "Check for Updates"), plus a repeatable local script for pulling upstream's new commits into `wg` without clobbering the signal-light/branding work.

**Architecture:** A new GitHub Actions workflow (`.github/workflows/wg-release.yml`) builds via the existing `scripts/package-app.sh`, parameterized with WG-specific env vars (bundle id, Sparkle feed URL — bundle id and public key vars already exist in the script; only the feed URL needs to become parameterized). A second, independent Sparkle appcast (`appcast-wg.xml` + `scripts/update-appcast-wg.sh`) and a dedicated EdDSA keypair let WG builds check for updates against the fork's own releases instead of upstream's. A standalone `scripts/sync-upstream.sh` automates the git mechanics of pulling upstream into a disposable review branch, leaving the actual merge into `wg` to a manual step.

**Tech Stack:** zsh scripts, GitHub Actions (macOS runner), Sparkle's bundled `sign_update`/`generate_keys` CLIs (from `.build/artifacts/sparkle/Sparkle/bin/`), `gh` CLI.

## Global Constraints

- Do not modify `.github/workflows/release.yml` or `.github/workflows/ci.yml` — those stay upstream's, unmodified, so they remain diffable/mergeable during upstream syncs.
- Do not implement Apple code signing/notarization or upstream-sync automation (scheduled workflow) — both explicitly out of scope per the approved spec.
- New WG-specific files must not share a filename with any upstream file that upstream continues to modify (avoids merge conflicts on every future sync) — hence `appcast-wg.xml` / `update-appcast-wg.sh`, not edits to `appcast.xml` / `update-appcast.sh`.
- Bundle id for WG builds: `app.openisland.wg`.
- Release tag prefix for this fork: `wg-v*` (e.g. `wg-v1.2.1`), never bare `v*` (that's upstream's).
- Sparkle EdDSA private key lives only in GitHub Secrets (`WG_SPARKLE_EDDSA_KEY`), never in the repo.

---

### Task 1: Parameterize the Sparkle feed URL in `package-app.sh`

**Files:**
- Modify: `scripts/package-app.sh:19-20` (add variable), `scripts/package-app.sh:115-116` (use variable — this line shifts down by one after Step 1's insertion, to 116-117; match by content, not line number)

**Interfaces:**
- Produces: new env var `OPEN_ISLAND_SPARKLE_FEED_URL` (optional, defaults to upstream's feed) consumed by later tasks' workflow YAML.
- Note: `OPEN_ISLAND_BUNDLE_ID` (line 12) and `OPEN_ISLAND_EDDSA_PUBLIC_KEY` (line 118) are **already** parameterized — no change needed for those, just set them when invoking the script in Task 4.

- [ ] **Step 1: Add the `sparkle_feed_url` variable**

In `scripts/package-app.sh`, right after line 20 (`notary_profile="${OPEN_ISLAND_NOTARY_PROFILE:-}"`), add:

```bash
sparkle_feed_url="${OPEN_ISLAND_SPARKLE_FEED_URL:-https://raw.githubusercontent.com/Octane0411/open-vibe-island/main/appcast.xml}"
```

- [ ] **Step 2: Use the variable in the Info.plist heredoc**

Change (currently at line 116):

```xml
    <string>https://raw.githubusercontent.com/Octane0411/open-vibe-island/main/appcast.xml</string>
```

to:

```xml
    <string>$sparkle_feed_url</string>
```

(This line is inside a `cat > ... <<EOF` heredoc that already does `$variable` interpolation elsewhere on the same lines, e.g. `$app_name`, `$bundle_identifier` — no quoting changes needed.)

- [ ] **Step 3: Syntax-check the script**

Run: `bash -n scripts/package-app.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Verify default behavior is unchanged**

Run: `grep -A1 "sparkle_feed_url=" scripts/package-app.sh`
Expected output includes the upstream URL as the default:
```
sparkle_feed_url="${OPEN_ISLAND_SPARKLE_FEED_URL:-https://raw.githubusercontent.com/Octane0411/open-vibe-island/main/appcast.xml}"
```

Run: `grep -n '<string>\$sparkle_feed_url</string>' scripts/package-app.sh`
Expected: exactly one match (the line shifts down by one from its original 116 once Step 1's new variable line is inserted above it — match on content, not line number).

- [ ] **Step 5: Full local packaging smoke test**

Run:
```bash
OPEN_ISLAND_SPARKLE_FEED_URL="https://example.com/test-appcast.xml" zsh scripts/package-app.sh
plutil -extract SUFeedURL raw "output/package/WG Open Island.app/Contents/Info.plist"
```
Expected last line of output: `https://example.com/test-appcast.xml`

Then confirm the default still works without the override:
```bash
zsh scripts/package-app.sh
plutil -extract SUFeedURL raw "output/package/WG Open Island.app/Contents/Info.plist"
```
Expected: `https://raw.githubusercontent.com/Octane0411/open-vibe-island/main/appcast.xml`

- [ ] **Step 6: Commit**

```bash
git add scripts/package-app.sh
git commit -m "feat(release): parameterize Sparkle feed URL in package-app.sh"
```

---

### Task 2: Generate the WG Sparkle EdDSA keypair (manual/operational)

This task has no code artifact — it produces a secret only you can create and store. Do it once, before Task 4's workflow can be used for a real release.

**Files:** none (operational step; a placeholder GitHub Secret and repo variable are the "output")

- [ ] **Step 1: Build (or confirm) the Sparkle tool artifacts exist**

Run: `swift package resolve && ls .build/artifacts/sparkle/Sparkle/bin/generate_keys`
Expected: the path prints (file exists), no error.

- [ ] **Step 2: Generate a dedicated keypair for WG (separate Keychain account so it can't collide with any existing default Sparkle key on your machine)**

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account open-island-wg -x /tmp/wg_sparkle_private_key.pem
```

Expected: prints something like `Public key: <base64 string>` and writes `/tmp/wg_sparkle_private_key.pem`.

- [ ] **Step 3: Store the private key as a GitHub Secret**

In `itdragons/open-vibe-island` → Settings → Secrets and variables → Actions → New repository secret:
- Name: `WG_SPARKLE_EDDSA_KEY`
- Value: contents of `/tmp/wg_sparkle_private_key.pem`

- [ ] **Step 4: Store the public key as a GitHub Actions variable**

Settings → Secrets and variables → Actions → Variables tab → New repository variable:
- Name: `WG_SPARKLE_PUBLIC_KEY`
- Value: the base64 public key string printed in Step 2

- [ ] **Step 5: Delete the local private key file**

```bash
rm /tmp/wg_sparkle_private_key.pem
```

Expected: file no longer exists. This is the only copy outside GitHub Secrets — do not leave it on disk.

---

### Task 3: Create the WG-specific appcast (`appcast-wg.xml` + `scripts/update-appcast-wg.sh`)

**Files:**
- Create: `appcast-wg.xml`
- Create: `scripts/update-appcast-wg.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/update-appcast-wg.sh <version> <build_number> <ed_signature> <length> [pub_date]` — same call signature as upstream's `scripts/update-appcast.sh`, called by Task 4's workflow.

- [ ] **Step 1: Create `appcast-wg.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>WG Open Island Updates</title>
        <link>https://github.com/itdragons/open-vibe-island/releases</link>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
        <!-- Items are added by .github/workflows/wg-release.yml via scripts/update-appcast-wg.sh -->
    </channel>
</rss>
```

- [ ] **Step 2: Create `scripts/update-appcast-wg.sh`**

```bash
#!/bin/zsh
# Updates appcast-wg.xml with a new WG Open Island release entry.
#
# Usage:
#   zsh scripts/update-appcast-wg.sh <version> <build_number> <ed_signature> <length> [pub_date]
#
# Example:
#   zsh scripts/update-appcast-wg.sh 1.2.1 90 "abc123==" 9014852

set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <version> <build_number> <ed_signature> <length> [pub_date]" >&2
    exit 1
fi

VERSION="$1"
BUILD_NUMBER="$2"
ED_SIGNATURE="$3"
LENGTH="$4"
PUB_DATE="${5:-$(date -u '+%a, %d %b %Y %H:%M:%S +0000')}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
appcast="$repo_root/appcast-wg.xml"

if [[ ! -f "$appcast" ]]; then
    echo "Error: appcast-wg.xml not found at $appcast" >&2
    exit 1
fi

# GitHub's release-asset download URLs replace spaces in the asset filename with periods.
download_url="https://github.com/itdragons/open-vibe-island/releases/download/wg-v${VERSION}/WG.Open.Island.zip"

python3 - "$appcast" "$VERSION" "$BUILD_NUMBER" "$ED_SIGNATURE" "$LENGTH" "$PUB_DATE" "$download_url" <<'PYEOF'
import sys

appcast_path = sys.argv[1]
version = sys.argv[2]
build_number = sys.argv[3]
ed_signature = sys.argv[4]
length = sys.argv[5]
pub_date = sys.argv[6]
download_url = sys.argv[7]

new_item = f"""        <item>
            <title>Version {version}</title>
            <sparkle:version>{build_number}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>{pub_date}</pubDate>
            <enclosure
                url="{download_url}"
                type="application/octet-stream"
                sparkle:edSignature="{ed_signature}"
                length="{length}"
            />
        </item>"""

with open(appcast_path, "r") as f:
    content = f.read()

marker = "<!-- Items are added by .github/workflows/wg-release.yml via scripts/update-appcast-wg.sh -->"
if marker not in content:
    print("Error: marker comment not found in appcast-wg.xml", file=sys.stderr)
    sys.exit(1)

content = content.replace(marker, marker + "\n" + new_item)

with open(appcast_path, "w") as f:
    f.write(content)
PYEOF

echo "Updated appcast-wg.xml with version ${VERSION} (build ${BUILD_NUMBER})"
```

- [ ] **Step 3: Make it executable and syntax-check**

```bash
chmod +x scripts/update-appcast-wg.sh
bash -n scripts/update-appcast-wg.sh
```
Expected: no output from either command.

- [ ] **Step 4: Dry-run the script against a scratch copy**

```bash
cp appcast-wg.xml /tmp/appcast-wg-test.xml
OPEN_ISLAND_PACKAGE_ROOT=/tmp zsh -c '
  repo_root="'"$(pwd)"'"
  cp /tmp/appcast-wg-test.xml "$repo_root/appcast-wg.xml"
  zsh scripts/update-appcast-wg.sh 1.2.1 90 "test-signature==" 12345
  cat "$repo_root/appcast-wg.xml"
  cp /tmp/appcast-wg-test.xml "$repo_root/appcast-wg.xml"
'
```
Expected: printed XML contains a new `<item>` block with `Version 1.2.1`, `<sparkle:version>90</sparkle:version>`, and the `WG.Open.Island.zip` download URL. The final line restores the pristine scaffold so the repo file isn't left modified by this test.

- [ ] **Step 5: Commit**

```bash
git add appcast-wg.xml scripts/update-appcast-wg.sh
git commit -m "feat(release): add WG-specific Sparkle appcast and updater script"
```

---

### Task 4: Create `.github/workflows/wg-release.yml`

**Files:**
- Create: `.github/workflows/wg-release.yml`

**Interfaces:**
- Consumes: `scripts/package-app.sh` (Task 1's `OPEN_ISLAND_SPARKLE_FEED_URL`, existing `OPEN_ISLAND_BUNDLE_ID`/`OPEN_ISLAND_EDDSA_PUBLIC_KEY`), `scripts/update-appcast-wg.sh <version> <build_number> <ed_signature> <length>` (Task 3), `.build/artifacts/sparkle/Sparkle/bin/sign_update` (already vendored via SPM, same as upstream's `release.yml` uses), secrets `WG_SPARKLE_EDDSA_KEY`, variable `WG_SPARKLE_PUBLIC_KEY` (Task 2).
- Produces: a draft GitHub Release tagged `wg-v<version>` with `WG Open Island.dmg`/`.zip` attached, and a commit to `wg` updating `appcast-wg.xml`.

- [ ] **Step 1: Write the workflow file**

```yaml
name: WG Release

on:
  push:
    tags:
      - 'wg-v*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release, e.g. 1.2.1-dev1 (tag will be wg-v<version>)'
        required: true

permissions:
  contents: write

jobs:
  build-and-release:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Determine version and tag
        id: version
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          if [[ "${{ github.event_name }}" == "workflow_dispatch" ]]; then
            version="${{ github.event.inputs.version }}"
            tag="wg-v${version}"
            git tag "$tag"
            git push origin "$tag"
          else
            tag="${GITHUB_REF_NAME}"
            version="${tag#wg-v}"
          fi
          echo "version=$version" >> "$GITHUB_OUTPUT"
          echo "tag=$tag" >> "$GITHUB_OUTPUT"

      - name: Install dependencies
        run: |
          brew install create-dmg
          pip3 install --break-system-packages Pillow

      - name: Build and package (ad-hoc signed)
        env:
          OPEN_ISLAND_APP_NAME: "WG Open Island"
          OPEN_ISLAND_BUNDLE_ID: "app.openisland.wg"
          OPEN_ISLAND_VERSION: ${{ steps.version.outputs.version }}
          OPEN_ISLAND_BUILD_NUMBER: ${{ github.run_number }}
          OPEN_ISLAND_UNIVERSAL: "true"
          OPEN_ISLAND_SPARKLE_FEED_URL: "https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/appcast-wg.xml"
          OPEN_ISLAND_EDDSA_PUBLIC_KEY: ${{ vars.WG_SPARKLE_PUBLIC_KEY }}
        run: zsh scripts/package-app.sh

      - name: Verify artifacts
        run: |
          test -f "output/package/WG Open Island.zip"
          test -f "output/package/WG Open Island.dmg"
          ls -lh output/package/

      - name: Verify ad-hoc code signature
        run: |
          bundle="output/package/WG Open Island.app"
          codesign -dvv "$bundle"
          codesign --verify --deep --strict --verbose=2 "$bundle"

      - name: Verify bundle structure
        run: |
          bundle="output/package/WG Open Island.app"
          for f in \
            "Contents/MacOS/OpenIslandApp" \
            "Contents/Helpers/OpenIslandHooks" \
            "Contents/Helpers/OpenIslandSetup" \
            "Contents/Resources/OpenIsland.icns" \
            "Contents/Resources/OpenIsland_OpenIslandApp.bundle" \
          ; do
            if [[ ! -e "$bundle/$f" ]]; then
              echo "::error::Missing required file: $f"
              exit 1
            fi
          done
          echo "Bundle structure OK"

      - name: Sign update with EdDSA (Sparkle)
        id: sparkle_sign
        env:
          SPARKLE_EDDSA_KEY: ${{ secrets.WG_SPARKLE_EDDSA_KEY }}
        run: |
          sign_tool=".build/artifacts/sparkle/Sparkle/bin/sign_update"
          zip_path="output/package/WG Open Island.zip"
          sign_output="$(echo "$SPARKLE_EDDSA_KEY" | "$sign_tool" "$zip_path" --ed-key-file -)"
          ed_signature="$(echo "$sign_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
          length="$(echo "$sign_output" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
          echo "ed_signature=$ed_signature" >> "$GITHUB_OUTPUT"
          echo "length=$length" >> "$GITHUB_OUTPUT"

      - name: Update appcast-wg.xml on wg
        run: |
          cp appcast-wg.xml /tmp/appcast-wg.xml
          git fetch origin wg
          git checkout wg
          git pull --ff-only origin wg
          cp /tmp/appcast-wg.xml appcast-wg.xml
          zsh scripts/update-appcast-wg.sh \
            "${{ steps.version.outputs.version }}" \
            "${{ github.run_number }}" \
            "${{ steps.sparkle_sign.outputs.ed_signature }}" \
            "${{ steps.sparkle_sign.outputs.length }}"
          git add appcast-wg.xml
          git commit -m "chore: update appcast-wg.xml for ${{ steps.version.outputs.tag }}"
          git push origin wg

      - name: Create GitHub Release (draft)
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "${{ steps.version.outputs.tag }}" \
            --title "WG Open Island ${{ steps.version.outputs.tag }}" \
            --draft \
            --notes "Unsigned/ad-hoc-signed build. Right-click → Open on first launch to bypass Gatekeeper." \
            "output/package/WG Open Island.dmg#WG Open Island.dmg (macOS, Universal)" \
            "output/package/WG Open Island.zip#WG Open Island.zip (macOS, Universal)"
```

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/wg-release.yml'))" && echo "YAML OK"
```
Expected: `YAML OK`

- [ ] **Step 3: Confirm it doesn't collide with the existing release workflow's triggers**

```bash
grep -n "tags:" .github/workflows/release.yml .github/workflows/wg-release.yml
```
Expected: `release.yml` shows `- 'v*'`, `wg-release.yml` shows `- 'wg-v*'` — disjoint patterns, both can coexist.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/wg-release.yml
git commit -m "feat(release): add WG Open Island release workflow"
```

- [ ] **Step 5: Manual end-to-end test (run yourself, not scriptable from this session)**

Push a test tag or use `workflow_dispatch` with `version: 0.0.1-test1`, then confirm in the Actions tab that: the build succeeds, a draft release appears under itdragons/open-vibe-island Releases with both artifacts attached, and `appcast-wg.xml` on `wg` gained a new `<item>`.

---

### Task 5: Create `scripts/sync-upstream.sh`

**Files:**
- Create: `scripts/sync-upstream.sh`

**Interfaces:**
- Consumes: `gh` CLI (for `gh repo sync`), the `main`/`wg` branches already present locally and on `origin`.
- Produces: a local branch `sync/wg-<YYYYMMDD>` containing `wg` merged with the latest upstream `main`, already build-verified — final merge into `wg` is a manual step this script deliberately does not perform.

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make executable and syntax-check**

```bash
chmod +x scripts/sync-upstream.sh
bash -n scripts/sync-upstream.sh
```
Expected: no output from either command.

- [ ] **Step 3: Dirty-tree guard test**

```bash
touch /tmp/scratch-dirty-marker.txt
cp /tmp/scratch-dirty-marker.txt README.md.bak-test
zsh scripts/sync-upstream.sh; echo "exit=$?"
rm -f README.md.bak-test /tmp/scratch-dirty-marker.txt
```
Expected: script prints `ERROR: working tree is dirty...` and `exit=1` (it must refuse to run against a dirty tree rather than silently proceeding).

- [ ] **Step 4: Existing-branch guard test**

```bash
git branch "sync/wg-$(date +%Y%m%d)"
zsh scripts/sync-upstream.sh; echo "exit=$?"
git branch -D "sync/wg-$(date +%Y%m%d)"
```
Expected: script prints `ERROR: branch sync/wg-... already exists...` and `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-upstream.sh
git commit -m "feat(release): add upstream sync helper script"
```

---
