import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

/// The keystroke path no longer rebuilds a whole-document segment list.
/// What remains is a code-block rehighlight, scoped to the fence the edit
/// landed in and coalesced to one pass per runloop tick when hosted.
@Suite(.serialized) struct CodeBlockRehighlightScopingTests {

    private func edit(_ c: EditorController, at location: Int, _ text: String) {
        let storage = c.textStorage
        c.testSelection = NSRange(location: location, length: 0)
        c.nextEditHint = .typing
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
        c.testSelection = NSRange(location: location + (text as NSString).length, length: 0)
        storage.endEditing()
    }

    private func fenceOffset(_ c: EditorController, containing needle: String) -> Int {
        (c.textStorage.string as NSString).range(of: needle).location
    }

    @Test func headlessEditRehighlightsSynchronously() throws {
        let c = try EditorController(initialMarkdown: "```swift\nlet a = 1\n```\n")
        c.rehighlightRunCount = 0
        edit(c, at: fenceOffset(c, containing: "let a"), "x")
        #expect(c.rehighlightRunCount == 1,
                "no host attached — the pass runs before the edit returns")
    }

    @Test func rehighlightRangeIsExactlyTheFenceContainingTheEdit() throws {
        let c = try EditorController(initialMarkdown:
            "intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n```swift\nlet c = 3\n```\n\nouttro\n")
        var seen: [NSRange] = []
        c.rehighlightProbe = { seen.append($0) }

        let target = fenceOffset(c, containing: "let b")
        edit(c, at: target, "z")

        #expect(seen.count == 1, "one fence, one pass; got \(seen)")
        let range = try #require(seen.first)
        let text = (c.textStorage.string as NSString).substring(with: range)
        #expect(text.contains("let a"))
        #expect(text.contains("let b"))
        #expect(!text.contains("let c"), "the other fence is untouched; got \(text.debugDescription)")
        #expect(!text.contains("intro"))
    }

    @Test func fenceSpanningManyLinesIsRecoveredWhole() throws {
        var md = "```swift\n"
        for i in 0..<40 { md += "let v\(i) = \(i)\n" }
        md += "```\n"
        let c = try EditorController(initialMarkdown: md)
        var seen: [NSRange] = []
        c.rehighlightProbe = { seen.append($0) }

        edit(c, at: fenceOffset(c, containing: "let v20"), "q")

        let range = try #require(seen.first)
        let text = (c.textStorage.string as NSString).substring(with: range)
        #expect(text.contains("let v0"), "extends back to the fence start")
        #expect(text.contains("let v39"), "and forward to its end")
    }

    @Test func editInProseNextToAFenceDoesNotRehighlightIt() throws {
        let c = try EditorController(initialMarkdown: "```swift\nlet a = 1\n```\n\nprose\n")
        var seen: [NSRange] = []
        c.rehighlightProbe = { seen.append($0) }
        edit(c, at: fenceOffset(c, containing: "prose"), "!")
        #expect(seen.isEmpty, "an edit outside any fence has nothing to recolor; got \(seen)")
    }

    @Test func editInPlainDocumentNeverRehighlights() throws {
        let c = try EditorController(initialMarkdown: "# Title\n\nbody text\n")
        var seen: [NSRange] = []
        c.rehighlightProbe = { seen.append($0) }
        for i in 0..<5 { edit(c, at: 3 + i, "x") }
        #expect(seen.isEmpty)
    }

    #if canImport(AppKit) && os(macOS)
    @MainActor
    @Test func hostedBurstCoalescesToOnePass() async throws {
        let c = try EditorController(initialMarkdown: "```swift\nlet a = 1\n```\n")
        let textView = NSTextView(frame: .zero, textContainer: c.textContainer)
        c.hostTextView = textView
        c.rehighlightRunCount = 0

        let start = fenceOffset(c, containing: "let a")
        for i in 0..<5 {
            textView.setSelectedRange(NSRange(location: start + i, length: 0))
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: NSRange(location: start + i, length: 0), with: "x")
            textView.setSelectedRange(NSRange(location: start + i + 1, length: 0))
            c.textStorage.endEditing()
        }
        #expect(c.rehighlightRunCount == 0, "hosted edits defer")
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(c.rehighlightRunCount == 1,
                "a burst inside one tick shares one pass; got \(c.rehighlightRunCount)")
    }
    #endif

    // MARK: - blocks is on-demand now

    @Test func blocksReflectsStorageWithoutACachedRebuild() throws {
        let c = try EditorController(initialMarkdown: "# One\n\ntwo\n")
        let before = c.blocks
        #expect(before.first?.tag == .heading)
        edit(c, at: c.textStorage.length - 1, "\nthree")
        let after = c.blocks
        #expect(after.count == before.count + 1,
                "derived on read, got \(after.map(\.tag)) from \(before.map(\.tag))")
        #expect(after.last?.range.location ?? 0 > before.last?.range.location ?? 0)
    }
}
