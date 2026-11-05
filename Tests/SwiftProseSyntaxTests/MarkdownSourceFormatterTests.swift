import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport

enum SourceMarks {
    static let open: Character = "⟨"
    static let close: Character = "⟩"

    static func parse(_ marked: String) -> (String, NSRange) {
        var text = ""
        var start = 0
        var end = 0
        for character in marked {
            if character == open {
                start = (text as NSString).length
            } else if character == close {
                end = (text as NSString).length
            } else {
                text.append(character)
            }
        }
        return (text, NSRange(location: start, length: end - start))
    }

    static func render(_ text: String, _ selection: NSRange) -> String {
        let ns = text as NSString
        return ns.substring(to: selection.location) + String(open)
            + ns.substring(with: selection) + String(close)
            + ns.substring(from: NSMaxRange(selection))
    }
}

private let formatter = MarkdownSourceFormatter()

private func apply(_ action: EditorAction, _ marked: String) -> String? {
    let (text, selection) = SourceMarks.parse(marked)
    guard let edit = formatter.edit(for: action, in: text, selection: selection) else { return nil }
    let result = edit.applied(to: text)
    let length = (result as NSString).length
    #expect(NSMaxRange(edit.range) <= (text as NSString).length)
    #expect(NSMaxRange(edit.selection) <= length)
    return SourceMarks.render(result, edit.selection)
}

private func active(_ action: EditorAction, _ marked: String) -> Bool {
    let (text, selection) = SourceMarks.parse(marked)
    return formatter.isActive(action, in: text, selection: selection)
}

private func enabled(_ action: EditorAction, _ marked: String) -> Bool {
    let (text, selection) = SourceMarks.parse(marked)
    return formatter.canPerform(action, in: text, selection: selection)
}

private func roundTrip(_ action: EditorAction, _ before: String, _ after: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(apply(action, before) == after, sourceLocation: sourceLocation)
    #expect(apply(action, after) == before, sourceLocation: sourceLocation)
}

@Suite struct SourceFormatterBoldTests {
    @Test func wrapsAndUnwrapsSelection() {
        roundTrip(.bold, "a ⟨word⟩ b", "a **⟨word⟩** b")
        #expect(active(.bold, "a **⟨word⟩** b"))
        #expect(!active(.bold, "a ⟨word⟩ b"))
    }

    @Test func removesDelimitersIncludedInSelection() {
        #expect(apply(.bold, "a ⟨**word**⟩ b") == "a ⟨word⟩ b")
        #expect(active(.bold, "a ⟨**word**⟩ b"))
    }

    @Test func trimsWhitespaceAtSelectionEdges() {
        #expect(apply(.bold, "a⟨ word ⟩b") == "a **⟨word⟩** b")
    }

    @Test func emptySelectionInsertsAndRemovesPair() {
        roundTrip(.bold, "a ⟨⟩ b", "a **⟨⟩** b")
        #expect(active(.bold, "a **⟨⟩** b"))
    }

    @Test func caretAtSpanEndStepsOut() {
        #expect(apply(.bold, "**word⟨⟩** x") == "**word**⟨⟩ x")
        #expect(active(.bold, "**word⟨⟩**"))
        #expect(!active(.bold, "**⟨⟩word**"))
    }

    @Test func caretInsideSpanRemovesSpan() {
        #expect(apply(.bold, "a **wo⟨⟩rd** b") == "a wo⟨⟩rd b")
    }

    @Test func partialSelectionSplitsSpan() {
        #expect(apply(.bold, "**foo ⟨bar⟩ baz**") == "**foo** ⟨bar⟩ **baz**")
        #expect(apply(.bold, "**⟨foo⟩ bar**") == "⟨foo⟩ **bar**")
        #expect(apply(.bold, "**foo ⟨bar⟩**") == "**foo** ⟨bar⟩")
    }

    @Test func overlappingSpanMerges() {
        #expect(apply(.bold, "⟨**foo** bar⟩") == "**⟨foo bar⟩**")
        #expect(apply(.bold, "**foo** ⟨bar⟩ baz") == "**foo** **⟨bar⟩** baz")
        #expect(apply(.bold, "**fo⟨o** ba⟩r") == "**⟨foo ba⟩**r")
    }

