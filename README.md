# SwiftProse

A SwiftUI live Markdown editor backed by TextKit 2 and tree-sitter. Bold becomes bold while you type, code spans get a monospace font, headings size up, and link / image syntax collapses to its display text — all rendered in the same `NSTextView` / `UITextView` the user is typing into.

## Modules

| Library | What it provides |
|---------|------------------|
| `SwiftProseSyntax` | Pure Swift, no UI. Tree-sitter `MarkdownParser` (CommonMark), incremental edit replay, block classifier, hidden-range computer, highlight tags / spans, list-marker editing, list continuation, and the typed editing operations (`bold`, `wrap`, `applyListMarker`, etc.). |
| `SwiftProseRendering` | Bullet and chip `NSTextAttachment` subclasses, inline content types, custom `NSTextLayoutFragment` implementations, platform aliases. |
| `SwiftProseView` | `EditorController` (parser + highlighter + text view), `ProseTheme`, the macOS / iOS `NSTextView` / `UITextView` representable wrappers, and the `Step` / `Transaction` editing primitives. |
| `SwiftProse` | The single `SwiftProseEditor` SwiftUI view plus toolbar, status bar, configuration, environment-driven modifiers (`.theme`, `.configuration`, `.inlineContentProvider`, `.onProseControllerReady`), and a `ProsePlayground` preview. |

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

## Public API surface

### `SwiftProseEditor`

```swift
public struct SwiftProseEditor: View {
    public init(text: Binding<String>)
}
```

| Modifier | Purpose |
|----------|---------|
| `.theme(_:)` | A `ProseTheme` (colors + fonts for token classes). |
| `.configuration(_:)` | Toolbar items, status items, sizing (`.fitsContent` / `.fillContainer`), `minHeight`, context-menu items. |
| `.inlineContentProvider(_:)` | Map a `ProseInlineContent` to an `NSTextAttachment`. |
| `.onProseControllerReady(_:)` | Receive the live `EditorController` for cursor-aware insertions. |

### Toolbar actions (`SwiftProseEditor.Action`)

`bold`, `italic`, `strikethrough`, `heading(level:)`, `unorderedList`, `orderedList`, `taskList`, `blockquote`, `codeSpan`, `codeBlock`, `link`, `horizontalRule`, `indent`, `outdent`.

### Status items (`SwiftProseEditor.StatusItem`)

`words`, `characters`, `cursor`.

### Editing primitives (`SwiftProseSyntax.EditingOps`)

Pure functions over `(text, selection, …)` returning an `EditResult`:

- `wrap(...)` — wrap the selection in markers (e.g. `**bold**`).
- `prefixLines(...)` — add/remove a per-line prefix (`> `, `- `, etc.).
- `numberedList(...)` — apply ordered-list markers.
- `wrapCodeBlock(...)` — wrap in fenced code.
- `applyListMarker(...)`, `switchListMarker(...)`, `indentListLines(...)`, `outdentListLines(...)`.
- `insertHorizontalRule(...)`.

### Parser (`SwiftProseSyntax.MarkdownParser`)

```swift
public enum Grammar: Sendable { case block, inline }
public init(grammar: Grammar = .block) throws
public func parse(_ source: String) -> MutableTree?
public func applyEdit(replacing nsRange: NSRange, with replacement: String, newSource: String) -> [TSRange]
```

## Testing

```sh
swift test
```

Three test targets: `SwiftProseSyntaxTests`, `SwiftProseViewTests`, `SwiftProseTests`.

## License

MPL 2.0.
