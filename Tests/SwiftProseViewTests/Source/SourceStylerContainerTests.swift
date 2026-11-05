import Foundation
import Testing
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Source styler multi-line constructs")
@MainActor
struct SourceStylerMultiLineTests {
    @Test func everyLineOfASetextHeadingIsStyled() {
        let probe = SourceProbe("First line\nsecond line\n===\n\nafter")
        #expect(probe.traits("First").contains(.bold))
        #expect(probe.traits("second").contains(.bold))
        #expect(probe.isColor(probe.source.headingColor, "First line"))
        #expect(!probe.traits("after").contains(.bold))
    }

    @Test func typingAnUnderlineRestylesTheWholeParagraph() {
        let probe = SourceProbe("intro\n\none\ntwo\nthree\n\nafter")
        probe.edit(probe.range(of: "three"), "---")
        #expect(probe.traits("one").contains(.bold))
        #expect(probe.traits("two").contains(.bold))
        #expect(!probe.traits("intro").contains(.bold))
        #expect(probe.lastLines == ["one\n", "two\n", "---\n", "\n"])
        probe.edit(probe.range(of: "---"), "three")
        #expect(!probe.traits("one").contains(.bold))
        #expect(!probe.traits("two").contains(.bold))
    }

    @Test func aParagraphInterruptedBeforeTheUnderlineStaysPlain() {
        let probe = SourceProbe("one\n# head\ntwo\n===")
        #expect(!probe.traits("one").contains(.bold))
        #expect(probe.traits("two").contains(.bold))
    }

    @Test func setextHeadingsInsideQuotesAndListItems() {
        let quoted = SourceProbe("> Title\n> more\n> ===")
        #expect(quoted.traits("Title").contains(.bold))
        #expect(quoted.traits("more").contains(.bold))
        #expect(quoted.isColor(quoted.source.syntaxColor, "==="))
        let listed = SourceProbe("- Title\n  ---")
        #expect(listed.traits("Title").contains(.bold))
        #expect(listed.isColor(listed.source.syntaxColor, "---"))
        let outside = SourceProbe("- Title\n---")
        #expect(!outside.traits("Title").contains(.bold))
        let otherQuote = SourceProbe("> Title\n===")
        #expect(!otherQuote.traits("Title").contains(.bold))
    }

    @Test func tablesInsideQuotesAndListItems() {
        let quoted = SourceProbe("> a | b\n> --|--\n> 1 | 2\n\nafter | x")
        #expect(quoted.isColor(quoted.source.syntaxColor, "|", after: "> a "))
        #expect(quoted.isColor(quoted.source.syntaxColor, "--|--"))
        #expect(quoted.isColor(quoted.source.syntaxColor, "|", after: "> 1 "))
        #expect(!quoted.isColor(quoted.source.syntaxColor, "|", after: "after "))
        let listed = SourceProbe("- a | b\n  --|--\n  1 | 2\n- next | item")
        #expect(listed.isColor(listed.source.syntaxColor, "|", after: "- a "))
        #expect(listed.isColor(listed.source.syntaxColor, "--|--"))
        #expect(listed.isColor(listed.source.syntaxColor, "|", after: "  1 "))
        #expect(!listed.isColor(listed.source.syntaxColor, "|", after: "next "))
    }

    @Test func codeSpansCrossLinesWithinAParagraph() {
        let probe = SourceProbe("a `code\nspans` b *c*\n\nd")
        #expect(probe.isColor(probe.source.codeColor, "code"))
        #expect(probe.isColor(probe.source.codeColor, "spans"))
        #expect(probe.isColor(probe.source.syntaxColor, "`", after: "spans"))
        #expect(probe.controller.isLocationInCode(probe.location(of: "spans") + 1))
        #expect(!probe.controller.isLocationInCode(probe.location(of: " b") + 1))
        #expect(probe.traits("c", after: "b *").contains(.italic))
    }

    @Test func codeSpansStopAtTheParagraphAndNeedAnEqualRun() {
        let blank = SourceProbe("a `code\n\nnot` b")
        #expect(!blank.isColor(blank.source.codeColor, "code"))
        let unequal = SourceProbe("a `code\nnot`` b")
        #expect(!unequal.isColor(unequal.source.codeColor, "code"))
        let middle = SourceProbe("a ``x\nall code\ny`` z")
        #expect(middle.isColor(middle.source.codeColor, "all code"))
        #expect(!middle.isColor(middle.source.codeColor, "z"))
    }

    @Test func typingTheClosingBacktickRestylesEarlierLines() {
        let probe = SourceProbe("a `one\ntwo\nthree x")
        #expect(!probe.isColor(probe.source.codeColor, "one"))
        probe.insert("`", at: probe.location(of: " x"))
        #expect(probe.isColor(probe.source.codeColor, "one"))
        #expect(probe.isColor(probe.source.codeColor, "two"))
        #expect(probe.isColor(probe.source.codeColor, "three"))
        #expect(!probe.isColor(probe.source.codeColor, "x"))
        probe.edit(NSRange(location: probe.location(of: "` x"), length: 1), "")
        #expect(!probe.isColor(probe.source.codeColor, "one"))
        #expect(!probe.isColor(probe.source.codeColor, "two"))
    }
}

@Suite("Source code in containers")
@MainActor
struct SourceCodeContainerTests {
    @Test func quotedFenceBodiesLeaveOutTheQuoteMarkers() {
        let highlighter = FakeCodeHighlighter()
        let probe = SourceProbe("> ```py\n> x = 1\n>   # c\n> ```\nafter", highlighter: highlighter)
        #expect(highlighter.sessions.first?.resets == ["x = 1\n  # c"])
        #expect(probe.codeBodies == ["x = 1\n  # c"])
        #expect(probe.highlightMismatches().isEmpty)
        #expect(probe.isColor(probe.source.syntaxColor, ">", after: "py\n"))
        probe.insert("x", at: probe.location(of: "= 1") + 3)
        #expect(highlighter.resetCount == 1)
        #expect(highlighter.sessions.first?.edits.last?.replacement == "x")
        #expect(highlighter.isConsistent)
        #expect(probe.highlightMismatches().isEmpty)
    }

    @Test func listFenceBodiesLeaveOutTheItemIndent() {
        let highlighter = FakeCodeHighlighter()
        let probe = SourceProbe("- item\n\n  ```py\n  x\n    # y\n  ```\n- ```\n  z\n  ```", highlighter: highlighter)
        #expect(probe.codeBodies == ["x\n  # y", "z"])
        #expect(probe.highlightMismatches().isEmpty)
        probe.insert(" ", at: probe.location(of: "  x"))
        #expect(probe.codeBodies == [" x\n  # y", "z"])
        #expect(probe.highlightMismatches().isEmpty)
        #expect(highlighter.isConsistent)
    }

    @Test func indentedCodeBodiesLeaveOutTheIndent() {
        let highlighter = FakeCodeHighlighter()
        let probe = SourceProbe("para\n\n    x = 1\n      # c\n", highlighter: highlighter)
        #expect(probe.codeBodies == ["x = 1\n  # c"])
        #expect(probe.highlightMismatches().isEmpty)
    }

    @Test func quotedFenceEndsWithTheQuote() {
        let probe = SourceProbe("> ```\n> a\nb\n\nc")
        #expect(probe.isCodeBlock("a"))
        #expect(!probe.isCodeBlock("b"))
        #expect(!probe.isCodeBlock("c"))
        let listed = SourceProbe("- ```\n  a\nb")
        #expect(listed.isCodeBlock("a"))
        #expect(!listed.isCodeBlock("b"))
    }
}
