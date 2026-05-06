# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & test

The CommandLineTools toolchain doesn't ship Swift Testing, so always point `swift` and `xcodebuild` at the Xcode developer dir:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SwiftProseViewTests.StepInverseRoundTripTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SwiftProseViewTests.StepInverseRoundTripTests/replaceTextRoundTrips
```

End-to-end XCUITests live in a separate Xcode project (`Examples/SwiftProseDemo/`) and require `xcodebuild`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
  -scheme SwiftProseDemo -destination 'platform=macOS'
```

Targets `macOS 26` / `iOS 26` (SDK 26+ required — older Xcodes won't build).

## Architecture

Four SPM targets in a strict dependency chain (see `Package.swift`):

```
SwiftProseSyntax  ← pure Swift, no UI. Tree-sitter, schema, document tree, classifiers, codecs.
   ↑
SwiftProseRendering  ← NSTextAttachment subclasses + custom NSTextLayoutFragments.
   ↑
SwiftProseView  ← TextKit 2 controller, compiler/serializer, steps, commands, input rules,
                  ProseMirror codec, theme, keymap, plugins, NS/UITextView wrappers.
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

`SwiftProseSyntax` defines a typed tree mirroring ProseMirror. The default schema (`Schema.defaultMarkdown`) is a typed superset of `prosemirror-schema-basic` + `addListNodes` — wire-format-load-bearing attributes (`ordered_list.order`, `code_block.params`, `image.{src,alt,title}` defaulting to `""`, `link.{href,title}` defaulting to `""`, `table_cell.colwidth` as `[Int]`) track PM exactly. Marks are declared in PM-basic order: `[link, em, strong, code, strike]`. Extensions over PM-basic that need stripping for strict interop: `task_list`, `html_block`, `link_reference`, `strike` mark, `table_*`.

Core types:

- **`Schema`** — `NodeType`s, `MarkType`s, top node. Preserves `nodeTypeOrder` and `markTypeOrder` for stable iteration. `Schema.nodeFromJSON(_:)` / `Schema.markFromJSON(_:)` decode PM JSON without pulling in the View layer (`SchemaJSON.swift`).
- **`NodeType`** — content rules, attrs, and PM spec flags: `atomSpec`, `isCode`, `defining`, `definingForContent`, `definingAsContext`, `selectable`, `draggable`, `linebreakReplacement`, `allowedMarks: AllowedMarks` (`.all` / `.none` / `.named(Set)`). Factories `create(attrs:)` / `createChecked(attrs:)` / `createAndFill(attrs:)` fill schema defaults; `createChecked` throws `NodeTypeAttrError.missingRequired` for defaultless attrs.
- **`MarkType`** — attrs, `excludes: Set<Name>`, `excludesAll: Bool` (PM `"_"`), `inclusive: Bool`. `MarkSet.adding(_:in:)` enforces excludes (e.g. adding `code` over a `strong em` span drops both). PM-style helpers: `mark.addToSet(_:in:)`, `mark.removeFromSet(_:)`, `mark.isInSet(_:)`.
- **`ContentExpression`** — content rules parse to a `ContentMatch` automaton (`ContentMatch.swift`) with `matchType`, `matchFragment`, `validEnd`, `defaultType`, `edgeCount`. Multi-element rules like `paragraph block*` validate correctly; single-segment `block+` / `inline*` / `(table_cell | table_header)+` also work.
- **`ProseNode`** — `NodeType` instance with attrs and a stable `NodeID`.
- **`ProseDocument` / `TreeNode`** — structural / leaf / inline nodes. `TreeNode.leaf(ProseNode, MarkSet)` carries marks alongside the leaf so an image inside a link span keeps the link mark across encode / decode. `MarkSet`s also live on `inline` runs.
- **`NodePath`** — a `ProseNode` chain, used as the `proseNodePath` attribute value.
- **`ResolvedPos` / `NodeRange`** (`ResolvedPos.swift`) — `document.resolve(_:)` returns a `ResolvedPos` exposing `depth`, `parent(at:)`, `node(at:)`, `index(at:)`, `start(at:)` / `end(at:)` / `before(at:)` / `after(at:)`, `textOffset`, `marks()`, `marksAcross(_:)`, `blockRange(_:pred:)`. `NodeRange` represents a contiguous child range under one parent — used by lift / wrap probes.
- **`ProseAttrValue` / `PMValue`** — JSON-roundtrippable scalars + `.array([ProseAttrValue])` + `.object([String: ProseAttrValue])` for nested attribute shapes. `ProseAttrValue(pmValue:)` and `.toPMValue()` convert.

The compiler stamps `proseNodePath` and `proseMarks` directly during emit, and `ProseDocument.from(storage:schema:)` reverse-projects the tree on demand. `controller.document` returns the cached tree; `controller.onDocumentChange` fires after each character edit with the freshly-derived `ProseDocument` and a `Step.replaceText` describing the storage edit.

### Editing primitives (layered)

These are nested, not parallel — pick the highest layer that gets the job done:

1. **`Operations`** (`SwiftProseView/Operations.swift`) — direct `NSTextStorage` mutators. Internal building blocks; new mutating behavior should rarely live here.
2. **`Step`** (`SwiftProseView/Step.swift`) — typed, undoable edit. Variants: `replaceText`, `setSpec`, `toggleInlineMark`, `replaceAround`, `addMark`, `removeMark`, `setNodeAttrs`, `setNodeAttrsAt` (position-addressed), `addNodeMark`, `removeNodeMark`, `setDocAttr`, `replaceCellInline`, `setTableSubtree`. Each `Step.apply` returns an `AppliedStep` whose `inverse` is itself typed (`addMark` ↔ `removeMark`, `setNodeAttrs` ↔ `setNodeAttrs(priorAttrs)`, `replaceAround` ↔ `replaceAround`, `setSpec` ↔ `setSpec(priorSpec)`) so undo / redo preserves `NodeID`s. `Step.canApply(to:)` returns a `LegalityError?` without mutating storage; `Transaction.apply` skips illegal steps cleanly. `Step.merge(_:)` coalesces adjacent inserts / matching mark ops; `Step.isStructural` is `true` for setSpec / replaceAround / setNodeAttrs / table / node-mark / setDocAttr — `merge` refuses to coalesce structural steps. **New behavior should compose `Step`s.**
3. **`Transaction`** — ordered list of `Step`s, applied atomically; pushed onto the `UndoManager` as a single unit. Carries `selection: Selection?` (installed on apply), `scrollIntoView: Bool`, `meta: [String: AnyHashable]` (`setMeta(_:_:)` / `getMeta(_:)`), and `label: String?` (forwarded to `undoManager.setActionName`). `meta["addToHistory"] == false` skips undo recording; `meta["closeHistory"] == true` opens a fresh undo group on apply. `Transaction.apply` accumulates the union of every step's `mappedRange` so post-apply validation covers the full mutated area.
4. **`Command`** (`SwiftProseView/Command.swift`) — registered in `CommandRegistry`, resolved per `EditorAction`. Builds a `Transaction` from a selection. Toolbar/menu items dispatch through here. See `Sources/SwiftProseView/Commands/`. `chainCommands(_:)` runs commands in order, first non-nil transaction wins. Generic `ToggleMarkCommand(id:mark:label:)` and `SetBlockTypeCommand(id:label:kind:)` subsume per-mark / per-heading commands. PM-shaped command stubs in `Commands/PMCommands.swift` (`selectAll`, `splitBlock`, `joinBackward` / `joinForward`, `selectNodeBackward` / `selectNodeForward`, `selectTextblockStart` / `selectTextblockEnd`, etc.) — many are skeletons returning nil until their structural Step builders land.
5. **`InputRule`** (`SwiftProseView/InputRules/InputRule.swift`) — regex-driven, peer of `Command` (not a subtype). Fires implicitly when typed text matches; receives capture groups; produces a `Transaction`. See `InputRules/DefaultInputRules.swift`. PM helpers `wrappingInputRule(...)` and `textblockTypeInputRule(...)` build rules from a regex plus a target node type / block spec. `InputRule.inCode: InCodePolicy` (`.run` / `.skip`) lets bold / italic / strike / codeSpan opt out when the cursor sits inside a code block. Optional smart-typography rules (`InputRule.smartSubstitutionRules(_:)`) ship behind a `RuleOptions` set (`.smartQuotes`, `.ellipsis`, `.emDash`).

`StepEnvironment` carries `(compiler, serializer, theme)` into every `Step.apply` — steps that need to reflow attributes (e.g. `setSpec`) recompile the affected region through it.

`StepMap.mapResult(_:bias:)` returns a `MapResult { pos, deleted, deletedBefore, deletedAfter, deletedAcross }` so callers can react to deletion-around-position. `Mapping` tracks mirror pairs (`appendMap(_:mirrors:)`, `getMirror(_:)`, `invert()`, `appendMappingInverted(_:)`).

`Transforms` (`SwiftProseView/Transforms.swift`) is a stub vocabulary mirroring PM's `Transform`: `lift`, `wrap`, `split`, `join`, `setBlockType`, `setNodeMarkup`, `clearIncompatible` plus probes (`canSplit`, `canJoin`, `liftTarget`, `findWrapping`). The Step-builder bodies are not fully wired yet — commands that need lift / wrap continue to compose `setSpec` bundles until each call site migrates.

### Selection

`SwiftProseView/Selection.swift` defines the typed `Selection` enum: `.text(range, anchor, head)`, `.node(path, range)`, `.all`. `controller.currentTypedSelection` returns one. `Selection.cursor(at:)` and `Selection.textRange(_:)` are convenience constructors. A `Transaction.selection` field installs the result on apply.

### Keymap

`SwiftProseView/Keymap.swift`. `EditorController.keymap` is a PM-style binding from key spec to `EditorAction`. Defaults `Keymap.mac` / `Keymap.pc`. `KeySpec.make(key:mod:shift:alt:)` builds normalized strings (`"Mod-Shift-b"`); `Mod` resolves to Cmd on macOS, Ctrl elsewhere. The macOS text view's `shortcutAction(forCommandKey:shift:)` consults this; iOS surface still has hardcoded `keyCommands` to be migrated when Phase 5.4 lands fully.

### Plugin system

`SwiftProseView/EditorPlugin.swift`. `EditorPlugin` protocol with `filterTransaction(_:controller:)` (veto), `appendTransaction(after:controller:)` (follow-up), and `props: PluginProps` for input-event hooks (`handleClick`, `handlePaste`, `handleDrop`, `handleKeyDown`, `handleTextInput`). Per-plugin state lives behind `PluginKey<State>`: `controller.setPluginState(_:for:)` / `controller.pluginState(for:)`. The macOS click handler consults `plugins[*].props.handleClick` before built-in checkbox handling.

Single-callback observers on `EditorController` (`onDocumentChange`, `onDiagnostic`, `onSchemaDiagnostic`, `onSelectionChanged`) coexist with multi-subscriber registration: `addOnDocumentChange(_:)` / `addOnDiagnostic(_:)` / `addOnSelectionChanged(_:)` return an `ObserverToken` for `removeObserver(_:)`. Internal callsites use the `fanoutDocumentChange(_:_:)` / `fanoutDiagnostic(_:)` / `fanoutSelectionChanged(_:)` helpers.

### Validation

After every transaction, `EditorController.validateAndRepair(in:)` runs:

1. `SpecValidator.validate(in:range:)` — line-level structural invariants. `SpecValidator.repair(in:range:)` is invoked when diagnostics fire. Surfaces through `onDiagnostic`.
2. Project storage to `ProseDocument`, then `SchemaValidator.validate(_:)` — typed-tree-level checks (unknown node / mark types, content-rule mismatches, marks on disallowed parents). Reports through `onSchemaDiagnostic`; no auto-repair.

### History

`SwiftProseView/HistoryConfig.swift`. `EditorController.historyConfig: HistoryConfig` exposes `depth` (forwarded to `undoManager.levelsOfUndo`) and `newGroupDelay`. `controller.closeHistoryGroup()` opens a fresh undo group; transactions tagged `meta["closeHistory"] == true` do the same on apply. `controller.undoDepth` / `redoDepth` / `isHistoryTransaction(_:)` are read-only accessors.

`EditorController.undoInputRule()` runs at the head of the Backspace chain — when the most recently fired input rule is still on the cursor, Backspace undoes the rule rather than deleting a character. `inputRules.lastFiredRule` is set by `InputRuleRunner.evaluate` after a successful match.

### Decorations

`SwiftProseView/DecorationProvider.swift`. The bundled `BlockSpecDecorationProvider` derives blockquote bars / code backgrounds / HRs from `proseNodePath`. `DecorationSet([...])` aggregates multiple providers; downstream consumers sort by `zIndex` when painting.

### Async compile path

`EditorController.setMarkdown(_:async:)` runs compilation off-main on a serial `compileQueue` against a dedicated `backgroundCompiler` (sharing the main-thread compiler with off-main calls would race the parser) and uses `compileGeneration` for latest-wins — stale results whose generation no longer matches are dropped. Headless callers (no host text view attached) and explicit `async: false` callers stay synchronous. Don't add a second compile entry point — extend the existing one.

### ProseMirror codec

`ProseMirrorCodec` (`SwiftProseView/ProseMirrorCodec.swift`) round-trips `NSAttributedString` ↔ ProseMirror-style JSON. The encode path walks the `ProseDocument` tree directly. Pipe tables encode and decode as a structural `table → table_row → (table_cell | table_header)` subtree with per-cell `align` attrs (matching `prosemirror-tables`); the compiler stamps the same structural `proseNodePath` on storage so `MarkdownTreeSerializer.emitTable` round-trips header / body / alignment / inline-marks.

Encoder behaviors worth knowing:

- Adjacent inline runs sharing a mark set merge into one PM `text` node (`pmMarksEqual` helper).
- Attrs whose value matches the schema default are omitted (e.g. `image.alt = ""` → no `alt` field).
- `markAliases: [Name: Name]` rewrites mark type names on emit (`["strike": "strikethrough"]`) for ecosystems with different naming.
- `firstListItemOrder(in:)` recovers `ordered_list.order` from the deepest first-list_item when the wrapping list lost it via tree projection.

`SchemaMap` extends the inline mark surface for custom marks. Mark `apply`/`extract` pairs project to / from rendering attributes.

### Isolating nodes (node views)

`NodeType.isolating` (today: `table`) marks a self-managed subtree that can be hoisted into a single `NSTextAttachment` so a `NodeViewProvider` renders the editing surface (cell grid, embedded editor, image gallery). Infrastructure in place: `ProseNodeAttachment` (Rendering) carries the structural subtree, `ProseSubtreeAttachment` (Syntax) is the layer-clean probe protocol used by `ProseDocument.from(storage:)` to lift the attachment's subtree, and `EditorController.nodeViewRegistry` is empty by default. Per-cell paragraphs in storage are still the live emit; the attachment-driven view is not yet wired.

### Code-block syntax highlighting

`CodeBlockHighlighter` is a protocol; the bundled `TreeSitterCodeBlockHighlighter` is registry-based. Grammar packages are **not bundled with SwiftProse** — the host app SPM-depends on individual `tree-sitter-<lang>` packages and registers them at startup. See `Examples/SwiftProseDemo/SwiftProseDemo/CodeHighlighters.swift` for a working four-language registration. When a fenced block has no info string, `detectLanguage(for:)` runs each registered grammar and picks the one with cleanest coverage (≥ 30% of source chars and ≥ 1.5× over the runner-up); ambiguous bodies stay uncolored.

### Platform abstraction

`SwiftProseRendering/PlatformAliases.swift` defines `PlatformFont` / `PlatformColor` / etc. as typealiases to the native AppKit or UIKit type. The macOS and iOS surfaces have separate text-view representables (`ProseTextViewMac.swift`, `ProseTextViewIOS.swift`) that share the `EditorController` underneath. `#if os(macOS)` / `#if canImport(UIKit)` guards are common — keep new platform-specific code on the same side as existing guards rather than introducing a new shim.

## Conventions

- The README is canonical for the public API surface. Keep it updated when changing public types in `SwiftProse` / `SwiftProseView` / `SwiftProseSyntax`.
- Tests live next to the layer they cover (`SwiftProseSyntaxTests`, `SwiftProseViewTests`, `SwiftProseTests`). Tests for new step / command / input-rule logic go in `SwiftProseViewTests`. Cross-cutting suites: `ProseMirrorJSONConformanceTests`, `StepInverseRoundTripTests`, `MappingInvariantTests`, `ResolvedPosTests`.
- Comments stay short and technical. Lead with the rule, not the narrative — no "PM uses X for Y, so we …" prose. Skip references to historical incidents, callers, or PR numbers.
- License is MPL 2.0; new source files don't carry a header (existing files don't either).

## Commit message style

Single-line, lowercase, scoped prefix optional. No body, no trailers (no `Co-authored-by`, no "PM-equivalent to …" footers). Match the existing log:

- `schema: rename ordered_list.start → ordered_list.order to match PM`
- `steps: typed inverses for addMark / removeMark / setNodeAttrs / replaceAround / setSpec`
- `tables: route TK2 line-fragment sizing through view-provider measurement`
- `compiler: parse link reference attrs onto leaf node`
