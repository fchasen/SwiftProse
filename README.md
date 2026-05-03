# Marginalia

A SwiftUI live Markdown / Phabricator-Remarkup editor backed by TextKit 2 and tree-sitter. Marginalia is the editor used inside Zilla for bug descriptions, comments, and revision replies.

Unlike WebKit-based editors, Marginalia renders inline formatting in the same `NSTextView` / `UITextView` the user is typing into — bold becomes bold while you type, code spans get a monospace font, headings size up, and link / image syntax collapses to its display text. There is no plain ↔ rendered mode switch (a separate `Preview` view is available, but the editor itself is always live).

## Modules

| Library | What it provides |
|---------|------------------|
| `MarginaliaSyntax` | Pure Swift, no UI. Tree-sitter `MarkdownParser` (CommonMark + Remarkup grammars), incremental edit replay, block classifier, hidden-range computer (the syntax characters Marginalia visually collapses), highlight tags / spans, list-marker editing, list continuation, and the typed editing operations (`bold`, `wrap`, `applyListMarker`, etc.). |
| `MarginaliaRendering` | Bullet and chip `NSTextAttachment` subclasses, inline content types, custom `NSTextLayoutFragment` implementations, platform aliases. |
| `MarginaliaView` | `EditorController` (the brains tying parser + highlighter + text view together), `Highlighter` (with `Dialect` / `Theme`), and the macOS / iOS `NSTextView` / `UITextView` representable wrappers. |
| `Marginalia` | The single `Marginalia` SwiftUI view plus toolbar, status bar, configuration, environment-driven modifiers (`.dialect`, `.theme`, `.previewRenderer`, `.inlineContentProvider`), and a `Playground` preview. |

## Requirements

- Swift 5.10+
- macOS 14.0+ / iOS 17.0+

## Installation

This package is consumed locally by Zilla via the Xcode project. From another Swift package:

```swift
dependencies: [
    .package(path: "Packages/Marginalia")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Marginalia", package: "Marginalia")
    ])
]
```

`Marginalia` re-exports `MarginaliaSyntax`, `MarginaliaRendering`, and `MarginaliaView`, so `import Marginalia` is normally enough.

## Quick start

### Plain editor

```swift
import Marginalia
import SwiftUI

struct DescriptionEditor: View {
    @State var text = ""
    @State var selection = NSRange(location: 0, length: 0)

    var body: some View {
        Marginalia(text: $text, selection: $selection)
            .frame(minHeight: 240)
    }
}
```

### Toolbar, status bar, preview

```swift
Marginalia(text: $text, selection: $selection)
    .configuration(.init(
        toolbar: Marginalia.Configuration.defaultToolbar,
        statusItems: [.words, .characters, .cursor, .dialect]
    ))
    .dialect(.commonMark)         // or .remarkup
    .defaultPreview()             // renders Markdown via AttributedString(markdown:)
    .frame(minHeight: 320)
```

`.defaultPreview()` is a convenience over `.previewRenderer { source, dialect in ... }` for callers that want a built-in renderer; pass any `@Sendable (String, Highlighter.Dialect) -> AttributedString` to plug in your own.

### Inline content (chips, mentions, file links)

```swift
Marginalia(text: $text, selection: $selection)
    .inlineContentProvider { content in
        // content is a MarginaliaInlineContent describing the matched
        // tree-sitter node (e.g. a `bug 123456` reference). Return an
        // NSTextAttachment to render in place — Marginalia keeps the
        // attachment glued to the underlying source range as the user types.
        MarginaliaChip.attachment(for: content)
    }
```

### Choose a dialect

```swift
.dialect(.commonMark)   // standard Markdown — used for Bugzilla comments
.dialect(.remarkup)     // Phabricator Remarkup — used for revision replies
```

The dialect controls which tree-sitter grammar parses the buffer (CommonMark via `tree-sitter-markdown`, Remarkup via the vendored `Vendor/tree-sitter-remarkup/`) and which highlight ruleset / hidden-range policy is applied.

## Public API surface

### `Marginalia`

```swift
public struct Marginalia: View {
    public init(text: Binding<String>, selection: Binding<NSRange> = ...)
}
```

