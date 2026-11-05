# ``SwiftProseTreeSitter``

A tree-sitter implementation of the editor's code-highlighting contract, with language detection.

## Overview

``TreeSitterCodeBlockHighlighter`` conforms to `CodeBlockHighlighter`. Register a grammar and its highlights query for each language, then hand the highlighter to the editor:

```swift
import SwiftProse
import SwiftProseTreeSitter
import SwiftTreeSitter
import TreeSitterSwift

let highlighter = TreeSitterCodeBlockHighlighter()
try highlighter.register(
    language: "swift",
    language: Language(language: tree_sitter_swift()),
    queryData: swiftHighlightsQuery
)

SwiftProseEditor(text: $text)
    .codeBlockHighlighter(highlighter)
```

The host app depends on each `tree-sitter-<lang>` grammar package it wants. Token colours come from the ``CodePalette`` passed to ``TreeSitterCodeBlockHighlighter/init(palette:)``.

### Sessions

``TreeSitterCodeBlockHighlighter/makeSession(language:body:)`` returns one session per code block. The session parses the body on reset and on each edit, maps highlight captures to palette colours, and returns the runs for the editor to paint. A block whose language is unregistered gets `nil` and stays uncoloured.

### Language detection

A fence with no info string passes `nil` as the language, and the highlighter calls ``TreeSitterCodeBlockHighlighter/detectLanguage(for:)``. Each registered grammar parses the body; the one whose highlights cover at least 30% of the source characters and at least 1.5 times the runner-up's coverage wins. An ambiguous body stays uncoloured.

## Topics

### Highlighter

- ``TreeSitterCodeBlockHighlighter``
- ``CodePalette``
