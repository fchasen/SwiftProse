# ``SwiftProseView``

The editor itself: the controller that owns the document, the typed edits that
change it, and the platform text views that host it.

## Overview

``EditorController`` owns an `NSTextStorage` and the TextKit 2 stack around it.
There is no separate model — the storage *is* the document, with structure
carried on it as attributes.

### Layers of editing

These nest; reach for the highest one that does the job.

| Layer | Use it for |
|---|---|
| ``Operations`` | Direct storage mutators. Building blocks; new behavior rarely belongs here. |
| ``Step`` | One typed, undoable edit. **New behavior should compose these.** |
| ``Transaction`` | An ordered list of steps applied atomically, as one undo entry. |
| ``Command`` | A named action resolved from an ``EditorAction``; what toolbars and menus dispatch. |
| ``InputRule`` | A regex that fires as you type and produces a transaction. |

### How an edit reaches the document

Everything the user does becomes a ``Transaction``, typing included. A keystroke
arrives at the storage, gets tagged with where it came from, is classified
(typing, deletion, autocorrect, paste, IME composition, dictation), normalized,
published, and registered for undo — in that order, once per edit group.

Because every edit carries a typed inverse, undo and redo are a single
mechanism, and identity-addressed edits such as a table-cell change reverse
correctly.

### Extending it

Register an ``EditorPlugin`` to veto transactions (`filterTransaction`), follow
up on them (`appendTransaction`), or intercept input events through
``PluginProps``. Per-plugin state lives behind a ``PluginKey``.

## Topics

### The controller

- ``EditorController``
- ``EditorAction``
- ``EditorSizing``
- ``ProseTheme``

### Typed edits

- ``Step``
- ``Transaction``
- ``AppliedStep``
- ``AppliedTransaction``
- ``StepEnvironment``
- ``Operations``

### Position mapping

- ``StepMap``
- ``Mapping``

### Selection and keys

- ``Selection``
- ``Keymap``
- ``KeySpec``

### Commands

- ``Command``
- ``CommandRegistry``
- ``ToggleMarkCommand``
- ``SetBlockTypeCommand``
- ``SetHeadingCommand``

### Input rules

- ``InputRule``
- ``InputRuleRunner``
- ``RuleOptions``

### Plugins

- ``EditorPlugin``
- ``PluginProps``
- ``PluginKey``
- ``AnyPluginKey``
- ``AutoLinkPlugin``
- ``CompletionPlugin``
- ``InternalLinkPlugin``

### Observing changes

- ``DocumentChange``
- ``SpecDiagnostic``
- ``SpecValidator``

### History

- ``HistoryConfig``

### Markdown and clipboard

- ``MarkdownAttributedCompiler``
- ``AttributedMarkdownSerializer``
- ``MarkdownTreeSerializer``
- ``ClipboardParser``
- ``ClipboardSerializer``
- ``PasteEvent``

### ProseMirror interchange

- ``ProseMirrorCodec``
- ``SchemaMap``
- ``DOMParser``
- ``DOMSerializer``

### Decorations and node views

- ``DecorationProvider``
- ``DecorationSet``
- ``Decoration``
- ``NodeViewProvider``
- ``NodeViewRegistry``

### Platform surfaces

macOS and iOS have separate representables — `ProseTextViewMac` and
`ProseTextViewIOS` — over one shared ``EditorController``. Only the one for
the platform you are building appears below.

- ``ProseTextViewMac``
- ``ProseSpellChecking``
