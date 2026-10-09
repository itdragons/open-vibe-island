#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

required_files=(
    "README.md"
    "AGENTS.md"
    "docs/index.md"
    "docs/product.md"
    "docs/architecture.md"
    "docs/quality.md"
    "docs/worktree-workflow.md"
    "docs/exec-plans/README.md"
    "docs/references/README.md"
)

for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "missing required file: $file" >&2
        exit 1
    fi
done

while IFS= read -r file; do
    case "$file" in
        docs/review/*)
            continue
            ;;
    esac

    if ! grep -qE '^# ' "$file"; then
        echo "missing top-level heading: $file" >&2
        exit 1
    fi
done < <(find docs -name '*.md' -type f | sort)

while IFS= read -r file; do
    case "$file" in
        docs/index.md|docs/review/*|docs/exec-plans/active/*|docs/exec-plans/completed/*|docs/superpowers/*)
            continue
            ;;
    esac

    if ! grep -Fq "$file" docs/index.md; then
        echo "docs index is missing link to: $file" >&2
        exit 1
    fi
done < <(find docs -name '*.md' -type f | sort)

if ! grep -Fq "docs/index.md" README.md; then
    echo "README.md should link to docs/index.md" >&2
    exit 1
fi

if ! grep -Fq "scripts/harness.sh" README.md; then
    echo "README.md should mention scripts/harness.sh" >&2
    exit 1
fi

echo "docs check passed"
