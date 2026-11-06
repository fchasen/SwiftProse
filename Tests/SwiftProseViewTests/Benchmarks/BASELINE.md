# Keystroke benchmark baseline

## 2026-11-06 — incremental serialization

`EditorController` keeps each top-level block's markdown in an
`IncrementalSerializer`. `didProcessEditing` records every storage edit into
one dirty range, and `serialize()` re-reads and re-writes only the units that
range reaches, plus following lists whose marker alternation it flips, and
splices them into the cached output. `markdown()` returns the load bytes
without serializing until the first storage edit after a load.
Reproduce and machine as below (debug build, Apple Silicon, macOS 27).
"Before" is the deferred-binding-push core, re-run the same day.

New rows: `markdown() — edited` and `serialize() — spliced after keystroke`
time one call after a mid-document keystroke; `markdown() — unedited` uses a
freshly loaded controller. `markdown() — edited back to load` is the old
`markdown()` row (measured after the keystroke rows undo themselves), where
the splice output equals the load serialization and `storageMatchesLoad`
runs.

### Mixed document (~1200 blocks)

| case | before median µs | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|---:|
| keystroke — doc start | 143.0 | 141.6 | 151.4 | 73.6 |
| keystroke — mid paragraph | 191.1 | 194.0 | 201.2 | 106.6 |
| keystroke — nested list item | 191.4 | 192.5 | 200.9 | 98.6 |
| keystroke — inside fence | 120.0 | 121.2 | 127.6 | 55.3 |
| keystroke — tail | 129.0 | 130.6 | 135.4 | 63.6 |
| keystroke — change subscriber | 191.9 | 210.8 | 221.8 | 104.8 |
| keystroke — bound sink, push deferred | 198.0 | 201.5 | 208.1 | 108.8 |
| keystroke + flushPendingBinding | 17669.5 | 494.3 | 569.1 | 3200.4 |
| insertMarkdown | 254.5 | 271.1 | 278.4 | 122.8 |
| markdown() — edited back to load | 33835.6 | 15140.3 | 15259.9 | 3080.8 |
| markdown() — edited | — | 252.6 | 257.6 | 94.9 |
| serialize() — spliced after keystroke | — | 249.0 | 256.5 | 89.9 |
| markdown() — unedited | — | 0.0 | 0.0 | 0.0 |
| MarkdownLoader.load | 64067.0 | 65937.8 | 67589.3 | 17725.7 |
| MarkdownWriter.markdown(from:) | 17092.4 | 17949.9 | 18117.6 | 71.3 |

### Long fence (one 3000-line fenced block)

| case | before median µs | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|---:|
| keystroke — inside 3000-line fence | 51.5 | 52.4 | 55.2 | 0.1 |
| markdown() | 26922.8 | 5812.4 | 5830.5 | 0.0 |
| MarkdownLoader.load | 23209.4 | 23914.4 | 24257.0 | 7.6 |
| MarkdownWriter.markdown(from:) | 19093.5 | 20598.1 | 20921.5 | 0.0 |

### Reading

A re-serialize after a local edit costs ~0.12–0.35 ms on the mixed fixture,
depending on the units the edit and its ±1-paragraph restyle reach: ~0.12 ms
in a heading or plain paragraph, ~0.3 ms when a neighbour is a nested list,
which costs ~75 µs to read and ~110 µs to write in a debug build. The
debounced push (`keystroke + flushPendingBinding`) drops from ~17.7 ms to
~0.5 ms. `markdown()` on an unedited document returns the load bytes without
work. Once edited, a document that serializes back to its load output still
pays `storageMatchesLoad` (~15 ms mixed, ~5.8 ms long fence): the string
compare and `VocabularySnapshot.matches`. The full writer stays within noise
of before (best-of-15 probe: 18.1 ms before, 18.5 ms after; reader 9.5 →
10.0 ms). An edit inside the long fence still re-reads and re-writes the
whole fence unit.

## 2026-11-06 — deferred binding push

`didProcessEditing` marks the binding dirty and restarts an 80 ms trailing
timer. The timer, or `flushPendingBinding()`, runs `pushBinding`, which
serializes once and calls the sink. A controller with no sink skips the push
and keeps the binding dirty until one is attached.
Reproduce and machine as below (debug build, Apple Silicon, macOS 27).

