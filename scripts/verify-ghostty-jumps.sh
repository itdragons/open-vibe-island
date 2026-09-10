#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

cd "$repo_root"

export OPEN_ISLAND_RUN_GHOSTTY_JUMP_INTEGRATION=1
zsh "$repo_root/scripts/test-clt.sh" --filter TerminalJumpServiceTests
