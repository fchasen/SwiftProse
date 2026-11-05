#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Code block highlighting (macOS, .serialized)")
@MainActor
struct CodeHighlightTests {
    static let document = """
    Intro x

    ```swift
    let x = 1
    let y = 2
    ```

    - item

      ```
      plain x
      ```

    ```js
    // x
    ```
    """

    private func highlighted(_ markdown: String, marker: Bool = false) -> (EditorHarness, FakeCodeHighlighter) {
        let harness = EditorHarness(markdown: markdown)
        let fake = FakeCodeHighlighter()
        fake.paintsResetMarker = marker
        harness.controller.setCodeBlockHighlighter(fake)
        return (harness, fake)
    }

    private func location(of needle: String, in harness: EditorHarness) -> Int {
        (harness.string as NSString).range(of: needle).location
    }

    @Test func loadResetsEachBlockOnce() {
        let fake = FakeCodeHighlighter()
        let controller = EditorController(markdown: Self.document, codeBlockHighlighter: fake)
        #expect(fake.sessions.count == 3)
        #expect(fake.sessions.map(\.language) == ["swift", nil, "js"])
        #expect(fake.sessions.map(\.resets) == [["let x = 1\nlet y = 2"], ["plain x"], ["// x"]])
        #expect(fake.editCount == 0)
        #expect(CodeHighlightProbe.mismatches(in: controller).isEmpty)

        let intro = (controller.textStorage.string as NSString).range(of: "Intro x")
        #expect(CodeHighlightProbe.colors(controller.textStorage, in: intro).allSatisfy { $0 == controller.theme.foregroundColor })

        controller.setMarkdown("```py\nx = 1\n```")
        #expect(fake.sessions.count == 4)
        #expect(fake.sessions[3].language == "py")
        #expect(fake.sessions[3].resets == ["x = 1"])
        #expect(controller.codeHighlighting.trackedKeys.count == 1)
    }

    @Test func attachingAndDetachingResetsAndRestoresBaseColor() {
        let harness = EditorHarness(markdown: Self.document)
        let fake = FakeCodeHighlighter()
        harness.controller.setCodeBlockHighlighter(fake)
        #expect(fake.resetCount == 3)
        harness.controller.setCodeBlockHighlighter(fake)
        #expect(fake.resetCount == 3)
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)

