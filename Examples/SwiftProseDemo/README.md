# SwiftProseDemo

End-to-end SwiftUI demo for SwiftProse, and the editing harness: a driver
that runs the real `ProseNSTextView` in the real app window, a seeded
fuzzer with strong oracles and shrinkable failures, and a catalogue of
scripted edit scenarios. References the local SPM package at `../..`.

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
inside the app's process. That means the delegate stamps an `EditHint`,
`ProseTextStorage` captures a pre-image, and `didChangeText()` drains the
envelope, exactly as when a person types, with no UI-automation permission
and with Xcode breakpoints available.

Under test (or with `--harness`) the app's `DocumentGroup` is suppressed and
a single `HarnessView` window comes up instead: no Cmd-N, no restoration
race, no second window. `SceneBuilder` has no `buildEither`, so the choice
is made with `defaultLaunchBehavior` rather than an `if`.

### Settling

Hosted drains are synchronous — `didChangeText()` closes the envelope
before returning. What is deferred is `main.async` work: typing attributes,
the code-block rehighlight, the background layer, the binding push. So
`EditDriver.settle()` is two main-queue fences plus an explicit drain,
which is sub-millisecond and causally complete. It replaces every sleep.

One consequence: **a harness run must not be scheduled from inside a
main-queue block.** libdispatch will not drain the main queue re-entrantly,
so a nested run loop can never settle. `HarnessCLI` schedules from a
run-loop timer for exactly this reason, and `settle()` says so on stderr the
first time a fence times out.

### Scenario files

```json
{ "name": "lists/tab-indents-nested-item", "tags": ["lists"],
  "intent": "Tab inside the second item indents it under the first.",
  "doc": "- one\n- tw<|>o\n",
  "ops": [ { "op": "key", "key": "Tab" } ],
  "expect": { "doc": "- one\n  - two\n" },
  "finally": ["tier0", "projection", "markdownFixpoint"] }
```

Markers are `<|>` for a caret and `<{` … `}>` for a selection. They sit in
*source* markdown, and compiling that source moves everything after them by
however many characters the presentation markers add (`"1. "`, a bullet
glyph plus tab, a checkbox) — so a marker's source offset is not its
storage offset. `ScenarioRunner` recovers the real one with a sentinel
compile: swap the markers for private-use scalars, compile, read where they
landed, then compile the clean source and assert the two agree. A marker
that changes how the line parses is reported as such rather than silently
producing a wrong offset.

`ScenarioTests` registers one XCTest method per file at suite-build time,
so `-only-testing:` addresses a scenario by name and a new file needs no
Swift.

To fill in or re-check expectations after editing the catalogue:

```sh
TEST_RUNNER_SWIFTPROSE_RECORD=1 TEST_RUNNER_SWIFTPROSE_RECORD_OUT=/tmp/recorded \
  … -only-testing:SwiftProseDemoTests/ScenarioTests/testRecordScenarios
```

It writes a copy of every scenario with the *observed* result and prints a
report of where the author's `expect` and the editor disagree. A
disagreement is triaged by hand — either the expectation was wrong, or the
editor is — never resolved by overwriting the file.

### Oracles

| id | check | default cadence |
|---|---|---|
| `diagnostics` | collected `SpecDiagnostic`s | every op |
| `length` | `document.contentLength == storage.length == view.string.length`, selection in bounds | every op |
| `specLocal` | `SpecValidator` over the edited paragraph ±1 | every op |
| `coverage` | every attribute run carries `proseNodePath` | every 10 |
| `schema` | `SchemaValidator` over the projected tree | every 25 |
| `projection` | spliced tree ≡ a fresh full projection | every 25 |
| `specFull` | `SpecValidator` over the whole document | every 50 |
| `offsets` | `resolve` at every block boundary + 256 samples | every 100 |
| `markdownFixpoint` | `EditorController(initialMarkdown: markdown()).markdown() == markdown()` | end |
| `pmJSON` | export → load headless → export | end |
| `history` | undo N / redo N restores string + specs + marks | end |
| `layout` | `ensureLayout` over the document range | end |
| `latency` | per-op p50 / p90 / p99 | end |

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