The `keystroke` helper is unchanged: `flushDocumentChanges` fans out the
`DocumentChange` and leaves the binding timer pending. The headless
controller has no sink, so the plain keystroke rows measure the editing path
alone. `bound sink, push deferred` attaches a sink and measures the same
keystroke with the timer armed; `keystroke + flushPendingBinding` adds the
push the timer would make, which is the cost a host pays once per burst.

### Mixed document (~1200 blocks)

83,692 UTF-16 source → 73,291 storage.

| case | 2026-11-05 median µs | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|---:|
| keystroke — doc start | 18655.7 | 143.8 | 151.5 | 78.8 |
| keystroke — mid paragraph | 18938.2 | 204.5 | 214.2 | 99.7 |
| keystroke — nested list item | 18494.8 | 201.5 | 210.8 | 98.5 |
| keystroke — inside fence | 18329.0 | 120.8 | 127.5 | 60.3 |
| keystroke — tail | 18356.2 | 128.0 | 132.3 | 63.3 |
| keystroke — change subscriber | 18520.3 | 196.5 | 205.9 | 104.7 |
| keystroke — bound sink, push deferred | — | 205.0 | 215.6 | 107.0 |
| keystroke + flushPendingBinding | — | 18283.2 | 18612.7 | 3243.4 |
| insertMarkdown | 18820.5 | 260.4 | 272.0 | 101.5 |
| markdown() | 34613.5 | 33995.8 | 34169.5 | 3080.6 |
| MarkdownLoader.load | 69216.5 | 66119.2 | 67000.0 | 17708.1 |
| MarkdownWriter.markdown(from:) | 18083.0 | 17679.2 | 17896.0 | 0.0 |

### Long fence (one 3000-line fenced block)

168,987 UTF-16 source → 168,971 storage.

| case | 2026-11-05 median µs | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|---:|
| keystroke — inside 3000-line fence | 21578.1 | 50.4 | 53.5 | 0.1 |
| markdown() | 27477.0 | 26509.2 | 26953.2 | 0.0 |
| MarkdownLoader.load | 25017.5 | 24157.5 | 24317.8 | 6.6 |
| MarkdownWriter.markdown(from:) | 20147.8 | 19916.2 | 20151.5 | 0.0 |

### Storage primitives (`StoragePrimitiveBench`, best per-op µs)

| primitive | mixed plain | mixed controller | fence plain | fence controller |
|---|---:|---:|---:|---:|
| 1-char edit | 35.0 | 360.1 | 1.6 | 85.5 |

The other primitive rows match 2026-11-05 within noise.

### Reading

A keystroke now costs 0.12–0.21 ms on the mixed fixture, about 90–150x
less than before, and 50 µs inside the long fence. One serialization per
burst remains (`keystroke + flushPendingBinding`, ~18 ms), paid when the
timer fires, the text view ends editing, the host submits, the editor
switches to source mode or the representable is torn down.

## 2026-11-05 — core replacement (MarkdownEditorKit)

The tree-sitter / ProseMirror-shaped core was replaced by the MarkdownEditorKit
core on `model-refactor`. Every section after this one measures the legacy
core and is kept for history; numbers are not comparable case-for-case.

Reproduce with:

```sh
SWIFTPROSE_BENCH=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter KeystrokeBenchmarkTests
```

Machine: Apple Silicon, debug build (`-Onone`), macOS 27.

Each `keystroke` op routes one character through a headless controller:
`shouldChangeText`, `replaceCharacters` with the caret's typing attributes,
then `flushDocumentChanges` / `drainDeferredEdits`. The delete that restores
the fixture runs outside the timer. `insertMarkdown` is the command path.
`MarkdownLoader.load` and `MarkdownWriter.markdown(from:)` run without a
controller.

A keystroke costs about one `MarkdownWriter.markdown(from:)`. At this
revision `pushBinding` serialized the whole document after every edit, with or
without a text sink; 2026-11-06 defers it to a trailing timer.

### Mixed document (~1200 blocks)

83,692 UTF-16 source → 73,291 storage.

| case | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|
| keystroke — doc start | 18655.7 | 18902.3 | 3176.8 |
| keystroke — mid paragraph | 18938.2 | 19465.0 | 3180.4 |
| keystroke — nested list item | 18494.8 | 18821.5 | 3183.5 |
| keystroke — inside fence | 18329.0 | 18530.8 | 3136.2 |
| keystroke — tail | 18356.2 | 18617.3 | 3140.8 |
| keystroke — change subscriber | 18520.3 | 18835.0 | 3167.8 |
| insertMarkdown | 18820.5 | 19263.2 | 3195.4 |
| markdown() | 34613.5 | 36509.9 | 3076.9 |
| MarkdownLoader.load | 69216.5 | 69534.8 | 17772.3 |
| MarkdownWriter.markdown(from:) | 18083.0 | 19008.9 | -4.8 |

