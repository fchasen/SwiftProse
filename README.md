# SwiftProse

A SwiftUI live Markdown editor backed by TextKit 2 and tree-sitter. Bold becomes bold while you type, code spans get a monospace font, headings size up, links collapse to their display text, fenced code blocks render with a tinted background and per-language tree-sitter syntax highlighting, and GFM pipe tables paint as a structured grid — all rendered in the same `NSTextView` / `UITextView` the user is typing into.

## Modules

| Library | What it provides |
|---------|------------------|
| `SwiftProseSyntax` | Pure Swift, no UI. Tree-sitter `MarkdownParser` (CommonMark) with incremental edit replay, `BlockSegmenter` / `BlockClassifier`, the `BlockSpec` model + `proseBlockSpec` storage attribute, `HighlightApplier` (markdown highlight queries), `CodeBlockHighlighter` (pluggable per-language tree-sitter syntax highlighting), `PipeTableModel` (GFM pipe-table parser + mutation helpers), `ProseMirrorJSON` codec types, and `TreeSitterMapping` (UTF-16 ↔ tree-sitter byte coordinates). |
| `SwiftProseRendering` | `NSTextAttachment` subclasses (bullets, checkboxes, chips), inline content types, custom `NSTextLayoutFragment` implementations (blockquote bar, code-block background with full-container fill, fenced-code language tag, indented code, horizontal rule, pipe-table cells/borders), platform aliases. |
| `SwiftProseView` | `EditorController` (TextKit-2 stack + parser + highlighter + commands), `MarkdownAttributedCompiler` / `AttributedMarkdownSerializer`, `ProseMirrorCodec` (structural decode/encode for paragraphs, headings, lists, blockquotes, code blocks, tables), `Step` / `Transaction` / `Command` editing primitives, the table-edit and code-block commands, `ProseTheme` with `CodePalette` + `TablePalette`, and the macOS / iOS `NSTextView` / `UITextView` representable wrappers. |
| `SwiftProse` | The single `SwiftProseEditor` SwiftUI view plus toolbar, status bar, configuration, environment-driven modifiers (`.theme`, `.configuration`, `.inlineContentProvider`, `.codeBlockHighlighter`, `.onProseControllerReady`), the per-cell table edit sheet, and a `ProsePlayground` preview. |

`SwiftProse` re-exports the other three modules — `import SwiftProse` is enough.

## Requirements

- Swift 5.10+
- macOS 26+ / iOS 26+

## Quick start

```swift
import SwiftProse
import SwiftUI

struct DescriptionEditor: View {
    @State var text = ""

    var body: some View {
        SwiftProseEditor(text: $text)
            .frame(minHeight: 240)
    }
}
```

### Toolbar, status bar

```swift
SwiftProseEditor(text: $text)
    .configuration(.init(
        toolbar: SwiftProseEditor.Configuration.defaultToolbar,
        statusItems: [.words, .characters, .cursor]
    ))
    .frame(minHeight: 320)
```

### Inline content (chips, mentions, file links)

```swift
SwiftProseEditor(text: $text)
    .inlineContentProvider { content in
        ProseChip.attachment(for: content)
    }
```

### Code-block syntax highlighting

Fenced code blocks render with a rounded tinted background by default. To color the body via tree-sitter, register grammars on a `TreeSitterCodeBlockHighlighter` and pass it via `.codeBlockHighlighter(_:)`. The grammar packages aren't bundled with `SwiftProse` itself — register them in your app:

```swift
import SwiftProse
import SwiftTreeSitter
import TreeSitterSwift // SwiftPM dep on alex-pinkus/tree-sitter-swift

let highlighter = TreeSitterCodeBlockHighlighter()
let swiftQuery = try! Data(contentsOf: Bundle.main.url(
    forResource: "swift", withExtension: "scm", subdirectory: "queries")!)
try highlighter.register(
    language: "swift",
    language: Language(language: tree_sitter_swift()),
    queryData: swiftQuery
)

SwiftProseEditor(text: $text)
    .codeBlockHighlighter(highlighter)
```

When a fenced block has no info string (` ``` ` instead of ` ```swift`), the highlighter's `detectLanguage(for:)` parses the body with each registered grammar and picks the one with the cleanest coverage (≥ 30% of source chars and ≥ 1.5× over the runner-up); ambiguous bodies stay uncolored. See `Examples/SwiftProseDemo/SwiftProseDemo/CodeHighlighters.swift` for a working four-language registration (swift / js / css / html).

### Tables

GFM pipe tables render as a structured cell grid (alignment row hidden, header row tinted + bold, per-column alignment honored, stitched borders, full container width). The markdown source remains canonical — chrome paints on top.

