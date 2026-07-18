#!/bin/zsh
# Updates appcast-wg.xml with a new WG Open Island release entry.
#
# Usage:
#   zsh scripts/update-appcast-wg.sh <version> <build_number> <ed_signature> <length> <download_url> <release_notes_file> [pub_date]
#
# release_notes_file: one bullet per line, each becomes an <li> in the update
# dialog. Pass /dev/null or an empty file to omit the description (Sparkle then
# shows its default generic "new version available" dialog).
#
# download_url is passed in (not built here) so the enclosure URL always matches the
# asset filename produced by the workflow — single source of truth, no drift.

set -euo pipefail

if [[ $# -lt 6 ]]; then
    echo "Usage: $0 <version> <build_number> <ed_signature> <length> <download_url> <release_notes_file> [pub_date]" >&2
    exit 1
fi

VERSION="$1"
BUILD_NUMBER="$2"
ED_SIGNATURE="$3"
LENGTH="$4"
DOWNLOAD_URL="$5"
RELEASE_NOTES_FILE="$6"
PUB_DATE="${7:-$(date -u '+%a, %d %b %Y %H:%M:%S +0000')}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
appcast="$repo_root/appcast-wg.xml"

if [[ ! -f "$appcast" ]]; then
    echo "Error: appcast-wg.xml not found at $appcast" >&2
    exit 1
fi

RELEASE_NOTES=""
if [[ -f "$RELEASE_NOTES_FILE" ]]; then
    RELEASE_NOTES="$(cat "$RELEASE_NOTES_FILE")"
fi

python3 - "$appcast" "$VERSION" "$BUILD_NUMBER" "$ED_SIGNATURE" "$LENGTH" "$PUB_DATE" "$DOWNLOAD_URL" "$RELEASE_NOTES" <<'PYEOF'
import sys

appcast_path = sys.argv[1]
version = sys.argv[2]
build_number = sys.argv[3]
ed_signature = sys.argv[4]
length = sys.argv[5]
pub_date = sys.argv[6]
download_url = sys.argv[7]
release_notes = sys.argv[8] if len(sys.argv) > 8 else ""

description_block = ""
lines = [line.strip() for line in release_notes.splitlines() if line.strip()]
if lines:
    items = "\n".join(f"                    <li>{line}</li>" for line in lines)
    description_block = f"""
            <description><![CDATA[
                <ul>
{items}
                </ul>
            ]]></description>"""

new_item = f"""        <item>
            <title>Version {version}</title>
            <sparkle:version>{build_number}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>{pub_date}</pubDate>{description_block}
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
