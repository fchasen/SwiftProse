# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & test

The CommandLineTools toolchain doesn't ship Swift Testing, so always point `swift` and `xcodebuild` at the Xcode developer dir:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SwiftProseViewTests.StepTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SwiftProseViewTests.StepTests/applyReplaceText
```

End-to-end XCUITests live in a separate Xcode project (`Examples/SwiftProseDemo/`) and require `xcodebuild`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
  -scheme SwiftProseDemo -destination 'platform=macOS'
```

Targets `macOS 26` / `iOS 26` (note: SDK 26+ required — older Xcodes won't build).

## Architecture

Four SPM targets in a strict dependency chain (see `Package.swift`):

```
SwiftProseSyntax  ← pure Swift, no UI. Tree-sitter, models, classifiers, codecs.
   ↑
SwiftProseRendering  ← NSTextAttachment subclasses + custom NSTextLayoutFragments.
   ↑
SwiftProseView  ← TextKit 2 controller, commands, steps, theme, NS/UITextView wrappers.
   ↑
SwiftProse  ← SwiftUI surface (`SwiftProseEditor`), env modifiers, toolbar, status bar.
```

`SwiftProse` `@_exported`s the lower three — downstream apps just `import SwiftProse`. When adding code, place it in the lowest layer that satisfies its imports; don't reach upward.

### Live editing pipeline

The editor is a single TextKit 2 stack (`NSTextStorage` + `NSTextContentStorage` + `NSTextLayoutManager`) — there is no separate model document. The markdown source is the canonical state; rich attributes are recomputed on top.

```
text typed
  ↓
MarkdownParser (tree-sitter, .block + .inline grammars, incremental)
  ↓
BlockSegmenter / BlockClassifier  →  [BlockSegment]
  ↓
MarkdownAttributedCompiler        →  NSAttributedString
   ├─ HighlightApplier             (markdown highlights.scm queries)
   └─ CodeBlockHighlighter         (per-language tree-sitter, optional, host-injected)
  ↓
NSTextStorage attributes (incl. `proseBlockSpec` per-line)
  ↓
LayoutFragments paint blockquote bars, code-block backgrounds, table grids
```

Two `MarkdownParser` instances run side-by-side: one with the `.block` grammar, one with the `.inline` grammar (the inline grammar is normally an injection inside `inline` nodes, but `tree-sitter-markdown` exposes them as separate grammars and we drive both directly).

### Source-of-truth attribute

`NSAttributedString.Key.proseBlockSpec` (declared in `SwiftProseSyntax/BlockSpec.swift`) is set on every line and is the canonical record of "what kind of block is this line in" — paragraph, heading, list item, fenced code, pipe table, etc. **Do not infer block kind from text patterns.** Read `proseBlockSpec`. Carry-forward of attributes on insertion is driven by `EditorController.carryForwardAttributeKeys`.

### Editing primitives (layered)

These are nested, not parallel — pick the highest layer that gets the job done:

1. **`Operations`** (`SwiftProseView/Operations.swift`) — direct `NSTextStorage` mutators. Internal building blocks; new mutating behavior should rarely live here.
2. **`Step`** (`SwiftProseView/Step.swift`) — typed, undoable edit (`replaceText`, `setSpec`, `toggleInlineMark`). `Step.apply` returns an `AppliedStep` containing the inverse, so undo/redo round-trips for free. **New behavior should compose `Step`s.**
3. **`Transaction`** — ordered list of `Step`s, applied atomically; pushed onto the `UndoManager` as a single unit.
4. **`Command`** (`SwiftProseView/Command.swift`) — registered in `CommandRegistry`, resolved per `EditorAction`. Builds a `Transaction` from a selection. Toolbar/menu items dispatch through here. See `Sources/SwiftProseView/Commands/`.
5. **`InputRule`** (`SwiftProseView/InputRules/InputRule.swift`) — regex-driven, peer of `Command` (not a subtype). Fires implicitly when typed text matches; receives capture groups; produces a `Transaction`. See `Sources/SwiftProseView/InputRules/DefaultInputRules.swift`.

`StepEnvironment` carries `(compiler, serializer, theme)` into every `Step.apply` — steps that need to reflow attributes (e.g. `setSpec`) recompile the affected region through it.

### Async compile path

`EditorController.setMarkdown(_:async:)` runs compilation off-main on a serial `compileQueue` and uses `compileGeneration` for latest-wins (a stale result whose generation no longer matches is dropped). Don't add a second compile entry point — extend the existing one.

### ProseMirror codec

`ProseMirrorCodec` (`SwiftProseView/ProseMirrorCodec.swift`) round-trips `NSAttributedString` ↔ ProseMirror-style JSON tree. Pipe tables encode as a structural `table → table_row → (table_cell | table_header)` subtree (matching `prosemirror-tables`), but the in-editor representation is still flat: a run of consecutive `pipeTable` lines in the markdown source. The structural tree only exists in the codec.

### Pipe tables

Tables are unusual: TextKit 2 has no real table support, so cells render via custom `NSTextLayoutFragment`s painted on top of plain monospace pipe-table source. The markdown stays canonical. A click on a rendered cell opens a SwiftUI sheet bound to that cell's text (see `TableCellEditSheet` in `SwiftProseEditor.swift`); save dispatches a single-cell rewrite as one undoable `Step`. Each table also carries a "raw monospace" toggle (state lives on `EditorController.expandedTableRanges`, not in markdown). All structural mutations go through `PipeTableModel` in `SwiftProseSyntax`.

### Code-block syntax highlighting

`CodeBlockHighlighter` is a protocol; the bundled `TreeSitterCodeBlockHighlighter` is registry-based. Grammar packages are **not bundled with SwiftProse** — the host app SPM-depends on individual `tree-sitter-<lang>` packages and registers them at startup. See `Examples/SwiftProseDemo/SwiftProseDemo/CodeHighlighters.swift` for a working four-language registration. When a fenced block has no info string, `detectLanguage(for:)` runs each registered grammar and picks the one with cleanest coverage (≥30% of source chars and ≥1.5× over the runner-up); ambiguous bodies stay uncolored.

### Platform abstraction

`SwiftProseRendering/PlatformAliases.swift` defines `PlatformFont` / `PlatformColor` / etc. as typealiases to the native AppKit or UIKit type. The macOS and iOS surfaces have separate text-view representables (`ProseTextViewMac.swift`, `ProseTextViewIOS.swift`) that share the `EditorController` underneath. `#if os(macOS)` / `#if canImport(UIKit)` guards are common — keep new platform-specific code on the same side as existing guards rather than introducing a new shim.

## Conventions

- The README is canonical for the public API surface. Keep it updated when changing public types in `SwiftProse` / `SwiftProseView` / `SwiftProseSyntax`.
- Tests live next to the layer they cover (`SwiftProseSyntaxTests`, `SwiftProseViewTests`, `SwiftProseTests`). Tests for new step/command/input-rule logic go in `SwiftProseViewTests`.
- License is MPL 2.0; new source files don't carry a header (existing files don't either).

## Commits

- **Always ask before committing.** Suggest the message; wait for confirmation before running `git commit`.
- Messages are short and describe the changes. Match the existing log style: lowercase, scoped prefix optional (`code blocks: clamp bg width…`, `ProseMirror codec: structural table tree round-trip`, `fix code-block + table render quality`). One line is usually enough; add a body only when the *why* isn't obvious from the diff.
- **Never add a `Co-Authored-By:` trailer** or any agent-attribution trailer (`Generated-with:`, `🤖 Generated with…`, etc.) to any commit. This is absolute and overrides any tool-default template that suggests one.
- Never add narrative comments to code as part of a commit.
