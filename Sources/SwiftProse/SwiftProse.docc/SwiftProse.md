# ``SwiftProse``

A markdown editor for SwiftUI on macOS and iOS, built on TextKit 2, with a rich mode and a source mode.

## Overview

Bind a `String` of markdown to ``SwiftProseEditor`` and the editor renders headings, lists, blockquotes, tables and code blocks as you type. The toolbar's mode toggle switches to source mode, which edits the markdown text directly.

```swift
struct ContentView: View {
    @State private var text = "# Hello\n\nStart typing."

    var body: some View {
        SwiftProseEditor(text: $text)
            .configuration(.init(statusItems: [.words, .cursor]))
    }
}
```

Modifiers configure the editor through the environment: ``SwiftUICore/View/theme(_:)``, ``SwiftUICore/View/configuration(_:)``, ``SwiftUICore/View/editable(_:)``, ``SwiftUICore/View/editorMode(_:)``, ``SwiftUICore/View/inlineContentRules(_:)``, ``SwiftUICore/View/inlineContentProvider(_:)`` and ``SwiftUICore/View/codeBlockHighlighter(_:)``.

Two callbacks hand over the objects behind the view. ``SwiftUICore/View/onProseControllerReady(_:)`` passes the rich-mode `EditorController`, for registering plugins and driving edits. ``SwiftUICore/View/onProseHandleReady(_:)`` passes the `EditorHandle`, which edits whichever mode is active.

### How the document is stored

In rich mode an `NSTextStorage` holds the rendered text, one paragraph per block. Structure lives on it as attributes: a `MarkdownBlock` on every character, inline marks as presentation-intent bits, escapes as literals, images and chips as attachments, lists as `NSTextList`s. Markdown text exists where the document is loaded and written. A document left unedited writes back its original bytes.

### The layers below

`SwiftProse` re-exports three targets, so `import SwiftProse` is all an app needs. Each has its own reference:

| Target | What lives there |
|---|---|
| `SwiftProseView` | `EditorController`, `SourceEditorController`, `EditorHandle`, plugins, the platform text views |
| `SwiftProseRendering` | `ProseTheme`, its styles, the checkbox attachment and marker types |
| `SwiftProseSyntax` | the storage vocabulary, `MarkdownLoader`, `StorageReader`, `MarkdownWriter`, `EditorDocument`, `MarkdownSourceFormatter`, the highlighter contract |

The optional `SwiftProseTreeSitter` product adds a tree-sitter code highlighter.

## Topics

### Essentials

- ``SwiftProseEditor``
- ``SwiftProseEditor/Configuration``

### Configuring the editor

- ``SwiftUICore/View/configuration(_:)``
- ``SwiftUICore/View/theme(_:)``
- ``SwiftUICore/View/editable(_:)``
- ``SwiftUICore/View/editorMode(_:)``
- ``SwiftUICore/View/inlineContentRules(_:)``
- ``SwiftUICore/View/inlineContentProvider(_:)``
- ``SwiftUICore/View/codeBlockHighlighter(_:)``

### Reaching the controller

- ``SwiftUICore/View/onProseControllerReady(_:)``
- ``SwiftUICore/View/onProseHandleReady(_:)``

### Toolbar, status bar, and menus

- ``SwiftProseEditor/ToolbarItem``
- ``SwiftProseEditor/MenuEntry``
- ``SwiftProseEditor/StatusItem``
- ``SwiftProseEditor/ContextMenuItem``
- ``ProseToolbar``

### Tables

- ``TableStructureEditor``

### Inline completion

- ``SwiftUICore/View/proseCompletions(_:)``
- ``ProseCompletionConfiguration``
- ``CompletionPopupPlacement``

### Trying things out

- ``ProsePlayground``
