# ``SwiftProseRendering``

The editor's theme and the value types its layout draws from.

## Overview

``ProseTheme`` sets the fonts, colours, heading scale, line height and insets for both modes, plus a style for each decorated construct: ``BlockquoteStyle`` for the quote bar, ``HorizontalRuleStyle`` for thematic breaks, ``CodeBlockStyle`` for the code band and language tag, ``ProseTheme/TablePalette`` for table rows and borders, and ``SourceStyle`` for source-mode syntax colours.

```swift
var theme = ProseTheme.default(fontScale: 1.1)
theme.blockquote.barColor = .systemTeal
theme.lineHeightMultiple = 1.2
```

``ListMarker`` and ``QuoteBar`` describe what the layout fragments draw beside a paragraph: a bullet, number or checkbox, and the bars of each enclosing blockquote. ``OrderedMarkerStyle`` picks decimal, lower-alpha or lower-roman numbering from list depth. ``CheckboxAttachment`` draws a task checkbox inline.

## Topics

### Theme

- ``ProseTheme``
- ``ProseTheme/TablePalette``
- ``BlockquoteStyle``
- ``HorizontalRuleStyle``
- ``CodeBlockStyle``
- ``SourceStyle``

### Markers and attachments

- ``ListMarker``
- ``OrderedMarkerStyle``
- ``QuoteBar``
- ``CheckboxAttachment``