    @Test func multiLineSelectionWrapsEachLine() {
        roundTrip(.bold, "⟨one\ntwo⟩", "**⟨one**\n**two⟩**")
        #expect(apply(.bold, "⟨one\n\ntwo⟩") == "**⟨one**\n\n**two⟩**")
        #expect(!active(.bold, "**⟨one**\ntwo⟩"))
    }

    @Test func skipsBlockPrefixes() {
        #expect(apply(.bold, "⟨- item⟩") == "- **⟨item⟩**")
        #expect(apply(.bold, "⟨# Title⟩") == "# **⟨Title⟩**")
        #expect(apply(.bold, "⟨> - [ ] task⟩") == "> - [ ] **⟨task⟩**")
        #expect(apply(.bold, "-⟨⟩ item") == "- **⟨⟩**item")
    }

    @Test func nestedWithItalic() {
        roundTrip(.italic, "**⟨word⟩**", "***⟨word⟩***")
        roundTrip(.bold, "*⟨word⟩*", "***⟨word⟩***")
        #expect(active(.bold, "***⟨word⟩***"))
        #expect(active(.italic, "***⟨word⟩***"))
        #expect(apply(.bold, "***⟨word⟩***") == "*⟨word⟩*")
        #expect(apply(.italic, "***⟨word⟩***") == "**⟨word⟩**")
    }

    @Test func underscoreDelimiters() {
        #expect(active(.bold, "__⟨word⟩__"))
        #expect(apply(.bold, "__⟨word⟩__") == "⟨word⟩")
        #expect(active(.italic, "_⟨word⟩_"))
        #expect(!active(.italic, "snake_⟨case⟩_name"))
    }

    @Test func escapedDelimitersAreLiteral() {
        #expect(!active(.italic, "\\*⟨word⟩\\*"))
    }

    @Test func emojiUsesUTF16Ranges() {
        roundTrip(.bold, "👍 ⟨word⟩ 🎉", "👍 **⟨word⟩** 🎉")
        roundTrip(.bold, "a ⟨👍🏽⟩ b", "a **⟨👍🏽⟩** b")
        roundTrip(.italic, "⟨家族👨‍👩‍👧⟩", "*⟨家族👨‍👩‍👧⟩*")
        #expect(active(.bold, "**👍⟨⟩**"))
    }

    @Test func disabledInsideFencedCode() {
        #expect(!enabled(.bold, "```\nco⟨de⟩\n```"))
        #expect(!enabled(.link, "```\n⟨⟩\n```"))
        #expect(apply(.bold, "```\nco⟨de⟩\n```") == nil)
        #expect(enabled(.bold, "⟨text\n```\ncode⟩\n```"))
    }
}

@Suite struct SourceFormatterInlineKindsTests {
    @Test func italic() {
        roundTrip(.italic, "a ⟨word⟩ b", "a *⟨word⟩* b")
        roundTrip(.italic, "⟨⟩", "*⟨⟩*")
        #expect(apply(.italic, "**⟨⟩**") == "***⟨⟩***")
        #expect(!active(.italic, "**⟨⟩**"))
    }

    @Test func strikethrough() {
        roundTrip(.strikethrough, "a ⟨word⟩ b", "a ~~⟨word⟩~~ b")
        roundTrip(.strikethrough, "x⟨⟩", "x~~⟨⟩~~")
        #expect(active(.strikethrough, "~⟨word⟩~"))
        #expect(!active(.strikethrough, "~~~⟨word⟩~~~"))
    }

    @Test func codeSpan() {
        roundTrip(.codeSpan, "a ⟨word⟩ b", "a `⟨word⟩` b")
        roundTrip(.codeSpan, "x ⟨⟩", "x `⟨⟩`")
        #expect(apply(.codeSpan, "`co⟨⟩de`") == "co⟨⟩de")
        #expect(apply(.codeSpan, "`code⟨⟩` x") == "`code`⟨⟩ x")
    }

    @Test func codeSpanFenceGrowsForBackticks() {
        roundTrip(.codeSpan, "use ⟨a`b⟩ here", "use ``⟨a`b⟩`` here")
        roundTrip(.codeSpan, "use ⟨a``b⟩ here", "use ```⟨a``b⟩``` here")
        roundTrip(.codeSpan, "⟨`tick⟩", "`` ⟨`tick⟩ ``")
        #expect(active(.codeSpan, "`` ⟨`tick⟩ ``"))
    }

    @Test func codeSpanContentsAreOpaqueToEmphasis() {
        #expect(!active(.italic, "`*⟨a⟩*`"))
        #expect(active(.codeSpan, "`*⟨a⟩*`"))
    }

