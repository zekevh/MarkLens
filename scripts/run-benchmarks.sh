#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/.benchmarks"
mkdir -p "${LOG_DIR}"

timestamp="$(date +"%Y%m%d-%H%M%S")"
log_path="${LOG_DIR}/benchmark-${timestamp}.log"

if [[ "${1-}" == "--input" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 [--input <benchmark-log>]" >&2
    exit 1
  fi
  log_path="$2"
else
  cmd=(
    xcodebuild
    -project MarkLens.xcodeproj
    -scheme MarkLens
    -destination "platform=macOS"
    test
    -only-testing:MarkLensTests/PerformanceBenchmarksTests
  )

  echo "Running benchmarks..."
  echo "Log: ${log_path}"
  echo "This can take a few seconds..."
  (
    cd "${ROOT_DIR}"
    if ! "${cmd[@]}" > "${log_path}" 2>&1; then
      echo
      echo "Benchmark run failed. Recent log output:"
      echo
      tail -n 80 "${log_path}"
      exit 1
    fi
  )
fi

echo
echo "Benchmark summary"
echo

rg "^Test case 'PerformanceBenchmarksTests\\." "${log_path}" | awk -F"'" '
  BEGIN {
    printf "%-68s %12s\n", "test_case", "duration_ms"
    printf "%-68s %12s\n", "---------", "-----------"
  }
  {
    name=$2
    sub(/^PerformanceBenchmarksTests\./, "", name)
    sub(/\(\)$/, "", name)

    duration=$5
    gsub(/[()]/, "", duration)
    sub(/ seconds$/, "", duration)

    printf "%-68s %12.3f\n", name, duration * 1000
    found=1
  }
  END {
    if (!found) {
      print "No benchmark test cases found in log input." > "/dev/stderr"
      exit 1
    }
  }
'

echo
echo "Log: ${log_path}"
