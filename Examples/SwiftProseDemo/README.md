# SwiftProseDemo

End-to-end SwiftUI demo for SwiftProse, and the editing harness: a driver
that runs the real `ProseNSTextView` in the real app window, a seeded
fuzzer with strong oracles and shrinkable failures, and a catalogue of
scripted edit scenarios. References the local SPM package at `../..` and
links the `SwiftProse` and `SwiftProseTreeSitter` products.

## Targets

| target | what it is |
|---|---|
| `SwiftProseDemo` | the app (iOS 26 / macOS 26). Also carries the harness engine, so the app itself can fuzz and replay from the command line. |
| `SwiftProseDemoTests` | app-hosted XCTest bundle — the primary runner. In-process, no UI-automation permission. |
| `SwiftProseDemoUITests` | XCUITest bundle. Thin, permission-gated, skipped by the scheme. |

## Running

```sh
# scenarios + fuzz smoke + canaries — no permission needed
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj -scheme SwiftProseDemo \
  -destination 'platform=macOS' -only-testing:SwiftProseDemoTests

# one scenario
… -only-testing:SwiftProseDemoTests/ScenarioTests/test_lists_tab_indents_nested_item

# a longer fuzz from the test runner (hosted tests need the TEST_RUNNER_ prefix)
TEST_RUNNER_SWIFTPROSE_FUZZ_SEED=42 TEST_RUNNER_SWIFTPROSE_FUZZ_STEPS=5000 \
TEST_RUNNER_SWIFTPROSE_FUZZ_PROFILE=destroyer \
  … -only-testing:SwiftProseDemoTests/FuzzTests

# soak: build once, loop seeds; bundles under build/fuzz/
Scripts/fuzz.sh --seeds 1-50 --steps 3000 --profile mixed
Scripts/fuzz.sh --seeds 1-50 --app          # one process, no XCTest — faster

# replay / shrink a failure and watch it in the window
build/dd/…/SwiftProseDemo.app/Contents/MacOS/SwiftProseDemo \
  --harness replay --bundle build/fuzz/kitchen-sink-mixed-42 --stop-at 137
… --harness replay --bundle build/fuzz/kitchen-sink-mixed-42 --shrink

# the permission-gated layer, explicitly
… -only-testing:SwiftProseDemoUITests
```

A bare `xcodebuild test` runs `SwiftProseDemoTests` and skips
`SwiftProseDemoUITests`, so it is green on a machine that has not granted
UI automation.

`SWIFTPROSE_TRACE=1` prints every step of a harness run to stderr — the
only way to see inside a headless soak that stops making progress.

## How it is put together

```
SwiftProseDemo/
  Harness/
    EditOp.swift          Codable op vocabulary (also a member of the UITests bundle)
    Scenario.swift        scenario codec + marker parsing
    EditDriver.swift      runs ops against the app's real NSTextView
    Oracles.swift         invariant checks, tiered by cost
    ScenarioRunner.swift  marker → storage selection, and running one scenario
    FuzzEngine.swift      seeded generator, profiles, write-ahead log, failure bundle
    Shrinker.swift        ddmin over ops / doc / payloads
    StorageDump.swift     attribute-run dump and tree description
    HarnessLaunch.swift   --harness parsing, tracing
    HarnessRegistry.swift the @MainActor rendezvous the tests wait on
    HarnessView.swift     editor + inspector, the window under test
    HarnessCLI.swift      --harness fuzz | replay
    Corpus.swift          Fixtures access
  Fixtures/
    corpus/               real documents + corpus.json manifest + corpus-ledger.json
    scenarios/**/*.json   the scripted catalogue
SwiftProseDemoTests/
  HarnessTestSupport.swift  waitForEditor, canaries, reset(doc:)
  DriverCanaryTests.swift   the harness testing itself, plus the corpus ledger
  ScenarioTests.swift       one XCTest per scenario file, plus the recorder
  FuzzTests.swift           seeded fuzz smoke
Scripts/
  fuzz.sh                 build once, loop seeds, collect bundles
  make-corpus.sh          re-fetch the corpus at pinned commits; pandoc the books
  findings.sh             everything the catalogue knows is broken
```

