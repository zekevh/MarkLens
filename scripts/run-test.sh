#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/.test-logs"
mkdir -p "${LOG_DIR}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <test-target>" >&2
  echo "Examples:" >&2
  echo "  $0 MarkLensTests" >&2
  echo "  $0 MarkLensUITests" >&2
  echo "  $0 MarkLensTests/AppStateTreeTests" >&2
  exit 1
fi

target="$1"
timestamp="$(date +"%Y%m%d-%H%M%S")"
safe_target="${target//\//-}"
log_path="${LOG_DIR}/test-${safe_target}-${timestamp}.log"

cmd=(
  xcodebuild
  -project MarkLens.xcodeproj
  -scheme MarkLens
  -destination "platform=macOS"
  test
  "-only-testing:${target}"
)

echo "Running tests: ${target}"
echo "Log: ${log_path}"
echo "This can take a few seconds..."

(
  cd "${ROOT_DIR}"
  if ! "${cmd[@]}" > "${log_path}" 2>&1; then
    echo
    echo "Test run failed. Recent log output:"
    echo
    tail -n 80 "${log_path}"
    exit 1
  fi
)

echo
echo "Test summary"
echo

rg "^(Test suite|Test case |\\*\\* TEST )" "${log_path}" || {
  echo "No test summary lines found in log output." >&2
  exit 1
}

echo
echo "Log: ${log_path}"
