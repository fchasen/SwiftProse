#if canImport(UIKit) && os(iOS)
import Testing
import UIKit
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
@Suite("Code block highlighting (iOS)")
struct IOSCodeHighlightTests {
    @Test func typingAndUndoKeepHighlightsInSync() {
        let host = IOSHostHarness(markdown: "```\nlet x = 1\nlet y = 2\n```\n\nafter")
        let fake = FakeCodeHighlighter()
        host.controller.setCodeBlockHighlighter(fake)
        #expect(fake.resetCount == 1)
        #expect(CodeHighlightProbe.mismatches(in: host.controller).isEmpty)

        host.select(0)
        host.spin()
        host.type("#")
        host.spin()
        #expect(host.string.hasPrefix("#let x = 1"))
        #expect(fake.sessions.count == 1)
        #expect(fake.editCount >= 1)
        #expect(CodeHighlightProbe.colors(host.storage, in: NSRange(location: 0, length: 10)).allSatisfy { $0 == FakeCodeHighlighter.comment })
        #expect(CodeHighlightProbe.mismatches(in: host.controller).isEmpty)

        host.undoManager?.undo()
        host.spin()
        #expect(host.string.hasPrefix("let x = 1"))
        #expect(CodeHighlightProbe.mismatches(in: host.controller).isEmpty)
        #expect(fake.isConsistent)
        #expect(host.markdown == "```\nlet x = 1\nlet y = 2\n```\n\nafter")
    }
}
#endif
