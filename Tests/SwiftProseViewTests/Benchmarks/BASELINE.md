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
