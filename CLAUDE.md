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
SwiftProseSyntax  ← pure Swift, no UI. Tree-sitter, schema, document tree, classifiers, codecs.
   ↑
SwiftProseRendering  ← NSTextAttachment subclasses + custom NSTextLayoutFragments.
   ↑
SwiftProseView  ← TextKit 2 controller, compiler/serializer, steps, commands, input rules,
                  ProseMirror codec, theme, NS/UITextView wrappers.
   ↑
SwiftProse  ← SwiftUI surface (`SwiftProseEditor`), env modifiers, toolbar, status bar.
```

`SwiftProse` `@_exported`s the lower three — downstream apps just `import SwiftProse`. When adding code, place it in the lowest layer that satisfies its imports; don't reach upward.

### Live editing pipeline

The editor is a single TextKit 2 stack (`NSTextStorage` + `NSTextContentStorage` + `NSTextLayoutManager`) — there is no separate model document. Markdown source is the canonical state; rich attributes are recomputed on top, and a typed `ProseDocument` tree is reverse-projected from storage on demand (cached on `EditorController.document`, invalidated by every storage edit).

```
text typed
  ↓
MarkdownParser (tree-sitter, .block + .inline grammars, incremental)
  ↓
BlockSegmenter / BlockClassifier  →  [BlockSegment]
  ↓
MarkdownAttributedCompiler        →  NSAttributedString
   ├─ HighlightApplier             (markdown highlights.scm queries)
   ├─ CodeBlockHighlighter         (per-language tree-sitter, optional, host-injected)
   └─ NodePathSynthesizer          (stamps proseNodePath + proseMarks)
  ↓
NSTextStorage attributes
  ↓
