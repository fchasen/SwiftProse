# SwiftProse

A markdown editor for SwiftUI on macOS and iOS, built on TextKit 2, with two editing modes. Rich mode renders the document as you type: the text storage holds the rendered text plus semantic attributes, and markdown syntax exists only where the document is loaded and written. Source mode edits the markdown text directly with incremental syntax highlighting. A document that is loaded and left unedited writes back its original bytes, including across a rich → source → rich switch. The core depends only on Apple frameworks.

## What you get

- **Rich editing.** Bold, italic, strikethrough, inline code and links render in place; headings size up, lists show bullets, numbers and clickable checkboxes, blockquotes draw a bar, code blocks get a tinted band.
- **Block kinds.** Paragraphs, headings (H1–H6), bullet / ordered / task lists, nested lists and multi-paragraph list items, blockquotes, fenced and indented code blocks, thematic breaks, GFM pipe tables, HTML blocks, images.
- **Source mode.** The same document as markdown text, with line-based incremental highlighting, the same toolbar and the same keyboard shortcuts.
- **Tables edited in place.** Cells are ordinary text, so marks, links and inline-content chips work inside them.
- **Byte-faithful round trips.** Untouched content keeps its exact source bytes; edited content is written in a canonical form.
- **Inline content.** Regex rules collapse source tokens such as `@name` or `{T123}` into atomic chips that keep their source.
- **Plugins.** Completion popups, autolinking, internal link handling, and hooks for clicks, paste, keys and text input.
- **Code highlighting.** A session-based highlighter contract; the optional `SwiftProseTreeSitter` product supplies a tree-sitter implementation with language detection.
- **Toolbar and status bar.** A SwiftUI toolbar for both modes, a table menu, a mode toggle, and word / character / cursor counts.
- **Spell, grammar, autocorrect.** Configured separately for each mode.

## Requirements

- Swift 5.10+ (Xcode 26)
- macOS 26 / iOS 26 (SDK 26)

## Install

Add SwiftProse to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/SwiftProse", branch: "main")
]
```

Add the product to the target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "SwiftProse", package: "SwiftProse"),
    // optional: tree-sitter code highlighting
    .product(name: "SwiftProseTreeSitter", package: "SwiftProse"),
])
```

`import SwiftProse` is enough for the editor; it re-exports `SwiftProseSyntax`, `SwiftProseRendering` and `SwiftProseView`. The `SwiftProseSyntax` product on its own gives headless loading and writing.

SwiftPM resolves `swift-tree-sitter` for every package that depends on SwiftProse. It links only into targets that use the `SwiftProseTreeSitter` product.

## Quick start

```swift
import SwiftProse
import SwiftUI

struct CommentEditor: View {
    @State private var markdown = "# Hello\n\nType into **me**.\n"

    var body: some View {
        SwiftProseEditor(text: $markdown)
            .frame(minHeight: 240)
    }
}
```

`SwiftProseEditor(text:)` binds to a markdown string. In rich mode, edits push `controller.markdown()` into the binding 80 ms after the last change, and at once when the text view ends editing, when `onSubmit` fires, on a switch to source mode, when the view is torn down, and when the app terminates (macOS) or enters the background (iOS). Source mode pushes after every edit. `controller.markdown()` and `EditorHandle.markdown()` return the current text between pushes. An external write to the binding (opening a different file, say) replaces the editor contents and drops any pending push.

In rich mode the editor hosts an `NSTextView` on macOS (`ProseTextViewMac`) and a `UITextView` on iOS (`ProseTextViewIOS`); source mode hosts `ProseSourceTextViewMac` and `ProseSourceTextViewIOS`. All four representables are public for hosts that embed the views directly.

## Configuration

```swift
SwiftProseEditor(text: $markdown)
    .configuration(.init(
        toolbar: SwiftProseEditor.Configuration.defaultToolbar
            .replacing(.link, with: .custom(id: "insertLink", label: "Link", systemImage: "link") {
                showLinkSheet = true
            }),
        statusItems: [.words, .characters, .cursor],
        sizing: .fitsContent,
        minHeight: 120,
        toolbarPadding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
    ))
```

