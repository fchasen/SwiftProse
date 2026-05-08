# SwiftProse

A SwiftUI markdown editor for macOS and iOS. Markup renders as you type, the underlying model is a typed ProseMirror-aligned tree, and the bound `String` is always the canonical markdown source.

## What you get

- **Live markdown rendering.** `**bold**` becomes bold, `# Heading` sizes up, code spans switch to monospace, links collapse to their display text — without leaving the source.
- **Block kinds.** Paragraphs, headings (H1–H6), bullet / ordered / task lists with a clickable checkbox, blockquotes, fenced and indented code blocks, horizontal rules, pipe tables, HTML blocks, link reference definitions.
- **Inline marks.** Bold, italic, strikethrough, inline code, links.
- **Pipe tables.** Insert / delete row & column, alignment toggles, structural editing through the toolbar.
- **Code highlighting.** Pluggable per-language tree-sitter grammars; bare fences auto-detect.
- **Toolbar + status bar.** Built-in SwiftUI toolbar covers the standard surface; status bar reports word / character / cursor.
- **Spell, grammar, autocorrect.** Configurable per editor; code blocks and inline code are excluded automatically on macOS.
- **Cross-platform.** Same SwiftUI view, same controller, same markdown — macOS and iOS.
- **Typed undo.** Every edit is a typed `Step` with a typed inverse, so undo / redo round-trips faithfully.
- **ProseMirror JSON.** Round-trips with `prosemirror-schema-basic` + `addListNodes` for collab transports or external storage.

## Requirements

- Swift 5.10+
- macOS 26 / iOS 26 (SDK 26)

## Install

Add SwiftProse to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/SwiftProse", from: "0.1.0")
]
```

Add it to the target:

```swift
.target(name: "MyApp", dependencies: ["SwiftProse"])
```

`import SwiftProse` is enough — the package re-exports its three internal modules.

## Quick start

```swift
import SwiftProse
import SwiftUI

struct DescriptionEditor: View {
    @State var text = "# Hello\n\nType into me.\n"

    var body: some View {
        SwiftProseEditor(text: $text)
            .frame(minHeight: 240)
    }
}
```

The editor parses, renders, and re-serializes the markdown on every change; `text` always reflects the canonical source. External writes to `text` (e.g. opening a different file) replace the editor contents.

## Configuration

```swift
SwiftProseEditor(text: $text)
    .configuration(.init(
        toolbar: SwiftProseEditor.Configuration.defaultToolbar,
        statusItems: [.words, .characters, .cursor],
        sizing: .fillContainer,
        minHeight: 320
    ))
```

- **Toolbar** — `.action(...)`, `.divider`, `.spacer`, or `.custom(...)`. The default toolbar covers bold / italic / strikethrough, H1–H3, lists, blockquote, code span / block, link, and horizontal rule.
- **Status bar** — `.words`, `.characters`, `.cursor` (line:column).
- **Sizing** — `.fitsContent` (height tracks content from `minHeight`) or `.fillContainer` (fixed height, scrolls internally).
- **Context menu** — append `ContextMenuItem`s to the platform edit menu.
- **Spell / grammar / autocorrect** — `spellChecking:` accepts `.off`, `.spelling`, `.spellingAndGrammar`, or `.full` (default). macOS excludes code blocks and inline code automatically; iOS applies the toggle to the whole text view.

## Theming

```swift
SwiftProseEditor(text: $text)
    .theme(ProseTheme.default(fontScale: 1.1))
```

`ProseTheme` exposes body / monospace fonts, foreground / markup / link colors, blockquote bar, heading scale, and per-tag `CodePalette` colors for syntax-highlighted code blocks.

## Code-block syntax highlighting

Fenced code blocks render with a tinted background by default. To color the body via tree-sitter, register grammars on a `TreeSitterCodeBlockHighlighter` and pass it via `.codeBlockHighlighter(_:)`. Grammar packages aren't bundled.

```swift
import SwiftProse
import SwiftTreeSitter
import TreeSitterSwift

let highlighter = TreeSitterCodeBlockHighlighter()
let queryData = try Data(contentsOf: Bundle.main.url(
    forResource: "swift", withExtension: "scm", subdirectory: "queries")!)