        harness.controller.setCodeBlockHighlighter(nil)
        let base = harness.controller.codeBaseColor
        for extent in CodeHighlighting.extents(in: harness.storage) {
            #expect(CodeHighlightProbe.colors(harness.storage, in: extent.body).allSatisfy { $0 == base })
        }
    }

    @Test func firstEditOnALaterLineSkipsTheStructureScan() {
        let (harness, fake) = highlighted(Self.document)
        let scans = harness.controller.codeHighlighting.structureScanCount
        harness.select(location(of: "let y", in: harness) + 4)
        harness.typeEach("x")
        #expect(harness.controller.codeHighlighting.structureScanCount == scans)
        #expect(fake.resetCount == 3)
    }

    @Test func topLevelCodeLinesLoadInNormalizedForm() {
        let harness = EditorHarness(markdown: "```swift\nlet x = 1\nlet y = 2\n```\n\n- item\n\n  ```\n  a\n  b\n  ```")
        let storage = harness.storage
        let topLevel = location(of: "let y", in: harness)
        let nested = location(of: "b", in: harness)
        let topBlock = storage.attribute(.markdownBlock, at: topLevel, effectiveRange: nil) as? MarkdownBlock
        let nestedBlock = storage.attribute(.markdownBlock, at: nested, effectiveRange: nil) as? MarkdownBlock
        #expect(topBlock?.isContinuation == false)
        #expect(nestedBlock?.isContinuation == true)
        #expect(harness.controller.markdown() == "```swift\nlet x = 1\nlet y = 2\n```\n\n- item\n\n  ```\n  a\n  b\n  ```")
    }

    @Test func typingFeedsBodyRelativeEditsAndRecolorsOnlyTheInvalidatedRange() {
        let (harness, fake) = highlighted(Self.document, marker: true)
        let swift = fake.sessions[0]
        let lineTwo = location(of: "let y", in: harness)
        let bodyStart = location(of: "let x", in: harness)
        harness.select(lineTwo + 4)
        harness.typeEach("x")

        #expect(swift.edits == [FakeCodeSession.Edit(
            range: NSRange(location: lineTwo + 4 - bodyStart, length: 0),
            replacement: "x",
            body: "let x = 1\nlet xy = 2"
        )])
        #expect(swift.invalidations == [NSRange(location: 10, length: 10)])
        #expect(fake.sessions.count == 3)
        #expect(fake.resetCount == 3)
        #expect(fake.sessions[1].edits.isEmpty && fake.sessions[2].edits.isEmpty)

        let storage = harness.storage
        let lineOne = NSRange(location: bodyStart, length: 9)
        #expect(CodeHighlightProbe.colors(storage, in: lineOne).allSatisfy { $0 == FakeCodeHighlighter.resetMarker })
        let edited = CodeHighlightProbe.colors(storage, in: NSRange(location: lineTwo, length: 10))
        #expect(edited.allSatisfy { $0 != FakeCodeHighlighter.resetMarker })
        #expect(edited[4] == FakeCodeHighlighter.identifier)
        #expect(edited[0] == harness.controller.codeBaseColor)
        let other = location(of: "plain x", in: harness)
        #expect(CodeHighlightProbe.colors(storage, in: NSRange(location: other, length: 7)).allSatisfy { $0 == FakeCodeHighlighter.resetMarker })

        harness.select(bodyStart + 4)
        let scans = harness.controller.codeHighlighting.structureScanCount
        harness.typeEach("x")
        #expect(harness.controller.codeHighlighting.structureScanCount == scans)
        #expect(swift.edits.last == FakeCodeSession.Edit(
            range: NSRange(location: 4, length: 0),
            replacement: "x",
            body: "let xx = 1\nlet xy = 2"
        ))
        #expect(swift.invalidations.last == NSRange(location: 0, length: 11))
        #expect(fake.sessions.count == 3)
    }

    @Test func incrementalColorsMatchAFullHighlightAcrossEdits() {
        let (harness, fake) = highlighted(Self.document)
        harness.select(location(of: "= 1", in: harness))
        harness.typeEach("# x ")
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        harness.insertNewline()
        harness.settle()
        harness.typeEach("x#")
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        harness.deleteBackward()
        harness.deleteBackward()
        harness.deleteBackward()
        harness.settle()
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        harness.select(location(of: "// x", in: harness) + 4)
        harness.typeEach("x")
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        #expect(fake.isConsistent)
        #expect(fake.sessions.count == 3)
    }

    @Test func splittingAndMergingABlockResetsItsSessions() {
        let (harness, fake) = highlighted("```\na x\nb\nc x\n```")
        #expect(fake.sessions.count == 1)
        harness.select(location(of: "b", in: harness))
        harness.step { harness.controller.toggleCodeBlock() }
        harness.settle()
        #expect(harness.markdown == "```\na x\n```\n\nb\n\n```\nc x\n```")
        #expect(fake.sessions.count == 3)
        #expect(fake.sessions[1].resets == ["a x"])
        #expect(fake.sessions[2].resets == ["c x"])
        #expect(harness.controller.codeHighlighting.trackedKeys.count == 2)
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)

        harness.select(location(of: "c x", in: harness) + 1)
        harness.typeEach("x")
        #expect(fake.sessions[2].edits.map(\.body) == ["cx x"])
        #expect(fake.sessions[1].edits.isEmpty)
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        harness.undo()
        harness.settle()

        harness.undo()
        harness.settle()
        #expect(harness.markdown == "```\na x\nb\nc x\n```")
        #expect(fake.sessions.count == 4)
        #expect(fake.sessions[3].resets == ["a x\nb\nc x"])
        #expect(harness.controller.codeHighlighting.trackedKeys.count == 1)
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        #expect(fake.isConsistent)
    }

    @Test func changingTheFenceLanguageResetsTheSession() {
        let (harness, fake) = highlighted("```swift\nlet x = 1\n```\n\nafter")
        let body = NSRange(location: 0, length: 10)
        guard let group = harness.block(at: 0)?.codeGroup else {
            Issue.record("expected a code block")
            return
        }
        harness.controller.editAttributes(in: body, actionName: "Language") { storage in
            storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .code(language: "python", group: group)), range: body)
        }
        harness.settle()
        #expect(fake.sessions.count == 2)
        #expect(fake.sessions[1].language == "python")
        #expect(fake.sessions[1].resets == ["let x = 1"])
        #expect(harness.markdown == "```python\nlet x = 1\n```\n\nafter")
    }

    @Test func fenceInputRuleStartsAFreshSession() {
        let (harness, fake) = highlighted("text")
        harness.select(harness.storage.length)
        harness.insertNewline()
        harness.typeEach("```rs")
        harness.insertNewline()
        harness.settle()
        harness.typeEach("x")
        #expect(fake.sessions.map(\.language) == ["rs"])
        #expect(fake.sessions.first?.resets == [""])
        #expect(fake.sessions.first?.edits.map(\.body) == ["x"])
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
    }

    @Test func undoAndRedoRestoreColors() {
        let (harness, fake) = highlighted("```\nlet x = 1\n```\n\nafter")
        harness.select(0)
        harness.typeEach("#")
        let line = NSRange(location: 0, length: 10)
        #expect(CodeHighlightProbe.colors(harness.storage, in: line).allSatisfy { $0 == FakeCodeHighlighter.comment })

        harness.undo()
        harness.settle()
        #expect(harness.string.hasPrefix("let x = 1"))
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        #expect(CodeHighlightProbe.colors(harness.storage, in: NSRange(location: 4, length: 1)) == [FakeCodeHighlighter.identifier])

        harness.redo()
        harness.settle()
        #expect(harness.string.hasPrefix("#let x = 1"))
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
        #expect(fake.sessions.count == 1)
        #expect(fake.isConsistent)
    }

    @Test func snapshotUndoRestoresColorsWithoutAHost() {
        let fake = FakeCodeHighlighter()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let controller = EditorController(
            markdown: "```\nlet x = 1\n```",
            codeBlockHighlighter: fake,
            undoManager: undoManager
        )
        controller.replace(
            NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "#", attributes: controller.typingAttributes(at: 0)),
            actionName: "Insert",
            selection: NSRange(location: 1, length: 0)
        )
        #expect(controller.textStorage.string == "#let x = 1")
        #expect(CodeHighlightProbe.mismatches(in: controller).isEmpty)
        undoManager.undo()
        #expect(controller.textStorage.string == "let x = 1")
        #expect(CodeHighlightProbe.mismatches(in: controller).isEmpty)
        #expect(fake.sessions.count == 1)
        #expect(fake.isConsistent)
    }

    @Test func deletingABlockDropsItsSession() {
        let (harness, _) = highlighted("```\na\n```\n\nmiddle\n\n```\nb\n```")
        #expect(harness.controller.codeHighlighting.trackedKeys.count == 2)
        let middle = location(of: "middle", in: harness)
        harness.select(NSRange(location: middle, length: harness.storage.length - middle))
        harness.deleteBackward()
        harness.settle()
        #expect(harness.controller.codeHighlighting.trackedKeys.count == 1)
    }

    @Test func themeChangeResetsSessionsAndRestylingKeepsHighlights() {
        let (harness, fake) = highlighted(Self.document)
        harness.select(location(of: "item", in: harness) + 4)
        harness.typeEach("s")
        #expect(fake.editCount == 0)
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)

        var theme = harness.controller.theme
        theme.codeBlock.textColor = .systemPurple
        harness.controller.theme = theme
        #expect(fake.sessions.count == 6)
        #expect(harness.controller.codeBaseColor == .systemPurple)
        #expect(CodeHighlightProbe.mismatches(in: harness.controller).isEmpty)
    }

    @Test func markdownOutputIsIdenticalWithAndWithoutAHighlighter() {
        let plain = EditorHarness(markdown: Self.document)
        let (colored, _) = highlighted(Self.document)
        #expect(colored.controller.serialize() == plain.controller.serialize())
        #expect(colored.markdown == Self.document)

        func apply(_ harness: EditorHarness) {
            harness.select(location(of: "= 2", in: harness))
            harness.typeEach("# x")
            harness.insertNewline()
            harness.settle()
            harness.typeEach("let z = x")
            harness.select(location(of: "Intro x", in: harness) + 7)
            harness.typeEach(" more")
            harness.select(location(of: "plain x", in: harness))
            harness.step { harness.controller.toggleCodeBlock() }
            harness.settle()
        }
        apply(plain)
        apply(colored)
        #expect(colored.string == plain.string)
        #expect(colored.controller.serialize() == plain.controller.serialize())
        #expect(colored.markdown == plain.markdown)
    }
}