- **`toolbar`** — `.action(EditorAction)`, `.divider`, `.spacer`, `.custom(...)`, `.menu(...)` and `.modeToggle`. An empty array hides the toolbar. The default toolbar covers marks, H1–H3, lists, blockquote, code span and block, link and thematic break, then `SwiftProseEditor.tableMenu`, a `.spacer` and `.modeToggle`. Leave `.modeToggle` out to remove the mode switch.
- **Menus** — `MenuEntry(editorAction:)` performs that action in whichever mode is active, and the menu lists only the entries that apply at the caret. Hosts that render items themselves call `resolvingEditorActions(isAvailable:perform:)` on the item array. On iOS, `topLevel: true` hoists an item out of the edit menu's Format submenu.
- **`statusItems`** — `.words`, `.characters`, `.cursor` (line:column), shown in the header row beside the toolbar.
- **`toolbarPadding`** — insets around the toolbar row.
- **`sizing`** — `.fitsContent` (height tracks content from `minHeight`) or `.fillContainer` (fixed height, scrolls internally).
- **`contextMenuItems`** — items appended to the platform edit menu.
- **`spellChecking`** — `.off`, `.spelling`, `.spellingAndGrammar` or `.full` (default) in rich mode. Code blocks and inline code are excluded on macOS.
- **`sourceSpellChecking`** — the same setting for source mode. It defaults to `spellChecking` with autocorrection removed, so `.full` becomes `.spellingAndGrammar`.
- **`isEditable`** — `false` (or `.editable(false)`) makes the editor read-only and greys the toolbar out in place. `.disabled(true)` from the environment also makes it read-only. Set `allowsCheckboxToggle: true` to keep task checkboxes interactive in a read-only editor.
- **`onSubmit`** — when set, Return calls it and Shift-Return inserts a line break, for comment-style editors.

`ProseToolbar` renders the same toolbar over any text surface. It takes the item array plus `perform`, `canPerform`, `isActive`, `isEnabled` and, for the mode toggle, `mode` and `onToggleMode`. `Keymap.keyboardShortcut(for:)` and `Keymap.action(for:command:shift:option:)` map keymap bindings to SwiftUI shortcuts and key events.

## Theming

```swift
SwiftProseEditor(text: $markdown)
    .theme(ProseTheme.default(fontScale: 1.1))
```

`ProseTheme` holds the body and monospace fonts, foreground and link colours, heading scale, weights or explicit fonts, line height, text container inset, and the styles for blockquotes (`BlockquoteStyle`), thematic breaks (`HorizontalRuleStyle`), code blocks (`CodeBlockStyle`), tables (`ProseTheme.TablePalette`) and source mode (`SourceStyle`). Code token colours belong to the highlighter.

## Modes

```swift
@AppStorage("editor.mode") private var mode: EditorMode = .rich

SwiftProseEditor(text: $markdown)
    .editorMode($mode)
```

`EditorMode` is `.rich` or `.source`. With `.editorMode(_:)` the host owns the mode; without it the editor keeps its own. The `.modeToggle` toolbar item and the iOS edit menu switch modes, and the toggle shows the mode it switches to (`SwiftProseEditor.modeToggleTitle(for:)`, `modeToggleSystemImage(for:)`).

On a switch the rich document's `markdown()` loads into source mode, and edited source text loads into rich mode through `setMarkdown(_:)`. Untouched content keeps its original bytes in both directions. Each mode keeps its own undo history; a switch that changes the text adds one undo step to the mode being entered, which restores its text from before the switch. The selection carries across the switch, mapped between rendered text and markdown source.

## Source mode

