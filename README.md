# SwiftProse

A SwiftUI text editor for macOS and iOS, built on TextKit 2, tree-sitter and a ProseMirror-aligned document tree (schema, nodes, marks, steps), so transactions are typed and undoable and the editor round-trips with ProseMirror JSON.

## Markdown support

Markup renders as you type — `**bold**` becomes bold, headings size up, code spans switch to monospace, fenced code gets a tinted background and per-language tree-sitter highlighting, links collapse to their display text.  

## Requirements

- Swift 5.10+
- macOS 26+ / iOS 26+

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

`import SwiftProse` re-exports the three internal modules. The view is bound to a `String`; the editor parses, renders, and serializes the markdown for you on every change.

## Modules

| Library | Contents |
|---------|----------|
| `SwiftProseSyntax` | Pure Swift, no UI. Tree-sitter `MarkdownParser` (CommonMark + inline injection) with incremental edit replay; `BlockSegmenter`, `BlockClassifier`, `InlineClassifier`; `BlockSpec`; `Schema` / `NodeType` / `MarkType` / `ProseNode` / `ProseDocument`; `HighlightApplier` and the pluggable `CodeBlockHighlighter` (with `TreeSitterCodeBlockHighlighter`); `PipeTableModel`; `TreeSitterMapping` (UTF-16 ↔ byte). |
| `SwiftProseRendering` | `NSTextAttachment` subclasses (bullet glyphs, checkboxes, chips); custom `NSTextLayoutFragment`s for blockquote bars, fenced + indented code backgrounds, language tags, horizontal rules; platform aliases (`PlatformFont`, `PlatformColor`). |
| `SwiftProseView` | `EditorController` (TextKit-2 stack + parser + commands + undo); `MarkdownAttributedCompiler` and the tree-driven `MarkdownTreeSerializer`; `Step` / `Transaction` / `Command` / `InputRule` editing primitives; `ProseMirrorCodec`; `ProseTheme` with `CodePalette`; the macOS / iOS text-view representable wrappers. |
| `SwiftProse` | `SwiftProseEditor` SwiftUI view, toolbar, status bar, configuration, environment-driven modifiers, and a `ProsePlayground` debug surface. |

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

- **Toolbar** — pass `.action(...)`, `.divider`, `.spacer`, or `.custom(...)` items. The default toolbar covers bold / italic / strikethrough, H1-H3, lists, blockquote, code span / block, link, and horizontal rule.
- **Status bar** — `.words`, `.characters`, `.cursor` (line:column).
- **Sizing** — `.fitsContent` (height tracks content, starting from `minHeight`) or `.fillContainer` (fixed-height, scrolls internally).
- **Context menu** — append `ContextMenuItem`s to the platform's right-click / edit menu.
- **Spell / grammar / autocorrect** — `spellChecking:` accepts `.off`, `.spelling` (default — continuous underlines), `.spellingAndGrammar`, or `.full` (adds autocorrect). On macOS, code blocks and inline code spans are excluded automatically via the spell-check delegate; on iOS the toggle applies to the whole text view.

## Theming

```swift
let theme = ProseTheme.default(fontScale: 1.1)
SwiftProseEditor(text: $text)
    .theme(theme)
```

`ProseTheme` exposes body / monospace fonts, foreground / markup / link colors, blockquote bar, heading scale, and per-tag `CodePalette` colors for syntax-highlighted code blocks.

## Code-block syntax highlighting

Fenced code blocks render with a tinted background by default. To color the body via tree-sitter, register grammars on a `TreeSitterCodeBlockHighlighter` and pass it via `.codeBlockHighlighter(_:)`. Grammar packages aren't bundled with `SwiftProse` itself.

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