@Suite("Code block highlighter contract (.serialized)")
@MainActor
struct CodeBlockHighlightingTests {
    private final class StubSession: CodeHighlightSession {
        let runs: [CodeHighlightRun]
        var bodies: [String] = []

        init(runs: [CodeHighlightRun]) {
            self.runs = runs
        }

        func reset(body: String) -> [CodeHighlightRun] {
            bodies.append(body)
            return runs
        }

        func didEdit(replacedRange: NSRange, replacement: String, body: String) -> CodeHighlightEdit {
            bodies.append(body)
            return CodeHighlightEdit(invalidatedRange: NSRange(location: 0, length: (body as NSString).length), runs: runs)
        }
    }

    private final class StubHighlighter: CodeBlockHighlighter {
        let runs: [CodeHighlightRun]
        var languages: [String?] = []
        var sessions: [StubSession] = []

        init(runs: [CodeHighlightRun] = []) {
            self.runs = runs
        }

        func makeSession(language: String?, body: String) -> CodeHighlightSession? {
            languages.append(language)
            let session = StubSession(runs: runs)
            sessions.append(session)
            return session
        }
    }

    private static let keyword = PlatformColor.systemPink

    private func color(_ controller: EditorController, at index: Int) -> PlatformColor? {
        controller.textStorage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? PlatformColor
    }