`SourceEditorController` owns the source text storage, selection, undo manager and TextKit 2 stack. `perform(_:)`, `canPerform(_:)`, `isActive(_:)` and `actionStates(for:)` run `MarkdownSourceFormatter` against the text, and `apply(_:label:)` applies any `MarkdownSourceEdit`. Every programmatic edit is one undo step. Source mode renders in the theme's `monospaceFont`, handles `Keymap` shortcuts, and pastes and copies plain text.

Highlighting is line based and incremental. Each line records the block state it ends in (open fence, HTML block, paragraph, table, list, open code span) and the container it sits in (quote depth, list content column). An edit restyles the edited lines and continues forward while a line's end state differs from its previous one, so opening or closing a fence restyles exactly the lines that enter or leave the block. Colours come from `ProseTheme.source`.

`MarkdownSourceFormatter` is a value type in `SwiftProseSyntax` and works on any string:

```swift
let formatter = MarkdownSourceFormatter()
if let edit = formatter.edit(for: .bold, in: text, selection: selection) {
    text = edit.applied(to: text)
    selection = edit.selection
}
```

Ranges are UTF-16 offsets, matching `NSString`, `NSTextView` and `UITextView`. Inline marks toggle delimiters around the selection, block actions rewrite line prefixes, and `insertTable(rows:columns:)` writes an empty pipe-table skeleton.

## Tables

GFM pipe tables are edited in place. Each row is a paragraph whose `MarkdownBlock` leaf is `.tableRow(group:alignments:isHeader:)`; cells are inline text separated by tab characters carrying `.markdownTableSeparator`. Rows of one table share tab stops measured from their cells.

- Tab and Shift-Tab move between cells; Tab in the last cell adds a row.
- Return moves to the same column in the next row and adds a row at the end; Return in an empty last row leaves the table.
- Backspace and forward delete step over separators, deleting a selection clears the covered cells, and pasted line breaks become spaces. A markdown table pasted at a paragraph boundary becomes a table.

Structural changes are `EditorAction`s, each one undo step: `insertTable(rows:columns:)`, `insertTableRowAbove`, `insertTableRowBelow`, `insertTableColumnBefore`, `insertTableColumnAfter`, `deleteTableRow`, `deleteTableColumn`, `setTableColumnAlignment(_:)`, `deleteTable` and `editTableStructure`. `editTableStructure` hands a `TableStructureModel` to `onEditTableStructure`; `SwiftProseEditor` presents it in the `TableStructureEditor` sheet and commits it with `applyTableStructure(_:)`, which keeps the content of every surviving cell.

SwiftUI declares its own `TableColumnAlignment`. A file that imports both SwiftUI and SwiftProse writes `SwiftProseSyntax.TableColumnAlignment`.

## Code-block highlighting

Code blocks render with a tinted band. To colour their bodies, pass a `CodeBlockHighlighter` with `.codeBlockHighlighter(_:)`. The optional `SwiftProseTreeSitter` product provides one:

```swift
import SwiftProse
import SwiftProseTreeSitter
import SwiftTreeSitter
import TreeSitterSwift

let highlighter = TreeSitterCodeBlockHighlighter()   // palette: .default
let queryData = try Data(contentsOf: Bundle.main.url(
    forResource: "swift", withExtension: "scm", subdirectory: "queries")!)
try highlighter.register(
    language: "swift",
    language: Language(language: tree_sitter_swift()),
    queryData: queryData
)

SwiftProseEditor(text: $markdown)
    .codeBlockHighlighter(highlighter)
```

The host app adds the `tree-sitter-<lang>` grammar packages it wants and registers each one. `TreeSitterCodeBlockHighlighter(palette:)` takes a `CodePalette` of token colours; `registeredLanguages` lists what is registered. A fence with no info string runs `detectLanguage(for:)`: the body is parsed with every registered grammar, and the one that covers at least 30% of the source and at least 1.5× the runner-up wins. An ambiguous body stays uncoloured. `Examples/SwiftProseDemo/SwiftProseDemo/CodeHighlighters.swift` registers four languages.

