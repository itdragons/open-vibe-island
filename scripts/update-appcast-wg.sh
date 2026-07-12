#!/bin/zsh
# Updates appcast-wg.xml with a new WG Open Island release entry.
#
# Usage:
#   zsh scripts/update-appcast-wg.sh <version> <build_number> <ed_signature> <length> <download_url> [pub_date]
#
# Example:
#   zsh scripts/update-appcast-wg.sh 1.2.1 90 "abc123==" 9014852 \
#     "https://github.com/itdragons/open-vibe-island/releases/download/wg-v1.2.1/WG.Open.Island-1.2.1.zip"
#
# download_url is passed in (not built here) so the enclosure URL always matches the
# asset filename produced by the workflow — single source of truth, no drift.

set -euo pipefail

if [[ $# -lt 5 ]]; then
    echo "Usage: $0 <version> <build_number> <ed_signature> <length> <download_url> [pub_date]" >&2
    exit 1
fi

VERSION="$1"
BUILD_NUMBER="$2"
ED_SIGNATURE="$3"
LENGTH="$4"
DOWNLOAD_URL="$5"
PUB_DATE="${6:-$(date -u '+%a, %d %b %Y %H:%M:%S +0000')}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
appcast="$repo_root/appcast-wg.xml"

if [[ ! -f "$appcast" ]]; then
    echo "Error: appcast-wg.xml not found at $appcast" >&2
    exit 1
fi

python3 - "$appcast" "$VERSION" "$BUILD_NUMBER" "$ED_SIGNATURE" "$LENGTH" "$PUB_DATE" "$DOWNLOAD_URL" <<'PYEOF'
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
