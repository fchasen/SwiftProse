# ``SwiftProseSyntax``

The typed document model, the schema it conforms to, and the parsers that
produce it. Pure Swift — no UI.

## Overview

A ``ProseDocument`` is a tree of ``TreeNode``s mirroring ProseMirror's data
model, validated against a ``Schema``. Most code never touches it directly:
commands, input rules, and ProseMirror JSON all go through it transparently.
Reach for it when building a custom schema, driving a collaborative-editing
transport, or validating content against a stricter shape.

### Positions are storage offsets

`document.resolve(_:)` takes a raw `NSTextStorage` offset. Three rules make
that exact:

- Structural nodes have **openness 0** — unlike ProseMirror, entering and
  leaving a node costs nothing.
- **Presentation markers** — a bullet glyph and its tab, `"12. "`, a task
  checkbox — count toward offsets but never toward text.
- **Attachment-backed nodes** such as tables are opaque; their content lives
  off-buffer.

Each node projected from storage records these facts in ``StorageLayout``, a
side channel excluded from equality, hashing, and the codecs.

### Structure as attributes

Two attributes on the storage are canonical: `proseNodePath` (a ``NodePath``,
the chain of structural ancestors for a character, carrying ``NodeID``
identity) and `proseMarks` (a ``MarkSet``). ``BlockSpec`` is a flat projection
of a node path, convenient for line-level work.

## Topics

### The document tree

- ``ProseDocument``
- ``TreeNode``
- ``ProseNode``
- ``NodeID``
- ``Fragment``
- ``Slice``

### Positions

- ``ResolvedPos``
- ``NodeRange``
- ``StorageLayout``

### Schema

- ``Schema``
- ``NodeType``
- ``MarkType``
- ``ContentExpression``
- ``ContentMatch``
- ``AllowedMarks``
- ``AttrSpec``
- ``NodeTypeAttrError``

### Marks

- ``ProseMark``
- ``MarkSet``
- ``MarkSetBox``

### Structure on storage

- ``NodePath``
- ``NodePathBox``
- ``BlockSpec``
- ``BlockKind``
- ``BlockSegment``
- ``BlockSegmenter``
- ``BlockClassifier``

### Validation

- ``SchemaValidator``
- ``SchemaDiagnostic``

### Parsing and highlighting

- ``MarkdownParser``
- ``TreeSitterMapping``
- ``HighlightApplier``
- ``HighlightSpan``
- ``CodeBlockHighlighter``
- ``TreeSitterCodeBlockHighlighter``

### ProseMirror JSON

- ``PMNode``
- ``PMMark``