    @Test func delimitersInsideASpanAreContent() {
        #expect(active(.codeSpan, "`a`⟨⟩`b`"))
        #expect(apply(.codeSpan, "`a`⟨⟩`b`") == "a`⟨⟩`b")
        #expect(active(.italic, "*a*⟨⟩*b*"))
        #expect(apply(.italic, "**a *⟨⟩* b**") == "**a ⟨⟩ b**")
    }

    @Test func linkDestinationsAreOpaque() {
        #expect(!active(.italic, "[⟨x⟩](https://a_b_c)"))
        #expect(active(.italic, "_[⟨x⟩](https://a_b)_"))
    }
}

@Suite struct SourceFormatterHeadingTests {
    @Test func setSwapRemove() {
        #expect(apply(.heading(level: 1), "⟨Title⟩") == "# ⟨Title⟩")
        #expect(apply(.heading(level: 2), "# ⟨Title⟩") == "## ⟨Title⟩")
        #expect(apply(.heading(level: 2), "## ⟨Title⟩") == "⟨Title⟩")
        #expect(apply(.heading(level: 3), "Ti⟨⟩tle") == "### Ti⟨⟩tle")
    }

    @Test func emptyLine() {
        roundTrip(.heading(level: 3), "⟨⟩", "### ⟨⟩")
        #expect(apply(.heading(level: 1), "a\n⟨⟩\nb") == "a\n# ⟨⟩\nb")
    }

    @Test func multipleLines() {
        roundTrip(.heading(level: 2), "⟨a\nb⟩", "⟨## a\n## b⟩")
        #expect(apply(.heading(level: 1), "⟨a\n\nb⟩") == "⟨# a\n\n# b⟩")
        #expect(apply(.heading(level: 1), "⟨# a\nb⟩") == "⟨# a\n# b⟩")
    }

    @Test func activeState() {
        #expect(active(.heading(level: 2), "## ⟨x⟩"))
        #expect(!active(.heading(level: 1), "## ⟨x⟩"))
        #expect(!active(.heading(level: 2), "⟨## x\ny⟩"))
        #expect(!active(.heading(level: 1), "#hashtag⟨⟩"))
    }

    @Test func keepsContainers() {
        #expect(apply(.heading(level: 1), "- ⟨item⟩") == "- # ⟨item⟩")
        #expect(apply(.heading(level: 1), "> ⟨q⟩") == "> # ⟨q⟩")
        #expect(apply(.heading(level: 1), "- [ ] ⟨task⟩") == "- # ⟨task⟩")
    }

    @Test func caretInPrefixMovesToContent() {
        #expect(apply(.heading(level: 2), "#⟨⟩ Title") == "## ⟨⟩Title")
    }
}

@Suite struct SourceFormatterListTests {
    @Test func bulletToggle() {
        roundTrip(.unorderedList, "⟨a\nb⟩", "⟨- a\n- b⟩")
        roundTrip(.unorderedList, "⟨⟩", "- ⟨⟩")
        #expect(apply(.unorderedList, "⟨a\n\nb⟩") == "⟨- a\n\n- b⟩")
        #expect(apply(.unorderedList, "* ⟨a⟩") == "⟨a⟩")
    }

    @Test func orderedToggleRenumbers() {
        roundTrip(.orderedList, "⟨a\nb\nc⟩", "⟨1. a\n2. b\n3. c⟩")
        #expect(apply(.orderedList, "⟨- a\n- b⟩") == "⟨1. a\n2. b⟩")
        #expect(apply(.orderedList, "⟨1. a\nb⟩") == "⟨1. a\n2. b⟩")
        #expect(apply(.orderedList, "⟨5. a\n9. b⟩") == "⟨a\nb⟩")
    }

    @Test func orderedNumbersPerIndentLevel() {
        #expect(apply(.orderedList, "⟨- a\n  - b\n  - c\n- d⟩") == "⟨1. a\n  1. b\n  2. c\n2. d⟩")
    }

    @Test func orderedContinuesPreviousItems() {
        #expect(apply(.orderedList, "1. a\n2. b\n⟨c⟩") == "1. a\n2. b\n3. ⟨c⟩")
        #expect(apply(.orderedList, "- a\n⟨c⟩") == "- a\n1. ⟨c⟩")
    }