Any type can implement the contract. `makeSession(language:body:)` returns a `CodeHighlightSession` for one code block (or `nil` to leave it uncoloured); the editor calls `reset(body:)` for the full body and `didEdit(replacedRange:replacement:body:)` for each edit inside it, and paints the `CodeHighlightRun`s each returns. A changed info string starts a new session. Both modes share the highlighter.

## Inline content

Inline content rules collapse a source pattern into a single atom. The atom keeps its source bytes, so writing reproduces the original text exactly.

```swift
let ticket = InlineContentRule(id: "ticket", pattern: #"\{T(\d+)\}"#) { match in
    .custom(kind: "ticket", label: "T\(match.capture(1) ?? "")", systemImage: "ticket")
}

SwiftProseEditor(text: $markdown)
    .inlineContentRules([ticket])
    .inlineContentProvider { content in ChipAttachment.make(for: content) }
```

`ProseInlineContent` cases are `.url(_:label:)`, `.userMention(handle:displayName:)` and `.custom(kind:label:systemImage:)`. `ChipAttachment` draws a rounded label chip; any `NSTextAttachment` conforming to `ProseSourceAttachment` works as a provider result. `controller.inlineContentKind(at:)` reports the kind of the atom at an offset.

## Handle

`EditorHandle` acts on whichever mode is active, so a host toolbar item works the same in both modes. `.onProseHandleReady(_:)` hands it over.

- `selection`, `setSelection(_:)`, `markdown()`, `caretRect()`, `rect(forCharacterAt:)`, `hostTextView`
- `insertMarkdown(_:replacing:label:)`, `replaceText(in:with:label:)`, `insertLink(label:url:)`, `insertInlineContent(_:markdownSource:replacing:trailingText:label:)`
- `insertMarkdownAtLineStart(_:replacingLeading:label:)` inserts after the line's block prefix and replaces a leading token matched by an `InlineContentRule`
- `perform(_:)`, `canPerform(_:)`, `isActive(_:)`, `focus()`, `isFocused`
- `richController`, `sourceController`, `mode`, `activeEditor`

In rich mode these delegate to `EditorController`; in source mode they edit the markdown text, and inline content inserts its `markdownSource`. Both controllers and the handle conform to `ProseEditing`.

## Controller

`EditorController` owns the rich-mode TextKit 2 stack (`textStorage`, `textContentStorage`, `textLayoutManager`, `textContainer`). `.onProseControllerReady(_:)` hands it over; it also works headless.

```swift
let controller = EditorController(markdown: "# Draft\n")
controller.setSelection(NSRange(location: 2, length: 5))
controller.perform(.bold)
controller.markdown()   // "# **Draft**\n"
```

- `markdown()` and `setMarkdown(_:)`
- `perform(_:)`, `canPerform(_:)`, `isActive(_:)` and `activeActionIDs()` for `EditorAction`s
- `insertMarkdown(_:replacing:label:)`, `replaceText(in:with:label:)`, `insertLink(label:url:)`, `setLink(_:in:label:)`, `insertInlineContent(_:markdownSource:replacing:trailingText:label:)`
- `toggleCheckbox(at:)`, `tableStructure()`, `applyTableStructure(_:)`
- `currentSelection`, `setSelection(_:)`, `caretRect()`, `rect(forCharacterAt:)`
- `theme`, `keymap`, `isEditable`, `allowsCheckboxToggle`, `setInlineContent(rules:provider:)`, `setCodeBlockHighlighter(_:)`
- `smartTypography: SmartTypographyOptions` — `.smartQuotes`, `.ellipsis`, `.emDash`; empty by default. Each substitution is its own undo step and skips code.
- `undoManager`

Every programmatic edit is a single undo step. Typing runs the built-in input rules: `# ` through `###### `, `- `, `* `, `+ `, `1. `, `> ` and `[ ]` / `[x]` at a line start set the block, and a closing `**`, `*`, `_`, `~~` or backtick applies the mark.