try highlighter.register(
    language: "swift",
    language: Language(language: tree_sitter_swift()),
    queryData: queryData
)

SwiftProseEditor(text: $text)
    .codeBlockHighlighter(highlighter)
```

Bare fences (` ``` ` with no info string) trigger language detection — the body is parsed against each registered grammar and the one with the cleanest coverage (≥ 30% of source chars and ≥ 1.5× over the runner-up) wins. Ambiguous bodies stay uncolored. `Examples/SwiftProseDemo/SwiftProseDemo/CodeHighlighters.swift` registers swift / js / css / html.

## Inline content (chips, mentions)

Map host-level rich content (`URL`, bug ID, user mention, etc.) to a `ProseInlineContent` and the editor draws it as a SwiftUI-styled chip:

```swift
SwiftProseEditor(text: $text)
    .inlineContentProvider { content in
        ChipAttachment.make(for: content)
    }
```

## Reading and writing markdown

The `text` binding is the source of truth. To touch the editor imperatively, hook the controller:

```swift
SwiftProseEditor(text: $text)
    .onProseControllerReady { controller in
        controller.perform(.bold)            // run any EditorAction
        let md = controller.markdown()       // current source
        controller.setMarkdown("new\n")      // replace
    }
```

`SwiftProseEditor.Action` enumerates everything the toolbar / context menu performs:

`bold`, `italic`, `strikethrough`, `heading(level:)`, `unorderedList`, `orderedList`, `taskList`, `blockquote`, `codeSpan`, `codeBlock`, `link(url:label:)`, `horizontalRule`, `indent`, `outdent`, `insertTable(rows:columns:)`, `insertTableRowAbove`, `insertTableRowBelow`, `insertTableColumnBefore`, `insertTableColumnAfter`, `deleteTableRow`, `deleteTableColumn`, `setTableColumnAlignment(_:)`.

For lower-level edits, build a `Transaction` and apply it to the controller:

```swift
let lineRange = NSRange(location: 0, length: controller.textStorage.length)
controller.apply(Transaction(steps: [
    .setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 2)))
], label: "Promote to heading"))
// → "## draft\n"
```

Transactions carry a label (`undoManager.setActionName`), an optional `selection` to install on apply, a `scrollIntoView` flag, and a `meta` bag — `meta["addToHistory"] = false` skips the undo stack, `meta["closeHistory"] = true` opens a fresh undo group.

## Customizing behavior

### Commands

A `Command` reads the current selection and produces a `Transaction`. Register one to add a new toolbar / menu / shortcut action:

```swift
struct InsertCalloutCommand: Command {
    let id = "callout"
    func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        Transaction(
            steps: [.replaceText(range: selection, with: NSAttributedString(string: "> Heads up\n"))],
            label: "Callout"
        )
    }
}

controller.commands.register(InsertCalloutCommand())
```

The generic `ToggleMarkCommand(id:mark:label:)` and `SetBlockTypeCommand(id:label:kind:)` cover the inline-mark and block-kind toggle patterns. `chainCommands(_:)` runs commands in order — first non-nil transaction wins, useful for fallbacks.

### Input rules