    @Test func bulletSwapsFromOrderedAndTask() {
        #expect(apply(.unorderedList, "⟨1. a\n2. b⟩") == "⟨- a\n- b⟩")
        #expect(apply(.unorderedList, "- [x] ⟨a⟩") == "- ⟨a⟩")
        #expect(apply(.orderedList, "- [ ] ⟨a⟩") == "1. ⟨a⟩")
    }

    @Test func taskToggle() {
        roundTrip(.taskList, "⟨a⟩", "- [ ] ⟨a⟩")
        #expect(apply(.taskList, "- ⟨a⟩") == "- [ ] ⟨a⟩")
        #expect(apply(.taskList, "1. ⟨a⟩") == "1. [ ] ⟨a⟩")
        #expect(apply(.taskList, "- [x] ⟨a⟩") == "⟨a⟩")
        #expect(apply(.taskList, "⟨- [x] a\nb⟩") == "⟨- [x] a\n- [ ] b⟩")
        #expect(apply(.taskList, "# ⟨Heading⟩") == "- [ ] ⟨Heading⟩")
    }

    @Test func preservesQuoteAndIndentation() {
        roundTrip(.unorderedList, "> ⟨a⟩", "> - ⟨a⟩")
        #expect(apply(.orderedList, "⟨- a\n  - b⟩") == "⟨1. a\n  1. b⟩")
        #expect(apply(.unorderedList, "⟨- a\n  - b⟩") == "⟨a\n  b⟩")
    }

    @Test func activeState() {
        #expect(active(.unorderedList, "- ⟨a⟩"))
        #expect(!active(.unorderedList, "- [ ] ⟨a⟩"))
        #expect(active(.taskList, "- [ ] ⟨a⟩"))
        #expect(active(.orderedList, "3) ⟨a⟩"))
        #expect(!active(.orderedList, "⟨1. a\nb⟩"))
        #expect(active(.unorderedList, "⟨- a\n  continued⟩"))
        #expect(!active(.unorderedList, "---⟨⟩"))
    }

    @Test func continuationLinesAreLeftAlone() {
        #expect(apply(.unorderedList, "⟨- a\n  continued⟩") == "⟨a\n  continued⟩")
    }
}

@Suite struct SourceFormatterQuoteTests {
    @Test func toggle() {
        roundTrip(.blockquote, "⟨a\nb⟩", "⟨> a\n> b⟩")
        roundTrip(.blockquote, "⟨a\n\nb⟩", "⟨> a\n>\n> b⟩")
        roundTrip(.blockquote, "⟨⟩", "> ⟨⟩")
    }

    @Test func removesOneLevel() {
        #expect(apply(.blockquote, "> > ⟨a⟩") == "> ⟨a⟩")
        #expect(apply(.blockquote, ">⟨a⟩") == "⟨a⟩")
    }

    @Test func activeState() {
        #expect(active(.blockquote, "> ⟨a⟩"))
        #expect(active(.blockquote, "⟨> a\n\n> b⟩"))
        #expect(!active(.blockquote, "⟨> a\nb⟩"))
    }

    @Test func wrapsCode() {
        #expect(enabled(.blockquote, "```\n⟨x⟩\n```"))
        #expect(apply(.blockquote, "⟨```\nx\n```⟩") == "⟨> ```\n> x\n> ```⟩")
    }
}

@Suite struct SourceFormatterCodeBlockTests {
    @Test func wrapAndUnwrap() {
        roundTrip(.codeBlock, "⟨a\nb⟩", "```\n⟨a\nb⟩\n```")
        roundTrip(.codeBlock, "x\n⟨a⟩\ny", "x\n```\n⟨a⟩\n```\ny")
    }

    @Test func emptyLineOpensFence() {
        #expect(apply(.codeBlock, "⟨⟩") == "```\n⟨⟩\n```")
        #expect(apply(.codeBlock, "```\n⟨⟩\n```") == "⟨⟩")
    }

    @Test func caretInsideRemovesFence() {
        #expect(apply(.codeBlock, "p\n```swift\nco⟨⟩de\n```\nq") == "p\nco⟨⟩de\nq")
        #expect(apply(.codeBlock, "```\nabc⟨⟩") == "abc⟨⟩")
        #expect(apply(.codeBlock, "⟨~~~\nx\n~~~⟩") == "⟨x⟩")
    }

    @Test func fenceGrowsPastContentFences() {
        #expect(apply(.codeBlock, "⟨intro\n````\n```\n````⟩") == "````\n⟨intro\n```⟩\n````")
        #expect(apply(.codeBlock, "⟨```js\nx\n```⟩") == "⟨x⟩")
    }