### Long fence (one 3000-line fenced block)

168,987 UTF-16 source → 168,971 storage.

| case | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|
| keystroke — inside 3000-line fence | 21578.1 | 21828.8 | 25.7 |
| markdown() | 27477.0 | 27938.6 | 0.0 |
| MarkdownLoader.load | 25017.5 | 25128.4 | 6.6 |
| MarkdownWriter.markdown(from:) | 20147.8 | 20227.5 | 0.0 |

### Storage primitives (`StoragePrimitiveBench`, best per-op µs)

A plain `NSTextStorage` copy against the controller's storage. Reads match;
a 1-char edit (insert + delete) on the controller's storage pays the
normalizer, restyler and binding serialization.

| primitive | mixed plain | mixed controller | fence plain | fence controller |
|---|---:|---:|---:|---:|
| markdownParagraphRanges | 153.0 | 150.5 | 474.5 | 589.1 |
| enumerate markdownBlock | 183.8 | 184.2 | 0.7 | 0.7 |
| attributedSubstring(full) | 83.0 | 83.6 | 0.5 | 0.5 |
| attributes(at:) | 0.8 | 0.8 | 1.0 | 1.0 |
| 1-char edit | 37.9 | 36930.6 | 2.2 | 46072.7 |

## Legacy core

Recorded on `refactor-prose` after Stage 0 (`DocumentChange` made lazy,
schema validation gated on a handler). Reproduce with:

```sh
SWIFTPROSE_BENCH=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter KeystrokeBenchmarkTests
```

Machine: Apple Silicon, debug build (`swift test` builds `-Onone`), macOS 27.
Absolute numbers are only comparable against another debug run on the same
machine; the point is the delta across stages.

Each `keystroke` op is one `beginEditing / replaceCharacters(1 char) /
endEditing` on a headless controller — exactly what `NSTextView` does when
the user types. The undo that restores the fixture runs outside the timer.

### Mixed document (~1200 blocks: paragraphs, 3-deep lists, blockquotes, 8 fences)

83,692 UTF-16 source → 76,789 storage.

| case | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|
| keystroke — doc start | 2831.9 | 2894.8 | -2.0 |
| keystroke — mid paragraph | 2875.1 | 2921.2 | -1.9 |
| keystroke — nested list item | 2852.0 | 2892.2 | -2.0 |
| keystroke — inside fence | 2860.8 | 2883.9 | 8.4 |
| keystroke — tail | 2868.3 | 2906.0 | -1.9 |
| transaction — replaceText | 2708.2 | 2784.5 | 47.5 |
| markdown() | 47411.5 | 48171.8 | 6716.9 |
| document (cold) | 26337.2 | 26641.7 | 5.1 |

### Long fence (one 3000-line fenced block)

168,987 UTF-16 source → 168,974 storage.

| case | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|
| keystroke — inside 3000-line fence | 47.8 | 50.2 | 1.8 |
| markdown() | 23286.0 | 24563.2 | 122.0 |
| document (cold) | 21869.1 | 22354.7 | 0.0 |

### Reading

Keystroke cost tracks **block count**, not document length: 1200 blocks
costs ~2.9 ms per character, while a 169 KB document that is almost
entirely one code fence costs ~48 µs. That is the whole-document
`resegment()` pass — `enumerateBlockSpecs` over the whole storage on every
edit, rebuilding `blocks` — and it is Stage 4's target (removed there). Position within the document does
not matter, which is the signature of a whole-document scan.

`ProseDocument.from` (the `document (cold)` row) is ~26 ms on the mixed
fixture. After Stage 0 it no longer runs per keystroke: an
`onDocumentChange` subscriber that ignores `change.document` pays nothing,
and `validateAndRepair` only projects when `onSchemaDiagnostic` is
installed. `DocumentChangeLazinessTests` pins that.

`markdown()` at ~47 ms is the binding-push cost; hosts that bind `text`
pay it on the 80 ms `scheduleTextPush` timer, not per keystroke. That is
the binding contract, not a scan to remove.


---

