#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/.build-logs"
mkdir -p "${LOG_DIR}"

timestamp="$(date +"%Y%m%d-%H%M%S")"
log_path="${LOG_DIR}/build-${timestamp}.log"

cmd=(
  xcodebuild
  -project MarkLens.xcodeproj
  -scheme MarkLens
  -destination "platform=macOS"
  build
)

echo "Running build..."
echo "Log: ${log_path}"

(
  cd "${ROOT_DIR}"
  if ! "${cmd[@]}" > "${log_path}" 2>&1; then
    echo
    echo "Build failed. Filtered log output:"
    echo

    filtered_output="$(sed -n '/MarkLensApp.swift/,/WorkspaceSupport.swift/p' "${log_path}")"
    if [[ -n "${filtered_output}" ]]; then
      printf "%s\n" "${filtered_output}"
    else
      tail -n 80 "${log_path}"
    fi
    exit 1
  fi
)

echo
echo "Build succeeded"
echo "Log: ${log_path}"