    @Test func mergesPartiallySelectedBlocks() {
        #expect(apply(.codeBlock, "⟨intro\n```\ncode⟩\n```") == "```\n⟨intro\ncode⟩\n```")
    }

    @Test func keepsQuotePrefixOnFences() {
        roundTrip(.codeBlock, "⟨> a\n> b⟩", "> ```\n⟨> a\n> b⟩\n> ```")
    }

    @Test func activeState() {
        #expect(active(.codeBlock, "```\n⟨x⟩\n```"))
        #expect(active(.codeBlock, "``⟨⟩`\nx\n```"))
        #expect(!active(.codeBlock, "⟨x⟩"))
        #expect(!active(.codeBlock, "⟨p\n```\nx⟩\n```"))
    }
}

@Suite struct SourceFormatterLinkTests {
    @Test func wrapsSelectionWithPlaceholder() {
        #expect(apply(.link, "a ⟨word⟩ b") == "a [word](⟨url⟩) b")
        #expect(apply(.link, "a ⟨⟩") == "a [link](⟨url⟩)")
        #expect(apply(.link(url: nil, label: "docs"), "⟨⟩") == "[docs](⟨url⟩)")
    }

    @Test func usesProvidedURL() {
        #expect(apply(.link(url: "https://x.test"), "⟨word⟩") == "[word](https://x.test)⟨⟩")
        #expect(apply(.link(url: "https://x.test", label: "X"), "a ⟨⟩") == "a [X](https://x.test)⟨⟩")
        #expect(apply(.link(url: "https://x.test"), "⟨⟩") == "[https://x.test](https://x.test)⟨⟩")
    }

    @Test func selectedURLBecomesDestination() {
        #expect(apply(.link, "⟨https://example.com⟩") == "[https://example.com](https://example.com)⟨⟩")
    }

    @Test func unlinks() {
        #expect(apply(.link, "[wo⟨⟩rd](https://x)") == "wo⟨⟩rd")
        #expect(apply(.link, "a [⟨word⟩](https://x) b") == "a ⟨word⟩ b")
        #expect(apply(.link, "[word](https://x)⟨⟩ b") == "word⟨⟩ b")
    }

    @Test func replacesDestination() {
        #expect(apply(.link(url: "https://new"), "[⟨word⟩](https://old)") == "[⟨word⟩](https://new)")
    }

    @Test func activeState() {
        #expect(active(.link, "[word](u)⟨⟩"))
        #expect(active(.link, "[wo⟨rd⟩](u)"))
        #expect(!active(.link, "⟨⟩[word](u)"))
        #expect(!active(.link, "![a⟨⟩](b)"))
        #expect(active(.link, "[a](<b c>)⟨⟩"))
        #expect(active(.link, "[a](b \"title\")⟨⟩"))
    }

    @Test func emoji() {
        #expect(apply(.link, "👍 ⟨🎉⟩") == "👍 [🎉](⟨url⟩)")
    }
}

@Suite struct SourceFormatterHorizontalRuleTests {
    @Test func insertsWithBlankLines() {
        #expect(apply(.horizontalRule, "para⟨⟩") == "para\n\n---\n⟨⟩")
        #expect(apply(.horizontalRule, "⟨⟩") == "---\n⟨⟩")
        #expect(apply(.horizontalRule, "a⟨⟩\nb") == "a\n\n---\n⟨⟩\nb")
        #expect(apply(.horizontalRule, "a\n\n⟨⟩\n\nb") == "a\n\n---\n⟨⟩\nb")
        #expect(apply(.horizontalRule, "p⟨a⟩rt\n\nnext") == "part\n\n---\n⟨⟩\nnext")
        #expect(apply(.horizontalRule, "a\n⟨⟩") == "a\n\n---\n⟨⟩")
    }

    @Test func neverActiveAndDisabledInCode() {
        #expect(!active(.horizontalRule, "---\n⟨⟩"))
        #expect(!enabled(.horizontalRule, "```\n⟨⟩\n```"))
    }
}

@Suite struct SourceFormatterIndentTests {
    @Test func bulletRoundTrip() {
        #expect(apply(.indent, "- a\n- ⟨b⟩") == "- a\n  - ⟨b⟩")
        #expect(apply(.outdent, "- a\n  - ⟨b⟩") == "- a\n- ⟨b⟩")
    }