### Why in-process

The harness drives AppKit's own input path — `insertText`,
`doCommand(by:)`, a synthesized `keyDown`, the menu `undo:` action — from
inside the app's process. The text view's delegate calls
`hostShouldChangeText`, storage processes the edit, and the controller
normalizes, restyles and records it, exactly as when a person types, with
no UI-automation permission and with Xcode breakpoints available.

Under test (or with `--harness`) the app's `DocumentGroup` is suppressed and
a single `HarnessView` window comes up in its place, so a run owns exactly
one window from launch. The choice is made with `defaultLaunchBehavior`,
since `SceneBuilder` lacks `buildEither`.

### Settling

Normalization and restyling run inside the storage edit. The controller
defers three things to the main queue: input rules (queued with
`deferEdit`), the `DocumentChange` flush, and the inline-content refresh.
`EditDriver.settle()` is two main-queue fences followed by
`controller.settleForHarness()`, which runs all three; `hasPendingWorkForHarness`
reports whether any is left. It is sub-millisecond and causally complete,
and it replaces every sleep. `type` settles after every character, so an
input rule fires between keystrokes as it does for a person.

Each op is one event for undo. The controller's undo manager groups by
event, and AppKit closes that group when `NSApplication` finishes an event,
which never happens inside a test method; `settle()` closes it the same way
AppKit's event loop does, so two ops never share an undo group by accident.

One consequence: **a harness run must be scheduled from outside a
main-queue block.** libdispatch drains the main queue one level deep, so a
nested run loop inside a main-queue block waits forever. `HarnessCLI`
schedules from a run-loop timer for exactly this reason, and `settle()`
says so on stderr the first time a fence times out.

### Seams

The harness uses `@_spi(Harness) import SwiftProse` for seven seams
on `EditorController` (`Sources/SwiftProseView/HarnessSPI.swift`):

| seam | use |
|---|---|
| `settleForHarness()` | run deferred input rules, the pending change flush and the inline-content refresh |
| `hasPendingWorkForHarness` | whether any of that is queued |
| `activeUndoManagerForHarness` | the undo manager edits register on: the host `NSTextView`'s on macOS, the controller's otherwise |
| `breakUndoCoalescingForHarness()` | an AppKit typing-coalescing boundary; the `closeHistoryGroup` op |
| `harnessEditRouteProbe` | reports the route each edit took: `typing`, `bulk`, `deletion`, `composition`, `command`, `inputRule`, `tableEdit`, `atomRedirect`, `paste`, `undo`, `redo`, `load` |
| `harnessNormalizationDrift()` | `nil` when normalizing and restyling a copy of storage changes nothing |
| `harnessTableGeometry(at:)` | row index, row count and column count of the table row at an offset |

`DriverCanaryTests` checks the route probe: `type` reports `typing`,
`typeBurst` reports `bulk`.

### Scenario files

```json
{ "name": "lists/tab-indents-nested-item", "tags": ["lists"],
  "intent": "Tab inside the second item indents it under the first.",
  "doc": "- one\n- tw<|>o\n",
  "ops": [ { "op": "key", "key": "Tab" },
           { "op": "expect", "blockKind": "paragraph list:bullet@2" } ],
  "expect": { "doc": "- one\n  - two\n" },
  "finally": ["tier0", "normalizer", "markdownFixpoint"] }
```

Markers are `<|>` for a caret and `<{` … `}>` for a selection. They sit in
*source* markdown, and loading that source moves everything after them:
delimiters disappear, escapes render as one character, atoms become U+FFFC,
table cells are tab-joined. So a marker's source offset differs from its
storage offset. `ScenarioRunner` recovers the real one with a sentinel
load: swap the markers for private-use scalars, load, read where they
landed, then load the clean source and assert the two agree. A marker
that changes how the line parses is reported as such.

#### Ops