Bare fences (` ``` ` with no info string) trigger language detection: the body is parsed against each registered grammar and the one with the cleanest coverage (≥ 30% of source chars and ≥ 1.5× over the runner-up) wins. Ambiguous bodies stay uncolored. See `Examples/SwiftProseDemo/SwiftProseDemo/CodeHighlighters.swift` for a four-language registration (swift / js / css / html).

## Inline content (chips, mentions)

Map host-level rich content (`URL`, bug ID, user mention, etc.) to a `ProseInlineContent` and the editor draws it as a SwiftUI-styled chip. Useful for embedding non-markdown references inline without baking the host's domain types into the package.

```swift
SwiftProseEditor(text: $text)
    .inlineContentProvider { content in
        ChipAttachment.make(for: content)
    }
```

## ProseMirror-aligned document model

Behind the rendered storage is a typed tree mirroring ProseMirror's data model:

- **`Schema`** — the set of `NodeType`s and `MarkType`s, plus the top node. The default `Schema.defaultMarkdown` covers paragraph, heading, blockquote, lists (bullet / ordered / task), code blocks, horizontal rule, html block, link reference, table, and the marks `strong` / `em` / `code` / `link` / `strike`.
- **`NodeType`** — declares content rules, attrs, and PM spec flags (`atomSpec`, `isCode`, `defining`, `definingForContent`, `definingAsContext`, `selectable`, `draggable`, `linebreakReplacement`, `allowedMarks: AllowedMarks`). Factories `create(attrs:)` / `createChecked(attrs:)` / `createAndFill(attrs:)` fill schema defaults.
- **`MarkType`** — declares attrs, `excludes` set, `excludesAll` (PM `"_"`), `inclusive`. `MarkSet.adding(_:in:)` enforces excludes (e.g. adding `code` over `strong em` drops both). PM-style helpers: `mark.addToSet(_:in:)`, `mark.removeFromSet(_:)`, `mark.isInSet(_:)`.
- **`ContentExpression`** — content rules parse to a `ContentMatch` automaton with `matchType`, `matchFragment`, `validEnd`, `defaultType`, `edgeCount` so multi-element rules (`paragraph block*`, `(table_cell | table_header)+`) validate correctly.
- **`ProseNode`** — an instance of a `NodeType` with attrs and a stable `NodeID`.
- **`ProseDocument`** — a tree whose nodes carry text and `MarkSet`s on inline runs. `document.resolve(_:)` returns a `ResolvedPos` exposing `depth`, `parent(at:)`, `node(at:)`, `index(at:)`, `start(at:)` / `end(at:)` / `before(at:)` / `after(at:)`, `textOffset`, `marks()`, `marksAcross(_:)`, `blockRange(_:pred:)`. `NodeRange` represents a contiguous child range under one parent.
- **`MarkSet`** — ordered, deduplicated marks with stable schema-ranked sorting. `TreeNode.leaf` carries marks alongside its `ProseNode` so an image inside a link span keeps the link mark across encode / decode.

The compiler stamps the canonical `proseNodePath` and `proseMarks` attributes onto storage as it emits, and `ProseDocument.from(storage:schema:)` reverse-projects the tree on demand. `controller.document` returns the cached tree, invalidated by every storage edit. Headless callers can convert PM JSON without the View layer via `Schema.nodeFromJSON(_:)` / `Schema.markFromJSON(_:)` / `ProseAttrValue(pmValue:)` (`ProseAttrValue` and `PMValue` carry `.array` and `.object` cases for nested attrs).

## Editing primitives

The editor is built on three layered primitives in `SwiftProseView`:

- **`Operations`** — low-level `NSTextStorage` mutators (toggle bold / italic / strike / code, paragraph helpers, link insertion).
- **`Step`** — typed, undoable edits: `replaceText`, `setSpec`, `toggleInlineMark`, `replaceAround`, `addMark`, `removeMark`, `setNodeAttrs`. Each step's `apply` returns its inverse so undo / redo round-trips for free.
- **`Command`** — a registry-resolved unit that composes steps into a `Transaction` for an `EditorAction`. The default registry (`CommandRegistry.makeDefault()`) covers every action listed below.

`InputRule` runs the same machinery on typed text, matching against per-line patterns: `# `, `## ` … `###### ` for headings, `> ` for blockquotes, `- ` / `* ` / `+ ` for bullet lists, `1. ` for ordered lists, `- [ ] ` / `- [x] ` for task items, `---` for horizontal rules, ` ``` ` for fenced code blocks, and `**bold**` / `*italic*` / `~~strike~~` / `` `code` `` for inline marks. `InputRuleRunner.makeDefault()` ships the standard set.

```swift
let controller = try EditorController(initialMarkdown: "draft\n")
let lineRange = NSRange(location: 0, length: controller.textStorage.length)
controller.apply(Transaction(steps: [
    .setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 2)))
], label: "Promote to heading"))
// → "## draft\n"
```

## ProseMirror JSON round-trip

```swift
try controller.loadProseMirrorJSON(json)
let exported = try controller.exportProseMirrorJSON()
```

`ProseMirrorCodec` encodes the editor's tree into a structural ProseMirror document — paragraphs, headings, lists (bullet / ordered / task), blockquotes, fenced and indented code blocks, horizontal rules, and pipe tables (as `table → table_row → (table_cell | table_header)` with per-cell `align` attrs) — and decodes the inverse. `SchemaMap` extends the inline mark surface for custom marks.

### Schema posture

`Schema.defaultMarkdown` ships as a **typed superset** of `prosemirror-schema-basic` + `addListNodes`. Wire-format-load-bearing attributes track PM exactly (`ordered_list.order`, `code_block.params`, `image.{src,alt,title}` defaults of `""`, `link.{href,title}` defaults of `""`, `table_cell.colwidth` as `[Int]`); the codec omits attrs when their value matches the schema default. Marks are declared in PM-basic order: `[link, em, strong, code, strike]`.

The schema layers in extensions over PM-basic that are not part of the canonical wire format:

- `task_list` (block) and `list_item.checked` — checkbox lists. Encoded as a `bullet_list` with `[x] ` / `[ ] ` prefix on the first paragraph so a vanilla PM consumer still renders the items.
- `html_block` (block, plain text content) — passed through verbatim.
- `link_reference` (block, leaf with `label` / `href` / `title`) — markdown reference-style link definitions, kept as their own structural block.
- `strike` mark — strikethrough; not in PM-basic (a few PM ecosystems call it `strikethrough`).
- `table_*` — `prosemirror-tables`-shaped subtree (table → table_row → table_cell|table_header), with per-cell `align` / `colspan` / `rowspan` / `colwidth` attrs.

Hosts targeting strict PM-basic interop should strip these extension nodes / marks at the application layer before sending JSON over the wire.

## Observing the document

```swift
SwiftProseEditor(text: $text)
    .onProseControllerReady { controller in
        controller.onDocumentChange = { document, step in
            // Drive collaborative transport, mirror to a tree, etc.
        }
        controller.onDiagnostic = { diagnostic in
            // Spec-invariant violations the auto-repair pass caught.
        }
    }
```

`onProseControllerReady` hands back the live `EditorController` once the editor finishes setup, giving direct access to its commands, transactions, undo manager, and tree. `onDocumentChange` fires after every character edit with the freshly-derived `ProseDocument` plus a `Step.replaceText` describing the storage edit.

## Action set

`SwiftProseEditor.Action` covers the surfaces wired to commands, the toolbar, keyboard shortcuts, and the platform edit / context menus:

`bold`, `italic`, `strikethrough`, `heading(level:)`, `unorderedList`, `orderedList`, `taskList`, `blockquote`, `codeSpan`, `codeBlock`, `link(url:label:)`, `horizontalRule`, `indent`, `outdent`, `insertTable(rows:columns:)`, `insertTableRowAbove`, `insertTableRowBelow`, `insertTableColumnBefore`, `insertTableColumnAfter`, `deleteTableRow`, `deleteTableColumn`, `setTableColumnAlignment(_:)`.

## Examples

`Examples/SwiftProseDemo/` is a multi-platform DocumentGroup app that loads / saves `.md` files, wires up a SwiftUI toolbar, and registers four tree-sitter grammars (swift, javascript, css, html) for code-block highlighting. Open it with:

```sh
open Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj
```

## Testing

Unit tests cover the parser, segmenter, classifier, schema, document tree, ProseMirror JSON, the controller integration paths, every command and input rule, and undo / redo flows.

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