`EditorAction` lists every command the toolbar and menus perform: `bold`, `italic`, `strikethrough`, `heading(level:)`, `unorderedList`, `orderedList`, `taskList`, `blockquote`, `codeSpan`, `codeBlock`, `link(url:label:)`, `horizontalRule`, `indent`, `outdent`, and the table actions above.

## Plugins

A plugin is a class conforming to `EditorPlugin`. It receives every `DocumentChange` and can intercept clicks, long presses, paste, key presses and text input through `PluginProps`. Each handler returns `true` when it consumed the event.

```swift
final class ShoutPlugin: EditorPlugin {
    let key = AnyPluginKey(name: "example.shout")

    var props: PluginProps {
        PluginProps(handleTextInput: { controller, range, text in
            guard text == "!" else { return false }
            return controller.replaceText(in: range, with: "‼")
        })
    }
}

SwiftProseEditor(text: $markdown)
    .onProseControllerReady { controller in
        controller.register(plugin: ShoutPlugin())
    }
```

Plugins keep per-editor state with typed keys: `PluginKey<State>` with `pluginState(for:)`, `setPluginState(_:for:)` and `clearPluginState(for:)`.

Three plugins ship with the package:

- **`CompletionPlugin`** tracks trigger-prefixed queries such as `@name` and reports a `CompletionSession` through `onSessionChanged`. `attach(to:)` accepts an `EditorController` and a `SourceEditorController`; attach to both for completion in either mode. The `.proseCompletions(_:)` modifier wires a popup to it from a `ProseCompletionConfiguration` (triggers, an async `fetch`, a row view, and `onSelect`, which receives the active `ProseEditing` editor). `CompletionPopupPlacement` positions popups for hosts that draw their own.
- **`AutoLinkPlugin`** links text as it is typed in rich mode, driven by `AutoLinkRule`s. `AutoLinkRule.url` and `AutoLinkRule.email` are built in; a custom rule maps a regex match to an `href` and an optional title.
- **`InternalLinkPlugin`** handles clicks on `#fragment` links by selecting and scrolling to the matching heading (`SlugStyle.github` or `.exact`), and passes relative links to `handleRelativeLink` as a `LinkTarget`.

Plugins register on the rich controller. Source mode exposes `addKeyHandler(_:)`, `addTextInputHandler(_:)`, `addOnTextChange(_:)` and `addOnSelectionChanged(_:)` on `SourceEditorController`.

## Loading and writing without a view

`MarkdownLoader().load(_:)` parses markdown into attributed storage, `StorageReader` reads storage into an `EditorDocument` tree, and `MarkdownWriter` writes either form back to markdown. All three live in `SwiftProseSyntax`.

```swift
import SwiftProseSyntax

let storage = MarkdownLoader().load("# Title\n\n- item\n")
let document = StorageReader().document(from: storage)
let markdown = MarkdownWriter().write(document)
// or: MarkdownWriter().markdown(from: storage)
```

`EditorDocument.Block` is `.paragraph`, `.heading`, `.code`, `.thematicBreak`, `.atom`, `.quote`, `.list` or `.table`, with inline content as `InlineRun`s. Storage reads go through `NSAttributedString` helpers: `markdownBlock(at:)`, `markdownInlineIntent(at:)`, `markdownLiteral(at:)`, `markdownLink(at:)`, `proseSourceAttachment(at:)`, `markdownParagraphRanges(in:)`.

## Observing changes

```swift
SwiftProseEditor(text: $markdown)
    .onProseControllerReady { controller in
        let token = controller.addOnDocumentChange { change in
            // change.editedRange, change.changeInLength, change.origin
        }
        _ = controller.addOnSelectionChanged { range in }
        // later: controller.removeObserver(token)
    }
```

