# ``SwiftProseView``

The TextKit 2 editing core: the rich and source controllers, the handle that spans them, plugins and the platform text views.

## Overview

``EditorController`` owns the rich-mode stack: an `NSTextStorage` that holds the document, its content storage, layout manager and container, and an undo manager. It runs headless as well as hosted.

```swift
let controller = EditorController(markdown: "# Draft\n")
controller.setSelection(NSRange(location: 2, length: 5))
controller.perform(.bold)
let markdown = controller.markdown()
```

Every programmatic edit (``EditorController/perform(_:)``, ``EditorController/insertMarkdown(_:replacing:label:)``, ``EditorController/replaceText(in:with:label:)``) is one undo step. Typing goes through the host text view; the controller normalizes the edited paragraphs, restyles them, updates code highlighting and publishes a ``DocumentChange``.

``SourceEditorController`` owns the source-mode stack over the markdown text, with incremental line-based highlighting. ``EditorHandle`` holds both and forwards to whichever ``EditorMode`` is active. All three conform to ``ProseEditing``.

### Plugins

An ``EditorPlugin`` receives every ``DocumentChange`` and can intercept clicks, long presses, paste, key presses and text input through ``PluginProps``. ``CompletionPlugin``, ``AutoLinkPlugin`` and ``InternalLinkPlugin`` ship with the package.

### Text views

``ProseTextViewMac`` and ``ProseSourceTextViewMac`` host the controllers in an `NSTextView`; `ProseTextViewIOS` and `ProseSourceTextViewIOS` host them in a `UITextView`.

## Topics

### Rich mode

- ``EditorController``
- ``DocumentChange``
- ``Keymap``
- ``KeySpec``

### Source mode and modes

- ``SourceEditorController``
- ``EditorHandle``
- ``EditorMode``
- ``ProseEditing``

### Plugins

- ``EditorPlugin``
- ``PluginProps``
- ``PluginKey``
- ``AnyPluginKey``
- ``PluginKeyName``

### Completion

- ``CompletionPlugin``
- ``CompletionTrigger``
- ``CompletionContext``
- ``CompletionSession``

### Links

- ``AutoLinkPlugin``
- ``AutoLinkRule``
- ``AutoLinkMatch``
- ``InternalLinkPlugin``
- ``LinkTarget``

### Paste

- ``PasteEvent``
- ``PastedImage``

### Hosting

- ``ProseTextViewMac``
- ``ProseSourceTextViewMac``
- ``EditorSizing``
- ``ProseSpellChecking``
- ``ProseContextMenuItem``

### Layout

- ``LayoutManagerDelegate``
- ``MarkdownLayoutFragment``
- ``CodeBlockLayoutFragment``
- ``FencedCodeBlockLayoutFragment``
- ``TableRowLayoutFragment``