| op | fields | does |
|---|---|---|
| `type` | `text` | types one character at a time through `insertText` |
| `typeBurst` | `text` | inserts the whole string in one `insertText` |
| `key` | `key` | a named key (`Enter`, `Backspace`, `Delete`, `Tab`, `Shift-Tab`, arrows, `Mod-b`, …; see `EditDriver.KeyTable`) through `doCommand(by:)` or `keyDown` |
| `undo` / `redo` | `n` | the menu `undo:` / `redo:` action, `n` times |
| `selectAll`, `copy`, `cut` | | the menu actions |
| `paste` | `text`, `html`, `plain` | pastes `text` and optional `html`; `plain` pastes through Paste and Match Style |
| `caret` / `select` | `at` / `from`, `to` | moves the selection to an anchor |
| `action` | `id`, `url`, `label`, `rows`, `columns` | performs an `EditorAction` by stable ID |
| `compose` | `interims`, `commit` | IME marked text, then a commit |
| `correct` | `find`, `replace` | an autocorrect-style replacement |
| `toggleCheckbox` | anchor | `controller.toggleCheckbox(at:)` |
| `load` | `markdown`, `keepHistory` | `setMarkdown`; clears the undo stack unless `keepHistory` |
| `closeHistoryGroup` | | `breakUndoCoalescingForHarness()` |
| `wait` | `ms` | a real delay, for coalescing timing |
| `expect` | see below | asserts mid-script |
| `check` | `oracles` | runs the named oracles now |

An anchor is `{ "at": n }`, `{ "before": "text" }`, `{ "after": "text" }`
(with `n` picking the occurrence), or `{ "block": i, "edge": "start" | "end" }`
for storage paragraph `i`, where `end` sits before its newline. A table row
is one paragraph; the alignment row is not in storage.

#### Expectations