    @Test func orderedUsesMarkerWidthAndRenumbers() {
        #expect(apply(.indent, "1. a\n2. ⟨b⟩") == "1. a\n   1. ⟨b⟩")
        #expect(apply(.outdent, "1. a\n   1. ⟨b⟩") == "1. a\n2. ⟨b⟩")
        #expect(apply(.indent, "1. a\n   1. x\n2. ⟨b⟩") == "1. a\n   1. x\n   2. ⟨b⟩")
    }

    @Test func requiresPreviousSibling() {
        #expect(apply(.indent, "- ⟨a⟩") == nil)
        #expect(enabled(.indent, "- ⟨a⟩"))
    }

    @Test func outdentAtTopLevelRemovesMarker() {
        #expect(apply(.outdent, "- ⟨a⟩") == "⟨a⟩")
        #expect(apply(.outdent, "- ⟨a⟩\n  - b") == "⟨a⟩\n- b")
    }

    @Test func movesChildren() {
        #expect(apply(.indent, "- a\n- ⟨b⟩\n  - c\n- d") == "- a\n  - ⟨b⟩\n    - c\n- d")
        #expect(apply(.indent, "- a\n- ⟨b\n- c⟩") == "- a\n  - ⟨b\n  - c⟩")
    }

    @Test func insideQuote() {
        #expect(apply(.indent, "> - a\n> - ⟨b⟩") == "> - a\n>   - ⟨b⟩")
    }

    @Test func enabledOnlyForListLines() {
        #expect(!enabled(.indent, "⟨a⟩"))
        #expect(!enabled(.outdent, "⟨- a\nb⟩"))
        #expect(enabled(.outdent, "⟨- a\n  more⟩"))
        #expect(!active(.indent, "- a\n- ⟨b⟩"))
    }
}

@Suite struct SourceFormatterTableTests {
    @Test func insertsSkeleton() {
        #expect(apply(.insertTable(rows: 1, columns: 2), "⟨⟩") == "| ⟨⟩    |     |\n| --- | --- |\n|     |     |\n")
        #expect(apply(.insertTable(rows: 0, columns: 1), "intro⟨⟩") == "intro\n\n| ⟨⟩    |\n| --- |\n")
    }

    @Test func skeletonParsesAsTable() throws {
        let (text, selection) = SourceMarks.parse("Intro⟨⟩\n\nAfter")
        let edit = try #require(formatter.edit(for: .insertTable(rows: 2, columns: 3), in: text, selection: selection))
        let markdown = edit.applied(to: text)
        let filled = markdown.replacingOccurrences(of: "|     ", with: "| x   ")
        let parsed = try AttributedString(markdown: filled, options: .init(interpretedSyntax: .full))
        var columns = 0
        var rows = Set<Int>()
        for run in parsed.runs {
            for component in run.presentationIntent?.components ?? [] {
                if case .table(let layout) = component.kind { columns = layout.count }
                if case .tableRow(let row) = component.kind { rows.insert(row) }
            }
        }
        #expect(columns == 3)
        #expect(rows.count == 2)
        #expect(markdown.hasPrefix("Intro\n\n|"))
        #expect(markdown.hasSuffix("|\n\nAfter"))
    }

    @Test func otherTableActionsAreUnavailable() {
        let actions: [EditorAction] = [
            .insertTableRowAbove, .insertTableRowBelow, .insertTableColumnBefore, .insertTableColumnAfter,
            .deleteTableRow, .deleteTableColumn, .setTableColumnAlignment(.center), .deleteTable, .editTableStructure
        ]
        let text = "| a |\n| --- |\n| b |"
        for action in actions {
            #expect(!formatter.canPerform(action, in: text, selection: NSRange(location: 2, length: 0)))
            #expect(formatter.edit(for: action, in: text, selection: NSRange(location: 2, length: 0)) == nil)
            #expect(!formatter.isActive(action, in: text, selection: NSRange(location: 2, length: 0)))
        }
        #expect(enabled(.insertTable(rows: 2, columns: 2), "⟨⟩"))
    }
}