A `DocumentChange` carries the edited range in post-edit storage offsets, the change in length, and an origin: `.user`, `.command`, `.undo` or `.load`. A command publishes once; typing publishes once per run-loop turn. Plugins see the same changes through `documentDidChange(_:controller:)`. `onSelectionChanged` is a single-callback alternative to `addOnSelectionChanged(_:)`.

## Architecture

Five targets. The four core targets form a chain; `SwiftProseTreeSitter` sits beside it.

| Target | Role |
|---|---|
| `SwiftProseSyntax` | The storage vocabulary (`MarkdownBlock`, attribute keys, `GroupToken`), `MarkdownLoader`, `StorageReader`, `EditorDocument`, `MarkdownWriter`, the source-mode model (`MarkdownSourceFormatter`), atom attachments, `EditorAction`, and the highlighter contract. Foundation and attributed-string level AppKit / UIKit only. |
| `SwiftProseRendering` | `ProseTheme` and its styles, `CheckboxAttachment`, and the marker value types `ListMarker` and `QuoteBar`. |
| `SwiftProseView` | `EditorController`, `SourceEditorController`, `EditorHandle`, editing rules, normalization, restyling, highlighting sessions, plugins, layout fragments, and the macOS / iOS text views. |
| `SwiftProse` | `SwiftProseEditor`, configuration, modifiers, toolbar, status bar, completion overlay and the table structure sheet. Re-exports the three below it. |
| `SwiftProseTreeSitter` | `TreeSitterCodeBlockHighlighter` and language detection. The only target that links `swift-tree-sitter`. |

The canonical state is the `NSTextStorage`: one paragraph per block, a `MarkdownBlock` on every character, inline marks as `InlinePresentationIntent` bits, escapes and entities kept as literals, atoms as attachments, lists as real `NSTextList`s. Markdown text exists only at load and write.

## Examples

`Examples/SwiftProseDemo/` is a multi-platform `DocumentGroup` app that opens and saves `.md` files, shows the toolbar, status bar and mode toggle, and registers four tree-sitter grammars. It also carries the editing harness: scripted scenarios, a seeded fuzzer and a corpus ledger that drive the real text view. See its README.

```sh
open Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj
```

## API documentation

This README is the guide; DocC is the reference. In Xcode, use **Product → Build Documentation**. From the command line the DocC plugin is opt-in, gated on `SWIFTPROSE_DOCS`, so only this package resolves it:

```sh
SWIFTPROSE_DOCS=1 swift package generate-documentation --target SwiftProse
```

Each target is documented separately, since `SwiftProse` re-exports the others:

| Target | Reference covers |
|---|---|
| `SwiftProse` | `SwiftProseEditor`, configuration, modifiers, toolbar, completion |
| `SwiftProseView` | `EditorController`, `SourceEditorController`, `EditorHandle`, plugins, text views |
| `SwiftProseSyntax` | vocabulary, loader, reader, writer, `EditorDocument`, source formatter, highlighter contract |
| `SwiftProseRendering` | `ProseTheme`, styles, attachments, marker types |
| `SwiftProseTreeSitter` | `TreeSitterCodeBlockHighlighter` |

To preview one in a browser:

```sh
SWIFTPROSE_DOCS=1 swift package --disable-sandbox preview-documentation --target SwiftProseView
```

## Testing

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The CommandLineTools toolchain lacks Swift Testing, so point `DEVELOPER_DIR` at Xcode. `SwiftProseSyntaxTests` covers the loader, writer, vocabulary, source formatter and a corpus of round trips; `SwiftProseViewTests` covers editing, normalization, restyling, tables, highlighting, plugins, source mode and hosted text views; `SwiftProseTests` covers the SwiftUI surface and mode switching. Shared fixtures live in `Tests/Support`.

The demo's editing harness runs in the real app window:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
  -scheme SwiftProseDemo \
  -destination 'platform=macOS'