### After Stage 3.1 (`ProseTextStorage`)

Same machine, same fixtures. `StoragePrimitiveBench` (also gated on
`SWIFTPROSE_BENCH`) compares `ProseTextStorage` against a plain
`NSTextStorage` holding identical content, which is how the numbers below
were attributed.

| case | Stage 0/2 median µs | after 3.1 | delta |
|---|---:|---:|---:|
| keystroke — mixed (5 positions) | 2832–2875 | 2953–3030 | +3% |
| transaction — replaceText | 2708 | 2882 | +6% |
| markdown() — mixed | 47412 | 50789 | +7% |
| document (cold) — mixed | 26337 | 29815 | +13% (Stage 2 span stamping) |
| keystroke — inside 3000-line fence | 47.8 | 63.5 | +33% |

Three findings from the subclass, each of which cost 5-150x before it was
fixed, kept here so they are not rediscovered:

1. **Read paths must be forwarded.** `NSAttributedString` implements
   `enumerateAttribute`, `attribute(_:at:…)`, and friends on top of the
   `attributes(at:effectiveRange:)` primitive, allocating a bridged Swift
   dictionary per run. Leaving them to the default cost **6x** on
   keystrokes and **11x** on `ProseDocument.from`. They now forward to the
   backing store directly.
2. **The backing store must be a concrete `NSTextStorage`, not an
   `NSMutableAttributedString`.** The latter's `replaceCharacters` is linear
   in attribute-run count — ~250 µs per keystroke on the syntax-highlighted
   3000-line fence, and growing. Its `string` also copies the whole buffer
   on every read, where `NSTextStorage.string` hands back the live one.
3. **Whole-document walks bypass the overrides** via `proseStorage.contents`.
   `ProseDocument.from` does two attribute lookups *per character*, so a
   76 KB document is 150k forwarded ObjC calls — worth ~4 ms and 31k
   allocations on `markdown()` alone.

Attribute fixing stays **eager** (`fixesAttributesLazily == false`, the
default for a subclass). Making it lazy is worth ~0 on the keystroke path
and breaks `editedRange` bookkeeping — edits accumulate instead of
resetting, which surfaces as a wrong `Step.replaceText` range in
`onDocumentChange`. Eager fixing also does the `.attachment`-on-non-FFFC
cleanup that `scrubTypedAttributes` does by hand.


---

### After Stage 4a (`resegment` removed)

| case | Stage 0 | after 3.1 | after 4a | vs Stage 0 |
|---|---:|---:|---:|---:|
| keystroke — doc start | 2832 | 2953 | 125.5 | **23x** |
| keystroke — mid paragraph | 2875 | 2979 | 86.2 | **33x** |
| keystroke — nested list item | 2852 | 2985 | 87.4 | **33x** |
| keystroke — inside fence | 2861 | 3030 | 134.9 | **21x** |
| keystroke — tail | 2868 | 2961 | 86.9 | **33x** |
| transaction — replaceText | 2708 | 2882 | 233.4 | **12x** |
| markdown() | 47412 | 50789 | 52602 | — |
| document (cold) | 26337 | 29815 | 31449 | — |
| keystroke — inside 3000-line fence | 47.8 | 63.5 | 53.9 | ~1x |

Every keystroke used to rebuild a whole-document `[BlockSegment]` list, which
is why cost tracked block count and not edit size. `blocks` is now derived on
read, and the only per-keystroke work left is a code-block rehighlight scoped
to the fence the edit landed in — nothing at all for an edit outside a fence.
Position still shows in the numbers (doc start and inside-fence are ~130 µs
against ~86 µs elsewhere) but the whole-document term is gone.

`markdown()` and `document` are unchanged: neither runs per keystroke.

#### The gate for 4b

| case | after 4a | after 4b |
|---|---:|---:|
| keystroke — no tree subscriber | 86 | 86 |
| keystroke — subscriber reads `change.document` | 31355 | **391** |

A host that mirrors the typed tree was paying a full `ProseDocument.from`
per keystroke — 365x the cost of one that doesn't, and essentially all of
that host's keystroke budget. That was the condition Stage 4b was gated on,
and it is met: the splice re-projects only the top-level blocks the edit
touched (plus one of slack on each side) and reuses the rest, an 80x
improvement. `IncrementalProjectionTests` compares the spliced tree against
a full re-projection — node ids and storage spans included — after every
edit of 60 randomized sequences.
