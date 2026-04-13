#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
metric="${1:-code}"
target="${2:-MarkLens}"

case "${metric}" in
  code|lines|comments|blanks)
    ;;
  *)
    echo "Usage: $0 [code|lines|comments|blanks] [path]" >&2
    exit 1
    ;;
esac

if command -v jq >/dev/null 2>&1; then
  (
    cd "${ROOT_DIR}"
    tokei -t swift --output json "${target}" | jq -r ".Swift.${metric}"
  )
else
  column_index=3
  case "${metric}" in
    lines) column_index=2 ;;
    code) column_index=3 ;;
    comments) column_index=4 ;;
    blanks) column_index=5 ;;
  esac

  (
    cd "${ROOT_DIR}"
    tokei -t swift "${target}" \
      | awk -v idx="${column_index}" '$1 == "Swift" { print $idx; exit }'
  )
fi