@Suite struct SourceFormatterEditTests {
    @Test func editsAreMinimal() {
        let edit = formatter.edit(for: .bold, in: "a word b", selection: NSRange(location: 2, length: 4))
        #expect(edit == MarkdownSourceEdit(range: NSRange(location: 2, length: 4), replacement: "**word**", selection: NSRange(location: 4, length: 4)))
        let heading = formatter.edit(for: .heading(level: 2), in: "# Title", selection: NSRange(location: 3, length: 0))
        #expect(heading?.range == NSRange(location: 1, length: 0))
        #expect(heading?.replacement == "#")
    }

    @Test func minimizationKeepsSurrogatePairsWhole() {
        let edit = MarkdownSourceEdit(range: NSRange(location: 0, length: 2), replacement: "😁", selection: NSRange(location: 2, length: 0))
        let minimized = edit.minimized(against: "😀" as NSString)
        #expect(minimized.range == NSRange(location: 0, length: 2))
        #expect(minimized.replacement == "😁")
    }

    @Test func insertionHelper() {
        let edit = MarkdownSourceEdit.insertion("![a](b)", replacing: NSRange(location: 2, length: 1))
        #expect(edit.applied(to: "x yz") == "x ![a](b)z")
        #expect(edit.selection == NSRange(location: 9, length: 0))
    }

    @Test func snapsSelectionsThatSplitSurrogatePairs() {
        #expect(formatter.edit(for: .bold, in: "👍 x", selection: NSRange(location: 1, length: 0))?.selection == NSRange(location: 2, length: 0))
        #expect(apply(.bold, "a ⟨👍🏽⟩ b") == "a **⟨👍🏽⟩** b")
        let split = formatter.edit(for: .bold, in: "👍 x", selection: NSRange(location: 0, length: 1))
        #expect(split?.applied(to: "👍 x") == "**👍** x")
    }

    @Test func clampsOutOfRangeSelections() {
        #expect(formatter.edit(for: .bold, in: "abc", selection: NSRange(location: 10, length: 5)) != nil)
        #expect(!formatter.isActive(.bold, in: "", selection: NSRange(location: NSNotFound, length: 0)))
    }

    static let corpus = [
        "plain text",
        "# H1\n\n- a\n  - b\n1. c\n> quote **bold** and *it*\n\n```\ncode `x`\n```\n",
        "👍 **emoji** 🎉 `c` ~~s~~ [l](u)\n- [ ] t 👨‍👩‍👧\n",
        "| a | b |\n| --- | --- |\n| 1 | 2 |",
        "***x*** __y__ _z_ \\*e\\*\n\n---\n"
    ]

    @Test(arguments: corpus) func everyActionProducesValidEdits(text: String) {
        let actions: [EditorAction] = [
            .bold, .italic, .strikethrough, .codeSpan, .heading(level: 1), .heading(level: 2),
            .unorderedList, .orderedList, .taskList, .blockquote, .codeBlock, .link,
            .link(url: "https://x", label: nil), .horizontalRule, .indent, .outdent, .insertTable(rows: 1, columns: 2)
        ]
        let ns = text as NSString
        var selections: [NSRange] = []
        for location in 0...ns.length {
            selections.append(NSRange(location: location, length: 0))
            for length in [1, 3, 7] where location + length <= ns.length {
                selections.append(NSRange(location: location, length: length))
            }
        }
        for selection in selections {
            for action in actions {
                _ = formatter.isActive(action, in: text, selection: selection)
                guard let edit = formatter.edit(for: action, in: text, selection: selection) else { continue }
                #expect(edit.range.location >= 0 && NSMaxRange(edit.range) <= ns.length)
                let result = edit.applied(to: text) as NSString
                #expect(NSMaxRange(edit.selection) <= result.length, "\(action) \(selection)")
                #expect(!(result as String).unicodeScalars.contains("\u{FFFD}"), "\(action) \(selection)")
            }
        }
    }
}

@Suite struct SourceFormatterStatesTests {
    @Test func batchMatchesIndividualQueries() {
        let actions: [EditorAction] = [.bold, .italic, .heading(level: 2), .unorderedList, .codeBlock, .link, .indent, .deleteTable]
        let (text, selection) = SourceMarks.parse("## **⟨x⟩**\n- [y](u)")
        let states = formatter.states(for: actions, in: text, selection: selection)
        for action in actions {
            #expect(states.isActive(action) == formatter.isActive(action, in: text, selection: selection))
            #expect(states.canPerform(action) == formatter.canPerform(action, in: text, selection: selection))
        }
        #expect(states.isActive(.bold))
        #expect(states.isActive(.heading(level: 2)))
        #expect(!states.canPerform(.indent))
    }
}
