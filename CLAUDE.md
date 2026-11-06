# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & test

The CommandLineTools toolchain doesn't ship Swift Testing, so always point `swift` and `xcodebuild` at the Xcode developer dir:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SwiftProseViewTests.ControllerKeyRuleTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SwiftProseViewTests.ControllerKeyRuleTests/tabNestsAnywhereInItemAndShiftTabOutdents
```

DocC is opt-in so downstream apps don't resolve the plugin:

```sh
SWIFTPROSE_DOCS=1 swift package generate-documentation --target SwiftProseView
```

Landing pages live in `Sources/<Target>/<Target>.docc/`. Keep them building
without warnings — a symbol link that no longer resolves is a stale doc.
Platform-conditional types (`ProseTextViewIOS`) can't be curated, since the
reference is built per-platform.

The editing harness lives in a separate Xcode project
(`Examples/SwiftProseDemo/`) and requires `xcodebuild`. It drives the real
`ProseNSTextView` in the real app window, from inside the app's own
process, so it needs no UI-automation permission:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
  -scheme SwiftProseDemo -destination 'platform=macOS'
```

That runs `SwiftProseDemoTests` — driver canaries, the corpus ledger, ~165
scripted edit scenarios, and a seeded fuzz smoke — and skips the
permission-gated `SwiftProseDemoUITests`. See
`Examples/SwiftProseDemo/README.md` for the op vocabulary, the oracles, the
fuzz / replay / shrink CLI, and how to add a scenario.

The harness reaches eight `@_spi(Harness)` seams on `EditorController`
(`Sources/SwiftProseView/HarnessSPI.swift`): `settleForHarness()`,
`hasPendingWorkForHarness`, `activeUndoManagerForHarness`,
`breakUndoCoalescingForHarness()`, `harnessEditRouteProbe`,
`harnessNormalizationDrift()`, `harnessSerializationDrift()` and
`harnessTableGeometry(at:)`. They keep the
demo off `@testable import` and the public API clean; add to that file when
the harness needs more.