    private func bodyLocation(of needle: String, in controller: EditorController) -> Int {
        (controller.textStorage.string as NSString).range(of: needle).location
    }

    @Test func compilerForwardsLanguageAndBodyOnly() {
        let stub = StubHighlighter()
        _ = EditorController(markdown: "```swift\nlet x = 1\nlet y = 2\n```", codeBlockHighlighter: stub)
        #expect(stub.languages == ["swift"])
        #expect(stub.sessions.first?.bodies == ["let x = 1\nlet y = 2"])
    }

    @Test func keywordSpanColorsBodyTokens() {
        let stub = StubHighlighter(runs: [CodeHighlightRun(range: NSRange(location: 0, length: 3), color: Self.keyword)])
        let controller = EditorController(markdown: "Intro\n\n```swift\nlet x = 1\n```", codeBlockHighlighter: stub)
        let start = bodyLocation(of: "let", in: controller)
        #expect(start != NSNotFound)
        #expect(color(controller, at: start) == Self.keyword)
        #expect(color(controller, at: start + 2) == Self.keyword)
        #expect(color(controller, at: start + 3) == controller.codeBaseColor)
    }

    @Test func absentHighlighterLeavesForegroundUntouched() {
        let controller = EditorController(markdown: "```swift\nlet x = 1\n```")
        let start = bodyLocation(of: "let", in: controller)
        #expect(color(controller, at: start) == controller.codeBaseColor)
    }

    @Test func highlightingPreservesTheCodeBlock() {
        let stub = StubHighlighter(runs: [CodeHighlightRun(range: NSRange(location: 0, length: 3), color: Self.keyword)])
        let controller = EditorController(markdown: "```swift\nlet x = 1\n```", codeBlockHighlighter: stub)
        let start = bodyLocation(of: "let", in: controller)
        let block = controller.textStorage.markdownBlock(at: start)
        #expect(block?.isCode == true)
        #expect(block?.codeLanguage == "swift")
        #expect(controller.markdown() == "```swift\nlet x = 1\n```")
    }

    @Test func outOfBoundsSpansAreIgnored() {
        let stub = StubHighlighter(runs: [CodeHighlightRun(range: NSRange(location: 999, length: 5), color: Self.keyword)])
        let controller = EditorController(markdown: "```swift\nlet x = 1\n```\n\nafter", codeBlockHighlighter: stub)
        let start = bodyLocation(of: "let", in: controller)
        #expect(color(controller, at: start) == controller.codeBaseColor)
        let after = bodyLocation(of: "after", in: controller)
        #expect(color(controller, at: after) == controller.theme.foregroundColor)
    }

    @Test func typingOutsideCodeBlockSkipsHighlighter() {
        let stub = StubHighlighter()
        let harness = EditorHarness(markdown: "")
        harness.controller.setCodeBlockHighlighter(stub)
        harness.typeEach("hello world")
        #expect(stub.sessions.isEmpty)
        #expect(harness.markdown == "hello world")
    }
}
#endif