| Modifier | Purpose |
|----------|---------|
| `.dialect(_:)` | `.commonMark` (default) or `.remarkup`. |
| `.theme(_:)` | A `MarginaliaTheme` (colors + fonts for token classes). |
| `.configuration(_:)` | Toolbar items, status items, sizing (`.fitsContent` / `.fillContainer`), `minHeight`, context-menu items. |
| `.inlineContentProvider(_:)` | Map a `MarginaliaInlineContent` to an `NSTextAttachment`. |
| `.previewRenderer(_:)` / `.defaultPreview(...)` | Provide a renderer for the preview pane that the toolbar's `.togglePreview` action toggles into. |

### Toolbar actions (`Marginalia.Action`)

`bold`, `italic`, `strikethrough`, `heading(level:)`, `unorderedList`, `orderedList`, `taskList`, `blockquote`, `codeSpan`, `codeBlock`, `link`, `horizontalRule`, `togglePreview`.

`Configuration.defaultToolbar` is a SimpleMDE-style preset; build your own with `Marginalia.ToolbarItem.action(_:)`, `.divider`, `.spacer`, or `.custom(id:label:systemImage:shortcut:topLevel:action:)`.

### Status items (`Marginalia.StatusItem`)

`words`, `characters`, `cursor`, `dialect`.

### Editing primitives (`MarginaliaSyntax.EditingOps`)

Pure functions over `(text, selection, …)` that return an `EditResult` (`text` + `selection`):

- `wrap(...)` — wrap the selection in markers (e.g. `**bold**`).
- `prefixLines(...)` — add/remove a per-line prefix (`> `, `- `, etc.).
- `numberedList(...)` — apply ordered-list markers.
- `wrapCodeBlock(...)` — wrap in fenced code.
- `applyListMarker(...)`, `switchListMarker(...)`, `indentListLines(...)`, `outdentListLines(...)` — list manipulation.
- `insertHorizontalRule(...)`.

These power the toolbar but are usable directly when wiring custom shortcuts or test-driving editor behavior.

### Parser (`MarginaliaSyntax.MarkdownParser`)

```swift
public enum Grammar: Sendable { /* commonMark, remarkup, ... */ }
public init(grammar: Grammar = .block) throws
public func parse(_ source: String) -> MutableTree?
public func applyEdit(replacing nsRange: NSRange, with replacement: String, newSource: String) -> [TSRange]
```

`applyEdit` returns the changed ranges so the highlighter can re-tag only the affected slices. Marginalia's `EditorController` calls this on every text-storage edit.

### Highlighter (`MarginaliaView.Highlighter`)

```swift
public enum Dialect: Sendable { case commonMark; case remarkup }
public init(dialect: Dialect, theme: MarginaliaTheme = .default) throws
```

Maps tree-sitter capture names to `HighlightTag`s and then to attribute dictionaries. Tag set covers `textTitle`, `textStrong`, `textEmphasis`, `textLiteral`, `textURI`, `textReference`, `punctuationSpecial`, `punctuationDelimiter`, `stringEscape`, and more.

## Vendored grammar

`Vendor/tree-sitter-remarkup/` contains a small custom tree-sitter grammar for Phabricator Remarkup (the generated `src/parser.c` is committed). To regenerate it after editing `grammar.js`:

```sh
./Tools/regenerate-tree-sitter-remarkup.sh
```

The script uses `npx tree-sitter-cli`; no global install required. The CommonMark grammar comes from the SwiftPM dependency [`tree-sitter-grammars/tree-sitter-markdown`](https://github.com/tree-sitter-grammars/tree-sitter-markdown).

## Testing

```sh
swift test --package-path Packages/Marginalia
```

Three test targets:

- `MarginaliaSyntaxTests` — parser, editing ops, list continuation, hidden-range computation, highlight application.
- `MarginaliaViewTests` — controller and highlighter behavior.
- `MarginaliaTests` — top-level integration smoke tests.

## License

MarginaliaEditor is released under the Mozilla Public License, v. 2.0. See <https://www.mozilla.org/MPL/2.0/> for the full text.
