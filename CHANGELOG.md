# Changelog

## Unreleased

### Fixed: typing on macOS

Every keystroke in a hosted `NSTextView` threw
`NSInternalInconsistencyException` (“must begin a group before registering
undo”) and was dropped, so nothing appeared when typing. 0.1.0 overrode
`ProseNSTextView.undoManager` to return the controller's manager; AppKit's
typing-undo coalescer registers into whatever that property returns, and the
controller's manager has `groupsByEvent` off. The override is gone — with
`allowsUndo` off the property is nil, as intended — and the Edit menu's
`undo:` / `redo:` actions are routed to the controller instead.

AppKit also brackets each typed character with attribute writes, and the
envelope classifier counted every capture: real keystrokes classified as
`.bulk`, so input rules never fired and each character was its own undo
unit. Only character mutations count now.

`HostedTypingTests` types through `NSTextView.insertText` (the AppKit path)
rather than writing to storage, which is how both went unnoticed.

### Clipboard carries rendered text

Copy and cut put the text the editor shows on the pasteboard's plain-text
type — a bold word arrives as the word, a heading as its text, a bullet item
as `•` plus the item. It used to be markdown, so any plain-text consumer got
`**bold**` and `# Title`. Structure still travels in the HTML form
(`data-pm-slice`), which is what a paste back into SwiftProse reads.

`ClipboardSerializer.serializeForClipboard(...).text` is that rendered text;
`renderMarkdown(_:)` keeps the markdown form for hosts that want a
"copy as markdown" action. `PlainTextSerializer` is the new renderer.

## 0.1.0

First tagged release. Notable in this one is a rework of how edits reach the
document, and the performance that followed from it.

### Input goes through the transaction system

Typing used to bypass the typed-edit path entirely: the controller listened for
`NSTextStorage.didProcessEditingNotification` and reconstructed what had
happened after the fact. It now owns the storage.

- `ProseTextStorage` captures the pre-image of every mutation and tags it with
  an `EditOrigin` — platform, transaction, history, normalize, load.
- Platform edits are queued as envelopes, classified (typing, deletion,
  autocorrect, paste, IME composition, dictation, attribute-only), normalized,
  published, and registered for undo, once per edit group.
- The text-view delegates stamp a hint from the pre-edit selection; storage is
  the truth if the two disagree.

### One undo path

Every edit — typing, commands, paste, table-cell changes — registers typed
inverse `Step`s replayed with `Transaction.apply(..., sequential: true)`.

- **Table-cell edits are undoable.** They were a no-op: identity-addressed
  steps have no positional range, and the old undo captured a text snapshot of
  one.
- Typing coalesces on `historyConfig.newGroupDelay`, which is read for the
  first time. A burst also splits when the caret jumps somewhere non-adjacent.
- Undo restores the selection the edit started from; redo restores where it
  ended.

### Positions are storage offsets

`document.resolve(controller.currentSelection.location)` is exact, and
`document.contentLength == textStorage.length`. Presentation markers (a bullet
glyph, `"12. "`, a checkbox) count toward offsets but not toward text;
attachment-backed nodes such as tables are opaque. Each projected node records
this in `ProseNode.layout`.

### Structural invariants

`DocumentInvariants` runs over the structural run an edit landed in, not the
line:

- Ordered lists renumber after insert, delete, split, and multi-block deletion.
- List level never jumps more than one past the item above it.
- Blockquote depth stays continuous.

Deleting the first item of an ordered list used to split it into two lists,
both numbered from 1. Normalization no longer mints nodes where it can reuse
them, which is what caused that.

### Performance

Measured on a ~1200-block document (`Tests/SwiftProseViewTests/Benchmarks`):

| | before | after |
|---|---:|---:|
| keystroke | 2832–2875 µs | **86 µs** |
| transaction | 2708 µs | **225 µs** |
| keystroke, host reading `change.document` | 31355 µs | **391 µs** |

Every keystroke rebuilt a whole-document `[BlockSegment]` list, so cost tracked
block count rather than edit size. That list is derived on read now, and the
tree projection reuses everything an edit didn't touch.

### Removed

`Transforms` (7 of 12 functions were `return nil`), the ProseMirror command
stubs (all 14 returned nil, none had callers), `SpecValidator.repair`,
`MarkdownParser.applyEdit` / `.tree` / `.rootNode`, and
`TreeSitterMapping.makeInputEdit`.

### Breaking changes

For anyone who was tracking `main` before this tag, see **Upgrading** in the
README. The short version: `onDocumentChange` takes a `DocumentChange` instead
of `(ProseDocument, Step)`, raw writes to `controller.textStorage` are undoable
now, and tree positions no longer need a marker correction.