LayoutFragments paint blockquote bars, code-block backgrounds, language tags
```

Two `MarkdownParser` instances run side-by-side: one with the `.block` grammar, one with the `.inline` grammar. The tree-sitter-markdown package exposes them as separate grammars (rather than the inline grammar being injected) and we drive both directly. Markdown emit goes through `MarkdownTreeSerializer` — it walks the `ProseDocument` tree, not the storage attributes.

### Source-of-truth attributes

Two reference-typed attributes are canonical on storage:

- **`.proseNodePath`** (declared in `SwiftProseSyntax/AttributeKeys.swift`, value type `NodePathBox`) — the chain of structural ancestors for this character (e.g. `[doc, blockquote, paragraph]`). Carries node identity (`NodeID`) so adjacent runs with the same logical path don't accidentally fuse. **`BlockSpec` is now derived** from `proseNodePath` at read time via `storage.blockSpec(at:)` — there is no `proseBlockSpec` storage attribute anymore.
- **`.proseMarks`** (value type `MarkSetBox`) — the `MarkSet` of inline marks (strong, em, code, link, strike) on this character. Supersedes per-attribute font-trait inspection.

**Do not infer block kind from text patterns.** Read `proseNodePath` (or its `BlockSpec` projection). When inserting, carry-forward of attributes is driven by `EditorController.carryForwardAttributeKeys`.

### ProseMirror-aligned model

`SwiftProseSyntax` defines a typed tree mirroring ProseMirror:

- **`Schema`** — the set of `NodeType`s and `MarkType`s, plus the top node. `Schema.defaultMarkdown` is the standard markdown shape.
- **`NodeType`** / **`MarkType`** — declarations with attrs, content rules, group memberships. `ContentExpression` does cardinality matching against the trailing quantifier.
- **`ProseNode`** — a `NodeType` instance with attrs and a stable `NodeID`.
- **`ProseDocument`** / **`TreeNode`** — structural / leaf / inline nodes; `MarkSet`s live on inline runs.
- **`NodePath`** — a `ProseNode` chain, used as the `proseNodePath` attribute value.

The compiler stamps `proseNodePath` and `proseMarks` directly during emit, and `ProseDocument.from(storage:schema:)` reverse-projects the tree on demand. `controller.document` returns the cached tree; `controller.onDocumentChange` fires after each character edit with the freshly-derived `ProseDocument` and a `Step.replaceText` describing the storage edit.

### Editing primitives (layered)

These are nested, not parallel — pick the highest layer that gets the job done:

1. **`Operations`** (`SwiftProseView/Operations.swift`) — direct `NSTextStorage` mutators. Internal building blocks; new mutating behavior should rarely live here.
2. **`Step`** (`SwiftProseView/Step.swift`) — typed, undoable edit. Variants: `replaceText`, `setSpec`, `toggleInlineMark`, `replaceAround`, `addMark`, `removeMark`, `setNodeAttrs`. `Step.apply` returns an `AppliedStep` containing the inverse, so undo/redo round-trips for free. **New behavior should compose `Step`s.**
3. **`Transaction`** — ordered list of `Step`s, applied atomically; pushed onto the `UndoManager` as a single unit. Validation runs over the union of every range the transaction touched, with `SpecValidator.repair` invoked when invariants drift.
4. **`Command`** (`SwiftProseView/Command.swift`) — registered in `CommandRegistry`, resolved per `EditorAction`. Builds a `Transaction` from a selection. Toolbar/menu items dispatch through here. See `Sources/SwiftProseView/Commands/`.
5. **`InputRule`** (`SwiftProseView/InputRules/InputRule.swift`) — regex-driven, peer of `Command` (not a subtype). Fires implicitly when typed text matches; receives capture groups; produces a `Transaction`. See `Sources/SwiftProseView/InputRules/DefaultInputRules.swift`.

`StepEnvironment` carries `(compiler, serializer, theme)` into every `Step.apply` — steps that need to reflow attributes (e.g. `setSpec`) recompile the affected region through it.

### Async compile path

`EditorController.setMarkdown(_:async:)` runs compilation off-main on a serial `compileQueue` against a dedicated `backgroundCompiler` (sharing the main-thread compiler with off-main calls would race the parser) and uses `compileGeneration` for latest-wins — stale results whose generation no longer matches are dropped. Headless callers (no host text view attached) and explicit `async: false` callers stay synchronous. Don't add a second compile entry point — extend the existing one.

### ProseMirror codec

`ProseMirrorCodec` (`SwiftProseView/ProseMirrorCodec.swift`) round-trips `NSAttributedString` ↔ ProseMirror-style JSON. The encode path walks the `ProseDocument` tree directly. Pipe tables encode and decode as a structural `table → table_row → (table_cell | table_header)` subtree with per-cell `align` attrs (matching `prosemirror-tables`); the compiler stamps the same structural `proseNodePath` on storage so `MarkdownTreeSerializer.emitTable` round-trips header/body/alignment/inline-marks.

### Isolating nodes (node views)

`NodeType.isolating` (today: `table`) marks a self-managed subtree that can be hoisted into a single `NSTextAttachment` so a `NodeViewProvider` renders the editing surface (cell grid, embedded editor, image gallery). Infrastructure in place: `ProseNodeAttachment` (Rendering) carries the structural subtree, `ProseSubtreeAttachment` (Syntax) is the layer-clean probe protocol used by `ProseDocument.from(storage:)` to lift the attachment's subtree, and `EditorController.nodeViewRegistry` is empty by default. Per-cell paragraphs in storage are still the live emit; the attachment-driven view is not yet wired.

### Code-block syntax highlighting

`CodeBlockHighlighter` is a protocol; the bundled `TreeSitterCodeBlockHighlighter` is registry-based. Grammar packages are **not bundled with SwiftProse** — the host app SPM-depends on individual `tree-sitter-<lang>` packages and registers them at startup. See `Examples/SwiftProseDemo/SwiftProseDemo/CodeHighlighters.swift` for a working four-language registration. When a fenced block has no info string, `detectLanguage(for:)` runs each registered grammar and picks the one with cleanest coverage (≥ 30% of source chars and ≥ 1.5× over the runner-up); ambiguous bodies stay uncolored.

### Platform abstraction

`SwiftProseRendering/PlatformAliases.swift` defines `PlatformFont` / `PlatformColor` / etc. as typealiases to the native AppKit or UIKit type. The macOS and iOS surfaces have separate text-view representables (`ProseTextViewMac.swift`, `ProseTextViewIOS.swift`) that share the `EditorController` underneath. `#if os(macOS)` / `#if canImport(UIKit)` guards are common — keep new platform-specific code on the same side as existing guards rather than introducing a new shim.

## Conventions

- The README is canonical for the public API surface. Keep it updated when changing public types in `SwiftProse` / `SwiftProseView` / `SwiftProseSyntax`.
- Tests live next to the layer they cover (`SwiftProseSyntaxTests`, `SwiftProseViewTests`, `SwiftProseTests`). Tests for new step / command / input-rule logic go in `SwiftProseViewTests`.
- License is MPL 2.0; new source files don't carry a header (existing files don't either).

## Commit message style

Match the existing log style: lowercase, scoped prefix optional (`code blocks: strip fences and indent prefix from storage`, `tables: wrap pipe-table rows under shared table ancestor`, `compiler: parse link reference attrs onto leaf node`).
