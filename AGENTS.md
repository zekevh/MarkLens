# MarkLens Agent Notes

Use the repo wrappers to keep command output compact.

## Preferred Commands

- Build verification: `./scripts/run-build.sh`
- Swift LOC only: `./scripts/run-swift-loc.sh`
- Swift total lines: `./scripts/run-swift-loc.sh lines`
- Tests: `./scripts/run-test.sh <test-target>`
- Benchmarks: `./scripts/run-benchmarks.sh`

## Output Discipline

- Prefer `./scripts/run-build.sh` over raw `xcodebuild`.
- Prefer `./scripts/run-swift-loc.sh` over raw `tokei`.
- Avoid full noisy command output unless debugging requires it.

## Repo Hygiene

- Build logs live under `.build-logs/`.
- Test logs live under `.test-logs/`.
- Benchmark logs live under `.benchmarks/`.
