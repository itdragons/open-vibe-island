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
