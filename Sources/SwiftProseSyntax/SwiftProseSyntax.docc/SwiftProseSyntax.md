# ``SwiftProseSyntax``

The storage vocabulary, loader, reader and writer behind the editor, the source-mode formatter, and the code-highlighting contract. Usable without a view.

## Overview

``MarkdownLoader`` turns markdown into attributed storage. ``StorageReader`` reads storage into an ``EditorDocument`` tree, and ``MarkdownWriter`` writes either form back to markdown.

```swift
let storage = MarkdownLoader().load("# Title\n\n- item\n")
let document = StorageReader().document(from: storage)
let markdown = MarkdownWriter().write(document)
```

### The storage vocabulary

Loaded storage has one paragraph per block. Every character carries a ``MarkdownBlock`` under `NSAttributedString.Key.markdownBlock`: a leaf (paragraph, heading, code, thematic break, table row, HTML), its containers (quotes and list items), whether it continues a list item, and an optional ``TaskState``. Inline marks are ``MarkdownInlineIntent`` bits under `markdownInlineIntent`, links use `.link`, and escapes and entities keep their source under `markdownLiteral`. Images, HTML and inline-content chips are attachments conforming to ``ProseSourceAttachment``. Lists are `NSTextList`s on the paragraph style, and a ``GroupToken`` ties the lines of a code block, the rows of a table or the paragraphs of a blockquote together.

### Source mode

``MarkdownSourceFormatter`` applies an ``EditorAction`` to plain markdown text and returns a ``MarkdownSourceEdit``. It reports toolbar state from the text alone.

### Code highlighting

A ``CodeBlockHighlighter`` creates one ``CodeHighlightSession`` per code block. The session answers a full reset and each edit with ``CodeHighlightRun``s, which the editor paints.

## Topics

### Loading and writing

- ``MarkdownLoader``
- ``StorageReader``
- ``MarkdownWriter``
- ``DocumentWriter``
- ``EditorDocument``

### Storage vocabulary

- ``MarkdownBlock``
- ``GroupToken``
- ``TaskState``
- ``TableColumnAlignment``
- ``MarkdownInlineIntent``
- ``MarkdownBreak``
- ``MarkdownTableSeparator``
- ``MarkdownParagraph``

### Atoms and inline content

- ``ProseSourceAttachment``
- ``AtomKind``
- ``ProseInlineContent``
- ``InlineContentRule``
- ``InlineContentMatch``
- ``ProseInlineContentProvider``
- ``ChipAttachment``
- ``ChipTextAttachment``
- ``HorizontalRuleAttachment``
- ``HTMLBlockAttachment``

### Actions

- ``EditorAction``
- ``TableStructureModel``

### Source mode

- ``MarkdownSourceFormatter``
- ``MarkdownSourceEdit``

### Code highlighting

- ``CodeBlockHighlighter``
- ``CodeHighlightSession``
- ``CodeHighlightRun``
- ``CodeHighlightEdit``

### Platform

- ``PlatformFont``
- ``PlatformColor``
- ``PlatformFontDescriptor``
- ``PlatformImage``
- ``PlatformView``
- ``PlatformTextView``
- ``PlatformTextStorageEditActions``
- ``FontTraits``
