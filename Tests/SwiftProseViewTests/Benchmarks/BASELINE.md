# Keystroke benchmark baseline

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

## Mixed document (~1200 blocks: paragraphs, 3-deep lists, blockquotes, 8 fences)

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

## Long fence (one 3000-line fenced block)

168,987 UTF-16 source → 168,974 storage.

| case | median µs | p90 µs | live blocks/op |
|---|---:|---:|---:|
| keystroke — inside 3000-line fence | 47.8 | 50.2 | 1.8 |
| markdown() | 23286.0 | 24563.2 | 122.0 |
| document (cold) | 21869.1 | 22354.7 | 0.0 |

## Reading

Keystroke cost tracks **block count**, not document length: 1200 blocks
costs ~2.9 ms per character, while a 169 KB document that is almost
entirely one code fence costs ~48 µs. That is `resegment()` —
`enumerateBlockSpecs` over the whole storage on every edit, rebuilding
`blocks` — and it is Stage 4's target. Position within the document does
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

## After Stage 3.1 (`ProseTextStorage`)

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

## After Stage 4a (`resegment` removed)

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

### The gate for 4b

| case | µs |
|---|---:|
| keystroke — no tree subscriber | 86 |
| keystroke — subscriber reads `change.document` | 31355 |

A host that mirrors the typed tree pays a full `ProseDocument.from` per
keystroke — 365x the cost of one that doesn't, and essentially all of that
host's keystroke budget. That is the condition Stage 4b was gated on.