Targets `macOS 26` / `iOS 26` (SDK 26+ required — older Xcodes won't build).

## Architecture

Five SPM targets (see `Package.swift`). The four core targets form a chain; `SwiftProseTreeSitter` hangs off `SwiftProseSyntax`:

```
SwiftProseSyntax     ← vocabulary, loader, reader, writer, EditorDocument, source-mode model,
   ↑                   atom attachments, EditorAction, highlighter contract, platform aliases
SwiftProseRendering  ← ProseTheme and its styles, CheckboxAttachment, ListMarker, QuoteBar
   ↑
SwiftProseView       ← EditorController, SourceEditorController, EditorHandle, editing rules,
   ↑                   Normalizer, Restyler, highlighting sessions, plugins, layout fragments,
   ↑                   NS/UITextView representables, clipboard, HarnessSPI
SwiftProse           ← SwiftUI surface (SwiftProseEditor), modifiers, toolbar, status bar,
                       completion overlay, table structure sheet

SwiftProseTreeSitter ← TreeSitterCodeBlockHighlighter, CodePalette, language detection
                       (depends on SwiftProseSyntax + swift-tree-sitter)
```

`SwiftProse` `@_exported`s the three core targets below it. Place code in the lowest layer that satisfies its imports.

**Layering rule.** `SwiftProseSyntax` imports Foundation, CoreGraphics / CoreText, and AppKit / UIKit for attributed-string level types only: `NSAttributedString.Key`, `NSParagraphStyle` / `NSTextList`, self-drawing `NSTextAttachment` subclasses, `PlatformFont` / `PlatformColor`. SwiftUI, `NSTextView` / `UITextView`, `NSTextLayoutManager`, `NSTextContentStorage`, `NSTextLayoutFragment`, pasteboards and View-layer types belong in `SwiftProseView` or above. This keeps `MarkdownLoader` and `MarkdownWriter` headless and testable from `SwiftProseSyntaxTests`. The layout fragments read `controller.decorationCache`, `MarkdownTextList.effectiveTextLists` and `Restyler` constants, so they live in `SwiftProseView/Layout/`. `swift-tree-sitter` is linked only by `SwiftProseTreeSitter`; the core targets use Apple frameworks only.

### Canonical state: the text storage

`EditorController.textStorage` is the document; the live editing path reads and writes only it.

- **One paragraph per block.** Every character, including the paragraph's `\n`, carries `.markdownBlock` (`MarkdownBlock`, raw key `swiftprose.block`). `MarkdownBlock` has a `leaf` (`paragraph`, `heading(level:)`, `code(language:group:)`, `thematicBreak`, `tableRow(group:alignments:isHeader:)`, `html`), outer-to-inner `containers` (`quote(GroupToken)`, `listItem`), `isContinuation` for the second and later paragraphs of a list item, and an optional `task`. The value is uniform across the paragraph.
- **Inline marks** are `InlinePresentationIntent` bits in `.markdownInlineIntent` (`stronglyEmphasized`, `emphasized`, `code`, `strikethrough`). Links are `.link`.
- **Literals.** `.markdownLiteral` holds the source of an escape or entity on the one rendered character (two UTF-16 units for a surrogate pair) that stands for it.
- **Atoms** are U+FFFC attachments conforming to `ProseSourceAttachment` (`markdownSource`, `contentKind`): images, inline HTML, HTML blocks, thematic breaks, inline-content chips.
- **Lists** are real `NSTextList`s on the paragraph style. `textLists.count` equals the number of `listItem` containers.
- **`GroupToken`** ties paragraphs into one construct: the lines of a code block, the rows of a table, the paragraphs of one blockquote.
- **Tables** are rows of tab-separated cells; each separator `\t` carries `.markdownTableSeparator`, and `TableRowGeometry` (`.markdownTableGeometry`, `package`) records row index, row count and column edges for layout.
- **Soft breaks** inside a paragraph are U+2028 (`MarkdownBreak`). Each line of a code block is its own paragraph.

Fonts, colours and paragraph styles are derived from those attributes by `Restyler`; structure is read from the attributes above. **Do not infer block kind from text or fonts.** Read `markdownBlock(at:)`.

### Load and write

```
markdown
  ↓  MarkdownSourceText (bytes, line starts)
  ↓  AttributedString(markdown:) with source positions
  ↓  LoaderStructure  ← ContainerPrefix (quote / list prefixes), TableSource (pipe rows)
  ↓  LoaderInline     ← SourceAligner (recovers escapes, entities, delimiters as literals)
  ↓  inline-content rules → atoms
NSMutableAttributedString (MarkdownLoader.load)

storage → StorageReader → EditorDocument → MarkdownWriter → markdown
```

`MarkdownLoader.loadWithReport` stays internal; its `LoaderReport` feeds tests. `EditorDocument` exists only on the write side, built by `StorageReader` for `MarkdownWriter`. The writer's output is canonical. `EditorController.markdown()` returns the original load bytes until the first storage edit after a load; after that it returns them while `VocabularySnapshot` (the vocabulary attributes captured at load) still matches storage and the serialization equals the one taken at load, and the writer's output otherwise.

**Top-level units.** `StorageReader.units(in:from:previous:stoppingAt:)` (`package`) reads storage as `TopLevelUnit`s, one per top-level block of the document. Unit spans tile the storage: blank paragraphs after a block belong to it, leading blanks to the first unit. A read can start at any unit boundary with a fresh tree builder; `previous` (the prior unit's `TopLevelList`) only sets `separatesFromPrevious`. `MarkdownWriter.writeTopLevel(_:after:)` writes one unit given a `TopLevelContext` (`.other` or `.list(isOrdered:alternate:)`) and returns its text and the context after it; a block that renders nothing returns `nil` and leaves the context unchanged. The full writer joins unit texts with a blank line, so full and incremental serialization share one code path. `MarkdownWriter.markdown(from:range:)` (clipboard copy) keeps its clipped, context-free read.

**Incremental serialization.** `IncrementalSerializer` (`SwiftProseView/Editing`), owned by the controller, caches each unit's block, span, entry and exit context and text, plus the joined output. `didProcessEditing` records every storage edit into one dirty range (`NSRange.merged(withEdit:changeInLength:)`) ahead of its loading / restyling guard, so `withoutBinding` passes count, and then adds the normalizer's touched range. `serialize()` re-reads from the unit holding the dirty start (one unit earlier when that unit is a list, quote, code block or table, which can absorb what follows) and stops at the first new boundary past the dirty end that lands on a shifted old boundary. It then re-writes following units while their entry context or list separation changed, and splices the new texts into the output. Any inconsistency (length drift, spans that miss the storage length, an unprocessed edit batch) falls back to a full rebuild. `load()` and the load-snapshot restore rebuild the cache; load takes `serializedAtLoad` from that rebuild.

### Edit flow

```
host text view delegate → hostShouldChangeText(in:replacement:)
  ↓  plugins' handleTextInput, table-edit routing, typing into an atom, typed-input record
NSTextStorage mutates
  ↓  textStorage(_:didProcessEditing:...)
Normalizer   (edited paragraph ±1: block uniformity, list reconciliation, literals, table separators)
  ↓
Restyler     (fonts, colours, paragraph styles from block + intent)
  ↓
CodeHighlighting.update (session didEdit / reset per code block)
  ↓
recordChange → pending DocumentChange (the serializer's dirty range is recorded at the top of didProcessEditing)
  ↓  scheduleBindingPush (80 ms trailing debounce; the push splices only the dirty units)
flushDocumentChanges (next main-queue turn, or at the end of performEdit)
  ↓  plugins' documentDidChange, addOnDocumentChange observers
input rules (deferEdit, origin .user only)
```

Commands go through `performEdit(_:ranges:replacements:...)` → `EditSession.perform`, which makes each command one undo step and flushes on return. Key handling (Return, Backspace, Tab, fence and thematic-break rules) lives in `Editing/KeyRules.swift`; block and inline-closer input rules in `Editing/InputRules.swift`; format commands in `Editing/FormatCommands.swift`; table editing in `Editing/TableEditing.swift` and `TableCommands.swift`; paste in `Editing/ClipboardEditing.swift` and `PasteSanitizer.swift`.

`DocumentChange.origin` is `.user`, `.command`, `.undo` or `.load`. Every change except `.load` marks the `text` binding dirty and re-arms an 80 ms trailing timer; the push serializes once when it fires, through the incremental cache. `flushPendingBinding()` pushes immediately and runs on end of editing, before `onSubmit`, on representable teardown, on a switch to source mode, on load-snapshot restore, in `settleForHarness()`, and when the app terminates (macOS) or enters the background (iOS). With no `textSink` attached the push is skipped and the binding stays dirty. A load cancels any pending push, so external text wins.

### Undo

- **macOS, hosted:** the `NSTextView` owns undo (`allowsUndo = true`, the delegate's `undoManager(for:)` returns `controller.undoManager`). Typing uses AppKit's coalescing. Commands call `shouldChangeText(inRanges:replacementStrings:)` / `didChangeText()` around their storage writes with `breakUndoCoalescing()` on both sides, so they register on the same manager. `ProseNSTextView` forwards `undo:` / `redo:` explicitly.
- **Headless and iOS:** `EditSession.performSnapshot` registers a closure that restores an attributed snapshot of the affected paragraphs, re-registering its counterpart for redo. On iOS the manager is the host `UITextView`'s, which `ProseUITextView` points at the controller's.
- **Load and mode switch:** `setMarkdown(_:)` clears history. A mode switch that changes the text registers one restore step holding the full load snapshot.

### Tables

Tables are inline: header and body rows are paragraphs in storage, painted by `TableRowLayoutFragment` with shared tab stops. Cell navigation, separator protection, row insertion on Return / Tab, and structural actions route through `applyTableEdit` and `TableCommands`. `TableStructureModel` (Syntax) is the value the structure sheet edits.

### Source mode

`SourceEditorController` runs a plain TextKit 2 stack over the markdown text. `SourceStyler` highlights line by line, storing a `SourceLineState` per line (`package` key `.markdownSourceLineState`) and restyling forward while a line's end state changes. Commands run `MarkdownSourceFormatter` (Syntax, pure) and apply its `MarkdownSourceEdit`. A mode switch reloads the text into the other controller (`EditorHandle.synchronize(for:)`) and maps the caret through `SourceSelectionMapping`.

### Code highlighting

The contract is in `SwiftProseSyntax/Highlighting/CodeBlockHighlighter.swift`: `CodeBlockHighlighter.makeSession(language:body:)` returns a `CodeHighlightSession` per code block, which answers `reset(body:)` and `didEdit(replacedRange:replacement:body:)` with `CodeHighlightRun`s. `SwiftProseView/Highlighting/CodeHighlighting.swift` keeps one session per block, maps storage offsets to body offsets (skipping container prefixes marked `.markdownCodePrefix`), and paints the runs. Both modes use it. `SwiftProseTreeSitter` provides `TreeSitterCodeBlockHighlighter`: grammars registered by the host, a `CodePalette`, and `detectLanguage(for:)` for fences without an info string (≥ 30% coverage and ≥ 1.5× the runner-up).

### Plugins

`EditorPlugin` has `key`, `props: PluginProps` (`handleClick`, `handleLongPress`, `handlePaste`, `handleKeyDown`, `handleTextInput`) and `documentDidChange(_:controller:)`. State lives behind `PluginKey<State>`. Bundled: `CompletionPlugin` (attaches to both controllers), `AutoLinkPlugin`, `InternalLinkPlugin`. Key names use the `swiftprose.` prefix.

### Platform abstraction

`SwiftProseSyntax/Platform/PlatformAliases.swift` defines `PlatformFont` / `PlatformColor` / `PlatformTextView` and friends as typealiases to the native AppKit or UIKit type. The macOS and iOS surfaces have separate representables (`ProseTextViewMac` / `ProseTextViewIOS`, `ProseSourceTextViewMac` / `ProseSourceTextViewIOS`) over internal text-view subclasses (`ProseNSTextView`, `ProseUITextView`, `ProseSourceNSTextView`, `ProseSourceUITextView`). Keep new platform-specific code on the same side of the existing `#if canImport(AppKit) && os(macOS)` / `#elseif canImport(UIKit)` guards.

## Conventions

- The README is canonical for the public API surface. Keep it updated when changing public types in `SwiftProse` / `SwiftProseView` / `SwiftProseSyntax` / `SwiftProseRendering` / `SwiftProseTreeSitter`.
- Cross-target internals use the `package` access level. `public` is for API a host app calls.
- Internal loader, writer, normalizer, restyler and edit-session types keep their MarkdownEditorKit names (`LoaderStructure`, `StorageReader`, `Normalizer`, `Restyler`, `EditSession`, `VocabularySnapshot`, the `.markdown*` attribute keys). Public host-facing types use the `Editor*` / `Prose*` prefixes.
- Tests live next to the layer they cover (`SwiftProseSyntaxTests`, `SwiftProseViewTests`, `SwiftProseTests`, `SwiftProseTreeSitterTests`). Shared fixtures (`StorageBuilder`, `HeadlessEditor`, `FakeCodeHighlighter`, the corpus) live in `Tests/Support` (`SwiftProseTestSupport`) and use public API only. Suites that host a window are `.serialized`; `HostedTypingTests` is XCTest so it runs before the parallel Swift Testing phase.
- Comments stay short and technical. Lead with the rule. Skip references to historical incidents, callers, or PR numbers.
- License is MPL 2.0; new source files carry no header.

## Commit message style

Single-line, lowercase, scoped prefix optional. No body, no trailers (no `Co-authored-by`, no "PM-equivalent to …" footers). Match the existing log:

- `schema: rename ordered_list.start → ordered_list.order to match PM`
- `steps: typed inverses for addMark / removeMark / setNodeAttrs / replaceAround / setSpec`
- `tables: route TK2 line-fragment sizing through view-provider measurement`
- `compiler: parse link reference attrs onto leaf node`