| Action | What it does |
|--------|-------------|
| `.insertTable(rows:columns:)` | Insert a stub table at the cursor. |
| `.insertTableRowAbove` / `.insertTableRowBelow` | Add a body row relative to the cursor's row. |
| `.insertTableColumnBefore` / `.insertTableColumnAfter` | Add a column. |
| `.deleteTableRow` / `.deleteTableColumn` | Drop the cursor's row / column. |
| `.setTableColumnAlignment(_:)` | Set the column's alignment row token (`:---`, `---:`, `:---:`, `---`). |

A click on any rendered cell pops a SwiftUI sheet bound to that cell's text — saving dispatches a single-cell rewrite as one undoable `Step`. A toggle in the table's top-right corner flips the table to raw monospace source for hand-editing escape sequences or unusual structure the structural commands don't cover; flipping back re-parses with `PipeTableModel`. The ProseMirror codec encodes adjacent `.pipeTable` paragraphs into a structural `table → table_row → (table_cell | table_header)` PM tree (matching `prosemirror-tables`' shape, with per-cell `align` attrs) and decodes the inverse.

## Public API surface

### `SwiftProseEditor`

```swift
public struct SwiftProseEditor: View {
    public init(text: Binding<String>)
}
```

| Modifier | Purpose |
|----------|---------|
| `.theme(_:)` | A `ProseTheme` (body / mono fonts, foreground / markup / link colors, blockquote bar, `CodePalette` per-tag code colors, `TablePalette` for header tint / borders / toggle). |
| `.configuration(_:)` | Toolbar items, status items, sizing (`.fitsContent` / `.fillContainer`), `minHeight`, context-menu items. |
| `.inlineContentProvider(_:)` | Map a `ProseInlineContent` to an `NSTextAttachment`. |
| `.codeBlockHighlighter(_:)` | Inject a `CodeBlockHighlighter` (typically `TreeSitterCodeBlockHighlighter` with per-language registrations) so fenced code-block bodies syntax-highlight. |
| `.onProseControllerReady(_:)` | Receive the live `EditorController` for cursor-aware insertions and direct command dispatch. |

### Toolbar actions (`SwiftProseEditor.Action`)

`bold`, `italic`, `strikethrough`, `heading(level:)`, `unorderedList`, `orderedList`, `taskList`, `blockquote`, `codeSpan`, `codeBlock`, `link`, `horizontalRule`, `indent`, `outdent`, `insertTable(rows:columns:)`, `insertTableRowAbove`, `insertTableRowBelow`, `insertTableColumnBefore`, `insertTableColumnAfter`, `deleteTableRow`, `deleteTableColumn`, `setTableColumnAlignment(_:)`.

### Status items (`SwiftProseEditor.StatusItem`)

`words`, `characters`, `cursor`.

### Editing primitives

The editor is built on three layered primitives in `SwiftProseView`:

- **`Operations`** — low-level mutators on `NSTextStorage` (wrap, toggle bold/italic/strike/code, paragraph-range helpers).
- **`Step` / `Transaction`** — typed, undoable edits. Each `Step.apply` returns its inverse so undo/redo round-trips for free. New mutating behavior should compose `Step`s rather than mutate storage directly.
- **`Command`** — registered in `CommandRegistry`, resolved per `EditorAction`. Commands compose `Step`s into a `Transaction`. See `Sources/SwiftProseView/Commands/` for the built-in set.

Block-level helpers are exposed on `EditorController` (`canPerform(_:)`, `perform(_:)`, `applyTableCellEdit(...)`, `toggleTableExpansion(...)`).

### ProseMirror codec (`ProseMirrorCodec`)

Round-trips between the editor's `NSAttributedString` storage and a ProseMirror-style document tree. Encodes paragraphs, headings, lists (bullet / ordered / task), blockquotes, fenced and indented code blocks, horizontal rules, and pipe tables (as `table → table_row → table_cell | table_header` with per-cell `align` attrs). Decodes the inverse. `SchemaMap` extends the inline mark surface for custom marks (links, code, custom node types).

### Parser (`SwiftProseSyntax.MarkdownParser`)

```swift
public enum Grammar: Sendable { case block, inline }
public init(grammar: Grammar = .block) throws
public func parse(_ source: String) -> MutableTree?
public func applyEdit(replacing nsRange: NSRange, with replacement: String, newSource: String) -> [TSRange]
```

## Testing

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Three test targets: `SwiftProseSyntaxTests`, `SwiftProseViewTests`, `SwiftProseTests`. The CommandLineTools toolchain doesn't ship Swift Testing — point at the Xcode toolchain explicitly via `DEVELOPER_DIR`.

End-to-end UI tests live in `Examples/SwiftProseDemo/`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
  -scheme SwiftProseDemo -destination 'platform=macOS'
```

## License

MPL 2.0.