`expect` (as an op or the scenario's final block) takes any of:

- `doc` — the markdown, compared with one trailing newline trimmed. `<|>`
  / `<{ }>` markers are stripped before comparing; assert the selection
  with `selection`
- `selection` — `[location, length]` in storage offsets
- `blockKind` — the caret paragraph's block, written
  `<leaf>[ quote:<n>][ list:<bullet|ordered>@<depth>][ task:<checked|unchecked>][ cont]`
  where leaf is `paragraph`, `heading(N)`, `code`, `code(<lang>)`,
  `thematicBreak`, `tableRow`, `tableRow(header)` or `html`. Examples:
  `heading(2)`, `paragraph list:ordered@1`, `paragraph quote:1 list:bullet@1 task:checked`,
  `code(swift)`.
- `marks` — the marks at the caret: `strong`, `emphasis`, `code`,
  `strikethrough`, `link`
- `canUndo`, `canRedo` — the active undo manager's state

`ScenarioTests` registers one XCTest method per file at suite-build time,
so `-only-testing:` addresses a scenario by name and a new file needs no
Swift.

To fill in or re-check expectations after editing the catalogue:

```sh
TEST_RUNNER_SWIFTPROSE_RECORD=1 TEST_RUNNER_SWIFTPROSE_RECORD_OUT=/tmp/recorded \
  … -only-testing:SwiftProseDemoTests/ScenarioTests/testRecordScenarios
```

It writes a copy of every scenario with the *observed* markdown and caret
`blockKind` and prints a report of where the author's `expect` and the
editor disagree, with the observed storage selection. A
disagreement is triaged by hand — either the expectation was wrong, or the
editor is — never resolved by overwriting the file.

### Oracles

| id | check | default cadence |
|---|---|---|
| `length` | text view length == storage length == `textContentStorage.documentRange` length; selection in bounds | every op |
| `vocabulary` | over the edited paragraph ±1: every character carries `.markdownBlock`, uniform across the paragraph including its `\n`; every `.markdownLiteral` run is one character (two UTF-16 units for a surrogate pair); every U+FFFC carries a `ProseSourceAttachment`; a `\t` carries `.markdownTableSeparator` exactly when it sits in a table row; U+2028 appears only outside code paragraphs; `textLists.count` equals the block's list depth | every op |
| `scalars` | every surrogate in storage is paired | every op |
| `groups` | code, table and quote groups are contiguous; rows of a table share separator count and alignments, `isHeader` only on the first; table geometry row index and row count agree | every 25 |
| `normalizer` | `harnessNormalizationDrift()` is `nil` | every 25 |
| `vocabularyFull` | `vocabulary` over the whole document | every 50 |
| `reader` | `StorageReader().document(from:)` twice is equal; writing that document equals `MarkdownWriter().markdown(from: storage)` | every 100 |
| `markdownFixpoint` | `MarkdownWriter().markdown(from: MarkdownLoader().load(markdown()))` equals `markdown()`, ignoring one trailing newline and whitespace at the edges of a paragraph, which the writer keeps and loading drops | end |
| `history` | undo through `activeUndoManagerForHarness` until `canUndo` is false (cap 64) restores the baseline markdown; redoing restores the `StorageDump` rows | end |
| `layout` | `ensureLayout` over the document range on `textLayoutManager` | end |
| `latency` | per-op p50 / p90 / p99 | end |

`tier0` is `length`, `vocabulary` and `scalars`.

Cadences are per-op counters, not wall clock, so a run does the same work
on any machine and a failure reproduces from the seed alone. They scale
down automatically for a large document.

### The corpus ledger

`Fixtures/corpus/` holds ~1.3 MB of real documents — Swift evolution
proposals, the Swift book, Node and Electron API docs, the Rust book,
several large READMEs, the CommonMark spec's own examples, hand-written
feature-dense files, and *Alice in Wonderland*. `corpus.json` pins each
fetched file to a commit; `Scripts/make-corpus.sh` reproduces it.

Real-world markdown does not yet come through the editor losslessly.
`corpus-ledger.json` records, per document, which oracles it currently
fails, and `testCorpusLedgerIsAccurate` fails when the ledger is wrong in
*either* direction — a document that used to pass an oracle stopped, or one
that is listed now passes and should come off. `corpus-ledger.txt` beside
it carries the full detail. Regenerate with
`TEST_RUNNER_SWIFTPROSE_UPDATE_LEDGER=1`.

### Known findings

The catalogue carries what the harness knows is wrong with the editor, so a
finding is a file rather than a note somewhere:

- `"xfail": "<fragment>"` — the scenario asserts the behaviour that *should*
  happen and the runner checks it still fails the same way. Fixing the bug
  trips the xfail, which is how the ledger stays honest.
- `"crashes": "<why>"` — the scenario traps the process. An Objective-C
  exception can't be caught in Swift, so `ScenarioTests` skips these with
  the reason and only `--harness replay` runs them. While any is open the
  fuzz smoke stands down (`SWIFTPROSE_FUZZ_ANYWAY=1` overrides), because a
  run that rediscovers a known trap takes every test after it down too.
- `FuzzTests.knownFindings` — open editor bugs the fuzz smoke tolerates,
  keyed by signature prefix with the reason. A run that hits only these
  passes and attaches them; `SWIFTPROSE_FUZZ_STRICT=1` fails on them. Take
  an entry out when its bug is fixed.

```sh
Scripts/findings.sh              # everything currently open
Scripts/findings.sh lists/       # one category
```

### Debugging a failure

1. A scenario failure names the op index, prints the expected / actual
   markdown diff, and attaches `storage.txt`, `ops.jsonl` and `after.md`
   to the xcresult. The failure message carries a one-line `-only-testing:`
   repro.
2. A fuzz failure prints its bundle path **at the start of the run**, so a
   crash still points at the write-ahead op log — whose last line is the op
   that did it. `FuzzTests` shrinks in-process before reporting, so the
   failure message carries a minimal op log and a ready-to-commit
   `regression.json`.
3. `--harness replay --bundle … --stop-at N` replays to just before the
   failure and leaves the window open to single-step from.
4. A crash can't be shrunk in process — the judge would take the trap with
   the candidate. `--harness replay --bundle … --shrink --expect crash`
   spawns a replay per candidate and reads its exit signal instead.
5. Promote the minimized log to `Fixtures/scenarios/regressions/`.

### XCUITest layer

`HarnessUITests` launches with `--harness ui`, replays a few flows through
real key events, and asserts against the `markdown-mirror` accessibility
value. **It is unverified on the development machine**: the XCUITest runner
cannot initialize there without the macOS UI-automation permission, so a
failure on an ungranted machine means "no coverage", not "broken editor".
The scheme skips the bundle; run it explicitly on CI or a machine that has
the permission.