`InputRule` fires when typed text matches a regex. The default set turns `# ` into a heading, `> ` into a blockquote, `- ` / `1. ` / `- [ ] ` into lists, ` ``` ` into a fenced code block, and `**bold**` / `*italic*` / `~~strike~~` / `` `code` `` into inline marks. `InputRuleRunner.makeDefault()` ships these.

Add custom rules with the PM-style helpers:

```swift
controller.inputRules.register(
    textblockTypeInputRule(id: "h7", pattern: "^!! $", kind: .heading(level: 6))
)
```

`wrappingInputRule(...)` produces a list / blockquote wrap rule. Bold / italic / strike / codeSpan default to `inCode: .skip` so typing `*` inside a code block stays literal.

Optional smart-typography substitutions ship behind a `RuleOptions` set:

```swift
for rule in InputRule.smartSubstitutionRules([.smartQuotes, .ellipsis, .emDash]) {
    controller.inputRules.register(rule)
}
```

Backspace immediately after a rule fires runs `controller.undoInputRule()` first — the user can keep their typed source by pressing Backspace once.

### Keymap

`controller.keymap` is a PM-style binding from key spec to `EditorAction`. Defaults cover `Mod-b`, `Mod-i`, `Mod-e`, `Mod-]`, `Mod-[`. Rebind:

```swift
controller.keymap.bind("Mod-Shift-x", to: .strikethrough)
controller.keymap.unbind("Mod-e")
```

`KeySpec.make(key:mod:shift:alt:)` builds normalized specs. `Mod` resolves to Cmd on macOS and Ctrl elsewhere.

### Plugins

`EditorPlugin` is a PM-style plugin protocol for cross-cutting features:

```swift
final class WordCountPlugin: EditorPlugin {
    let key = AnyPluginKey(name: "wordCount")

    func appendTransaction(after tr: Transaction, controller: EditorController) -> Transaction? {
        // Recompute, log, post a notification, etc.
        return nil
    }
}

controller.register(plugin: WordCountPlugin())
```

`filterTransaction` vetoes a transaction; `appendTransaction` follows up. The `props: PluginProps` bag exposes `handleClick`, `handlePaste`, `handleDrop`, `handleKeyDown`, `handleTextInput` so a plugin can intercept input events. Per-plugin state lives behind `PluginKey<State>` via `controller.setPluginState(_:for:)` / `controller.pluginState(for:)`.

### Decorations

Structural chrome (blockquote bars, code-block backgrounds, HRs) comes from `DecorationProvider`s. The bundled `BlockSpecDecorationProvider` covers the defaults; `DecorationSet([...])` aggregates multiple providers so hosts can layer custom decorations.

### History

```swift
controller.historyConfig = HistoryConfig(depth: 200, newGroupDelay: 0.5)
```

`controller.undoDepth` / `redoDepth` are read-only counters. `controller.closeHistoryGroup()` opens a fresh undo group, matched by `meta["closeHistory"] = true` on transactions.

## UI integrations

Three optional surfaces hosts plug into for UX features ProseMirror editors take for granted: active toolbar state, a long-press hook for editing links inline, and inline completion suggestions.

### Active toolbar state

Toolbar buttons in the bundled `SwiftProseEditor` light up automatically — Bold appears pressed when the cursor is inside a strong span, the H1 button reads as active when the cursor's paragraph is an H1, and so on. Block-toggle commands (lists, blockquote, code block) follow the same rule.

If you build a custom toolbar, observe the same state from the controller:

```swift
@State private var controller: EditorController?
@State private var activeIDs: Set<String> = []

var body: some View {
    HStack {
        Button("Bold") { controller?.perform(.bold) }
            .tint(activeIDs.contains(EditorAction.bold.stableID) ? .accentColor : .primary)
        Button("H1") { controller?.perform(.heading(level: 1)) }
            .tint(activeIDs.contains(EditorAction.heading(level: 1).stableID) ? .accentColor : .primary)
    }
    SwiftProseEditor(text: $text)
        .onProseControllerReady { ctrl in
            controller = ctrl
            _ = ctrl.addOnSelectionChanged { _ in
                activeIDs = ctrl.activeActionIDs()
            }
            _ = ctrl.addOnDocumentChange { _, _ in
                activeIDs = ctrl.activeActionIDs()
            }
        }
}
```

API: `EditorController.isActionActive(_:)`, `EditorController.activeActionIDs()`. PM semantics — a mark is active when every character in the selection has it (or, on an empty selection, when the cursor sits at a stored mark or right after one).

## Selection

`controller.currentTypedSelection` returns a typed `Selection`:

- `.text(range, anchor, head)` — common cursor / range selection.
- `.node(path, range)` — single-node selection (PM's `NodeSelection`), used for atomic blocks like horizontal rules and images.
- `.all` — document-spanning selection.

A transaction's `selection` field installs the result on apply. Convenience constructors `Selection.cursor(at:)` and `Selection.textRange(_:)` cover the common cases.

## Observing changes

```swift
SwiftProseEditor(text: $text)
    .onProseControllerReady { controller in
        controller.onDocumentChange = { document, step in
            // Drive collab transport, mirror to a tree, etc.
        }
        controller.onDiagnostic = { diagnostic in
            // Block-level invariant violations (auto-repaired).
        }
        controller.onSchemaDiagnostic = { diagnostic in
            // Schema-level violations: unknown node/mark types,
            // content-rule mismatches, marks on disallowed parents.
        }
        controller.onSelectionChanged = { range in
            // Selection moved.
        }
    }
```

`onDocumentChange` fires after every character edit with the freshly-derived `ProseDocument` plus a `Step.replaceText` describing the edit. The single-callback properties coexist with multi-subscriber registration:

```swift
let token = controller.addOnDocumentChange { doc, step in /* ... */ }
controller.removeObserver(token)
```

`addOnDiagnostic(_:)` and `addOnSelectionChanged(_:)` follow the same pattern.

## ProseMirror JSON

```swift
try controller.loadProseMirrorJSON(json)
let exported = try controller.exportProseMirrorJSON()
```

`ProseMirrorCodec` round-trips the document with PM JSON: paragraphs, headings, lists (bullet / ordered / task), blockquotes, fenced & indented code blocks, horizontal rules, pipe tables (as `table → table_row → (table_cell | table_header)` with per-cell `align`). The encoder merges adjacent inline runs that share a mark set into a single PM `text` node, omits attrs whose value matches the schema default, and accepts an optional `markAliases` map (e.g. `["strike": "strikethrough"]`) for ecosystems with different naming. `SchemaMap` extends the inline mark surface for custom marks.

`Schema.defaultMarkdown` is a typed superset of `prosemirror-schema-basic` + `addListNodes`. Wire-format-load-bearing attributes track PM exactly — `ordered_list.order`, `code_block.params`, `image.{src,alt,title}` defaulting to `""`, `link.{href,title}` defaulting to `""`, `table_cell.colwidth` as `[Int]`. Marks are declared in PM-basic order: `[link, em, strong, code, strike]`.

Extensions over PM-basic (not part of the canonical wire format):

- `task_list` (block) and `list_item.checked` — checkbox lists. Encoded as a `bullet_list` with `[x] ` / `[ ] ` text prefix so vanilla PM consumers still render the items.
- `html_block` — passed through verbatim.
- `link_reference` — markdown reference-style link definitions, kept as their own structural block.
- `strike` mark — strikethrough.
- `table_*` — `prosemirror-tables`-shaped subtree with per-cell `align` / `colspan` / `rowspan` / `colwidth`.

Strict PM-basic interop should strip these extension nodes / marks before sending JSON over the wire.

## Schema and the typed model

Behind the rendered storage is a typed tree mirroring ProseMirror's data model. Most code never touches it — commands, input rules, and PM JSON go through it transparently. Reach for it when:

- Building a custom `Schema` with new node or mark types.
- Driving collab / OT / CRDT transports that need typed steps.
- Validating content against a stricter shape.

```swift
let document = controller.document        // typed ProseDocument mirror
let resolved = document.resolve(cursor)   // PM-style ResolvedPos
let marks = resolved?.marks() ?? MarkSet()
```

The model:

- **`Schema`** — set of `NodeType`s and `MarkType`s plus the top node. Headless callers convert PM JSON via `Schema.nodeFromJSON(_:)` / `Schema.markFromJSON(_:)` without pulling in the View layer.
- **`NodeType`** — declares content rules, attrs, and PM spec flags (`atomSpec`, `isCode`, `defining`, `selectable`, `draggable`, `linebreakReplacement`, `allowedMarks`). Factories `create(attrs:)` / `createChecked(attrs:)` / `createAndFill(attrs:)` fill schema defaults.
- **`MarkType`** — declares attrs, `excludes` set, `excludesAll` (PM `"_"`), `inclusive`. `MarkSet.adding(_:in:)` enforces excludes (e.g. adding `code` over a `strong em` span drops both).
- **`ContentExpression`** — content rules parse to a `ContentMatch` automaton with `matchType` / `matchFragment` / `validEnd` / `defaultType`, so multi-element rules like `paragraph block*` validate correctly.
- **`ProseDocument`** — typed tree whose nodes carry text and `MarkSet`s on inline runs. `document.resolve(_:)` returns a `ResolvedPos` exposing `depth`, `parent(at:)`, `node(at:)`, `index(at:)`, `start(at:)` / `end(at:)` / `before(at:)` / `after(at:)`, `textOffset`, `marks()`, `marksAcross(_:)`, `blockRange(_:pred:)`. `NodeRange` represents a contiguous child range under one parent.
- **`MarkSet`** — ordered, deduplicated marks with stable schema-ranked sorting.

### Steps and transforms

A `Step` is a typed, undoable edit:

| Step | What it does |
|---|---|
| `replaceText` | Character-range replacement (typing, paste, delete). |
| `setSpec` | Change a line's `BlockSpec` — turn a paragraph into a heading. |
| `toggleInlineMark` | Toggle bold / italic / strike / codeSpan over a range. |
| `replaceAround` | Wrap or unwrap content (e.g. blockquote in / out). |
| `addMark` / `removeMark` | Apply or strip a mark over a range. |
| `setNodeAttrs` / `setNodeAttrsAt` | Change a leaf's attrs by `NodePath` or position. |
| `addNodeMark` / `removeNodeMark` | Marks on leaf nodes (an image inside a link). |
| `setDocAttr` | Document-level attr change. |
| `replaceCellInline` / `setTableSubtree` | Table-cell edits. |

Each step's `apply` returns a typed inverse so undo / redo preserves `NodeID`s. `Step.canApply(to:)` probes legality without mutating storage; `Transaction.apply` skips illegal steps cleanly. `Step.merge(_:)` coalesces adjacent typing into one step (collab prerequisite).

Position mapping is preserved across transactions. `StepMap.mapResult(_:bias:)` returns a `MapResult { pos, deleted, deletedBefore, deletedAfter, deletedAcross }`. `Mapping` tracks mirror pairs (`appendMap(_:mirrors:)`, `getMirror(_:)`, `invert()`, `appendMappingInverted(_:)`).

The `Transforms` enum exposes the PM `Transform` vocabulary as functions returning Step lists — `lift`, `wrap`, `split`, `join`, `setBlockType`, `setNodeMarkup`, `clearIncompatible` — plus probes (`canSplit`, `canJoin`, `liftTarget`, `findWrapping`).

## Architecture

Four SPM targets in a strict dependency chain:

| Library | Role |
|---|---|
| `SwiftProseSyntax` | Pure Swift, no UI. Tree-sitter parsers, schema, document tree, classifiers, codecs. |
| `SwiftProseRendering` | `NSTextAttachment` subclasses (bullet glyphs, checkboxes, chips); custom `NSTextLayoutFragment`s for blockquote bars / code backgrounds / HR lines; platform aliases. |
| `SwiftProseView` | `EditorController` (TextKit-2 + parser + commands + undo); `MarkdownAttributedCompiler` and `MarkdownTreeSerializer`; `Step` / `Transaction` / `Command` / `InputRule`; `ProseMirrorCodec`; `ProseTheme`; the macOS / iOS text-view representable wrappers. |
| `SwiftProse` | `SwiftProseEditor` SwiftUI view, toolbar, status bar, configuration, environment-driven modifiers, and a `ProsePlayground` debug surface. Re-exports the lower three. |

The editor holds a single TextKit 2 stack — there's no separate model document. Markdown source is canonical; rich attributes are recomputed on top, and the typed `ProseDocument` tree is reverse-projected from storage on demand (cached on `controller.document`, invalidated by every storage edit).

## Examples

`Examples/SwiftProseDemo/` is a multi-platform DocumentGroup app that loads / saves `.md` files, wires up a SwiftUI toolbar, and registers four tree-sitter grammars (swift, javascript, css, html) for code-block highlighting:

```sh
open Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj
```

## Testing

Unit tests cover the parser, segmenter, classifier, schema, document tree, ProseMirror JSON, controller integration, every command and input rule, and undo / redo flows.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The CommandLineTools toolchain doesn't ship Swift Testing — point at the Xcode toolchain explicitly via `DEVELOPER_DIR`.

End-to-end UI tests live in `Examples/SwiftProseDemo/SwiftProseDemoUITests`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
  -scheme SwiftProseDemo \
  -destination 'platform=macOS'
```

## License

MPL 2.0.