```

## Upgrading

This release replaces the editor core. The ProseMirror-aligned model is removed; the SwiftUI surface keeps its names.

| Was | Now |
|---|---|
| `EditorController(initialMarkdown:)` (throwing) | `EditorController(markdown:theme:inlineContentRules:inlineContentProvider:codeBlockHighlighter:undoManager:)` |
| `setMarkdown(_:async:)` | `setMarkdown(_:)`, synchronous |
| `controller.layoutManager`, `controller.contentStorage` | `textLayoutManager`, `textContentStorage` |
| `perform(_:) -> NSRange` | `perform(_:)` returns `Void`; read `currentSelection` afterwards |
| `isActionActive(_:)` | `isActive(_:)`, `activeActionIDs()` |
| `onDocumentChange = { change in }` | `addOnDocumentChange { change in }` returning an `ObserverToken` |
| `DocumentChange.step`, `.document` | `DocumentChange.editedRange`, `.changeInLength`, `.origin` |
| `controller.document` (`ProseDocument`) | `StorageReader().document(from: controller.textStorage)` (`EditorDocument`) |
| `controller.apply(_:)` with `Transaction` / `Step` | `perform(_:)`, `insertMarkdown(_:replacing:label:)`, `replaceText(in:with:label:)`, `setLink(_:in:label:)` |
| `controller.insert(text:)` | `replaceText(in:with:label:)` |
| `commands`, `Command`, `CommandRegistry`, `*Command` structs | `EditorAction` with `perform` / `canPerform` / `isActive` |
| `inputRules`, `InputRule`, `RuleOptions` | built-in input rules; `smartTypography: SmartTypographyOptions`; `PluginProps.handleTextInput` for custom rules |
| `historyConfig`, `closeHistoryGroup()`, `undoDepth` / `redoDepth`, `isHistoryTransaction(_:)` | `controller.undoManager` (`canUndo`, `canRedo`) |
| `currentTypedSelection`, `Selection` | `currentSelection: NSRange`, `setSelection(_:)` |
| `linkMark(at:)`, `updateLink`, `removeLink` | `NSAttributedString.markdownLink(at:)`; `setLink(_:in:label:)` with a URL sets, with `nil` removes |
| `proseNodePath`, `proseMarks`, `BlockSpec` | `.markdownBlock` (`MarkdownBlock`), `.markdownInlineIntent`, `.link`, `.markdownLiteral` |
| `CodeBlockHighlighter.highlights(for:language:)` | `makeSession(language:body:)` returning a `CodeHighlightSession` |
| `TreeSitterCodeBlockHighlighter` in `SwiftProseSyntax` | `TreeSitterCodeBlockHighlighter(palette:)` in the `SwiftProseTreeSitter` product |
| `ProseTheme.codePalette`, `codeColor(for:)` | `CodePalette` on `TreeSitterCodeBlockHighlighter` |
| `ProseCompletionConfiguration.onSelect: (EditorController, NSRange, Item)` | `(any ProseEditing, NSRange, Item)` |
| `EditorPlugin.filterTransaction`, `appendTransaction` | `documentDidChange(_:controller:)`, `PluginProps.handleTextInput` |
| `ProseInlineContent.bugLink`, `.searchfoxLink` | `.custom(kind:label:systemImage:)` |
| `TableBlockView`, `nodeViewRegistry`, `NodeViewProvider`, `ProseNodeAttachment` | tables edit inline as paragraphs |
| `loadProseMirrorJSON`, `exportProseMirrorJSON`, `ProseMirrorCodec` | Removed. Load and write markdown with `MarkdownLoader` / `MarkdownWriter` |
| `Schema`, `NodeType`, `MarkType`, `ContentMatch`, `AttrSpec`, `AllowedMarks` | Removed |
| `ProseDocument`, `TreeNode`, `ProseNode`, `NodeID`, `NodePath`, `NodePathBox`, `StorageLayout`, `ResolvedPos`, `NodeRange`, `Slice`, `Fragment` | Removed |
| `Step`, `StepMap`, `Mapping`, `Transaction`, `AppliedStep`, `AppliedTransaction`, `StepEnvironment`, `HistoryRecord`, `HistoryConfig` | Removed |
| `ProseMark`, `MarkSet`, `MarkSetBox`, `InlineMark`, `PMNode`, `PMMark`, `SchemaMap` | Removed |
| `SchemaValidator`, `SpecValidator`, `SpecDiagnostic`, `SchemaDiagnostic`, `onDiagnostic`, `onSchemaDiagnostic`, `addOnDiagnostic` | Removed |
| `Decoration`, `DecorationSet`, `DecorationProvider`, `BlockSpecDecorationProvider` | Removed |
| `MarkdownParser`, `HighlightApplier`, `BlockClassifier`, `BlockSegmenter`, `BlockSegment`, `BlockKind`, `BlockRegion`, `BlockTag`, `InlineClassifier`, `InlineKind`, `InlineRegion`, `InlineTag`, `ListItemKind`, `PipeTableAlignment` | Removed |
| `MarkdownAttributedCompiler`, `MarkdownTreeSerializer`, `AttributedMarkdownSerializer`, `NodePathSynthesizer`, `Operations`, `InsertNewline` | Removed |
| `ClipboardParser`, `ClipboardSerializer`, `DOMParser`, `DOMSerializer`, `PlainTextSerializer` | Removed |
| `ProseSubtreeAttachment`, `TableScrollContainer`, `CellView`, `BulletAttachment`, `BulletGlyphAttachment`, `OrderedMarkerFormatter`, `BlockquoteLayoutFragment`, `IndentedCodeBlockLayoutFragment`, `ProseHosting`, `InlineContentNode` | Removed |
| `ProseTheme.markupColor`, `linkURLColor`, `PluginProps.handleDrop` | Removed |
| `controller.blocks`, `text`, `recompile()`, `sliceForRange`, `dispatchPaste`, `useStructuredBulkInsert`, `lastInputRule`, `undoInputRule()` | Removed |

New: `EditorMode`, `EditorHandle`, `SourceEditorController`, `.editorMode(_:)`, `.onProseHandleReady(_:)`, `ToolbarItem.modeToggle`, `Configuration.toolbarPadding` and `sourceSpellChecking`, the public `ProseToolbar`, `ProseSourceTextViewMac` / `ProseSourceTextViewIOS`, `MarkdownLoader`, `StorageReader`, `MarkdownWriter`, `EditorDocument`, `MarkdownSourceFormatter`, `InternalLinkPlugin`.

Behaviour changes without an API change:

- **`setMarkdown(_:)` is synchronous.** The storage holds the new document when the call returns.
- **macOS undo is the text view's.** The hosted `NSTextView` registers typing undo with AppKit's own coalescing, and commands register on the same manager. Headless editors and iOS register snapshot closures on `controller.undoManager` (on iOS, the text view's manager).
- **Tables are inline.** A table is a run of tab-separated paragraphs in storage, and its cells are ordinary editable text.
- **`markdown()` returns the load bytes until the document changes.** It compares storage with what was loaded and returns the original string while they match, so an edit followed by its undo returns the original bytes too.
- **Edited content is written in canonical form.** Setext headings are written as ATX, a closing `#` run is dropped, `~~~` fences become backticks, loose lists are tightened, link titles are dropped, reference-style links are written inline, and footnotes are written as text.

## Roadmap

Planned on the current core:

- **HTML blocks editable as text.** One paragraph per source line in monospace, grouped like a code block.
- **GFM alerts.** `> [!NOTE]` and friends get a coloured tag and bar by kind.
- **Link reference definitions.** `[text][label]` references and their definitions written back where they were.
- **Editable image alt text.** Alt text edited as text, with the title kept.
- **Wider tables.** Wrapped cells, capped column widths and horizontal scrolling.

## License

MPL 2.0. See [LICENSE](LICENSE).
