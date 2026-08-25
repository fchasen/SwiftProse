# ``SwiftProse``

A rich-text Markdown editor for SwiftUI, built on TextKit 2 and modelled on ProseMirror.

## Overview

Drop ``SwiftProseEditor`` into a view, bind a `String` of Markdown, and you have
an editor that renders headings, lists, tables, and syntax-highlighted code
blocks as you type.

```swift
struct ContentView: View {
    @State private var text = "# Hello\n\nStart typing."

    var body: some View {
        SwiftProseEditor(text: $text)
    }
}
```

Everything past that is reached through the `EditorController`, which
``SwiftUICore/View/onProseControllerReady(_:)`` hands you when the editor
appears.

### How the document is stored

There is no separate model document. An `NSTextStorage` holds the rendered
text, and structure lives on it as attributes — `proseNodePath` (the chain of
structural ancestors for a character) and `proseMarks` (its inline marks). A
typed `ProseDocument` tree is projected from those attributes on demand.

Markdown is an interchange format, not the live state: it is parsed on load and
serialized on read.

### Positions are storage offsets

`document.resolve(controller.currentSelection.location)` is exact — no
conversion, no correction — and `document.contentLength` equals
`textStorage.length`. Structural nodes have no open/close tokens, presentation
markers (a bullet glyph, `"12. "`, a checkbox) count toward offsets but never
toward text, and attachment-backed nodes such as tables are opaque.

### Every edit is a transaction

Typing, commands, paste, and table-cell edits all produce typed `Step`s with
typed inverses, applied atomically as a `Transaction`. That is what makes undo
one mechanism rather than several, and what lets a collaborative-editing
transport see the same operations the editor applies.

### The layers below

`SwiftProse` re-exports three lower targets, so `import SwiftProse` is all an
app needs. Each has its own reference:

| Target | What lives there |
|---|---|
| `SwiftProseView` | `EditorController`, `Step`, `Transaction`, commands, input rules, plugins, the platform text views |
| `SwiftProseRendering` | `NSTextAttachment` subclasses and the custom layout fragments that draw blockquote bars, code backgrounds, and rules |
| `SwiftProseSyntax` | `Schema`, `ProseDocument`, `ResolvedPos`, the tree-sitter parsers, and the codecs |

Build one with
`SWIFTPROSE_DOCS=1 swift package generate-documentation --target SwiftProseView`.

## Topics

### Essentials

- ``SwiftProseEditor``
- ``SwiftProseEditor/Configuration``

### Toolbar, status bar, and menus

- ``SwiftProseEditor/ToolbarItem``
- ``SwiftProseEditor/StatusItem``
- ``SwiftProseEditor/ContextMenuItem``

### Inline completion

- ``ProseCompletionConfiguration``
- ``CompletionPlacement``
- ``CompletionPopupPlacement``

### Hosting

- ``ProseHosting``

### Trying things out

- ``ProsePlayground``

