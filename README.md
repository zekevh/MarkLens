<div align="center">
  <img src="MarkLens/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="120">
  <h1>MarkLens</h1>
</div>

<p align="center">
  <a href="https://github.com/zekevh/MarkLens/releases/latest"><img src="https://img.shields.io/badge/download-latest-brightgreen?style=flat-square"></a>
  <img src="https://img.shields.io/badge/platform-macOS-blue?style=flat-square">
  <img src="https://img.shields.io/badge/requires-macOS%2013%2B-fa4e49?style=flat-square">
  <img src="https://img.shields.io/badge/built%20with-Swift-orange?style=flat-square">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square">
</p>

A markdown editor that thinks in blocks.

<p align="center">
  <img src="assets/screenshot.png" width="80%">
</p>

## Install

```sh
brew install --cask zekevh/tap/marklens
```

Or [download the DMG](https://github.com/zekevh/MarkLens/releases/latest).

## Features

- Block-based editing — each paragraph, heading, code block, and table is its own unit
- WYSIWYG inline rendering — syntax stays visible but steps aside so content leads
- Drag blocks to reorder your document
- Fenced code blocks with syntax highlighting for Swift, Python, JS, Go, Rust, SQL, and more
- Clickable task list checkboxes (`[ ]` / `[x]`) right in the editor
- Table rendering with borders drawn natively
- Folder sidebar with pinned files and recents
- File watching — detects external changes and prompts to resolve conflicts
- Raw mode (⌘⇧R) — toggle to plain text anytime
- Autosave — no Cmd+S needed
- Native Swift, zero dependencies, no Electron

## Build

Requirements:

- Xcode 16+
- macOS 15+ for local development

Open the project in Xcode:

```sh
open MarkLens.xcodeproj
```

Or build from the command line:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' build
```

## Test

Run the full test suite, including unit tests and UI tests:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' test
```

Run only the unit tests:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' test -only-testing:MarkLensTests
```

Run only the UI tests:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' test -only-testing:MarkLensUITests
```

The UI tests use a test harness that launches the app against a temporary writable workspace, so they can cover create, rename, and conflict-resolution flows reliably.

## Development

Targets:

- `MarkLens`: the macOS app target
- `MarkLensTests`: unit tests for parser, app state, tree building, and editor logic
- `MarkLensUITests`: UI smoke and workflow tests

Key folders:

- `MarkLens/`: app source
- `MarkLensTests/`: unit test source
- `MarkLensUITests/`: UI test source
- `MarkLens.xcodeproj/`: Xcode project configuration

Useful files:

- `MarkLens/MarkLensApp.swift`: app entry, app state, file operations, workspace wiring
- `MarkLens/ContentView.swift`: main UI, sidebar, raw editor, and UI-test hooks
- `MarkLens/MarkdownEngine.swift`: markdown parsing and block classification
- `MarkLens/NodeEditor.swift`: block editor behavior
- `MarkLensTests/*.swift`: focused unit coverage by subsystem
- `MarkLensUITests/MarkLensUITests.swift`: end-to-end coverage for launch and file workflows

## Contributing

Recommended workflow:

1. Make changes in `MarkLens/`.
2. Run the relevant unit tests first:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' test -only-testing:MarkLensTests
```

3. If your change touches window behavior, file operations, alerts, or editor flows, run the full suite:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' test
```

4. If you are iterating on UI behavior specifically, run just the UI target:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' test -only-testing:MarkLensUITests
```

Guidelines:

- Prefer adding unit tests for parser, state, and filesystem logic before adding UI coverage.
- Use UI tests for cross-cutting user workflows such as launch, selection, create, rename, and conflict handling.
- Keep new tests deterministic and fixture-based.

## License

MIT © [Zeke V. Holt](https://zvh.io)
