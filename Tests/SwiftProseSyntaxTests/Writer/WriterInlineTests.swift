import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Writer inline")
struct WriterInlineTests {
    @Test func singleMarks() {
        #expect(WF.inline(WF.t("a "), WF.t("b", .strong), WF.t(" c")) == "a **b** c")
        #expect(WF.inline(WF.t("a "), WF.t("b", .emphasis), WF.t(" c")) == "a *b* c")
        #expect(WF.inline(WF.t("a "), WF.t("b", .code), WF.t(" c")) == "a `b` c")
        #expect(WF.inline(WF.t("a "), WF.t("b", .strikethrough), WF.t(" c")) == "a ~~b~~ c")
    }

    @Test func strongAndEmphasisOnTheSameSpan() {
        #expect(WF.inline(WF.t("x", [.strong, .emphasis])) == "***x***")
        #expect(WF.inline(WF.t("x", [.strikethrough, .strong, .emphasis])) == "~~***x***~~")
        #expect(WF.inline(WF.t("x", [.strikethrough, .strong])) == "~~**x**~~")
        #expect(WF.inline(WF.t("x", [.strong, .code])) == "**`x`**")
    }

    @Test func emphasisUsesUnderscoreNextToStrong() {
        #expect(WF.inline(WF.t("a ", .strong), WF.t("b", [.strong, .emphasis])) == "**a _b_**")
        #expect(WF.inline(WF.t("a", [.strong, .emphasis]), WF.t(" b", .strong)) == "**_a_ b**")
        #expect(WF.inline(WF.t("a ", .emphasis), WF.t("b", [.strong, .emphasis])) == "_a **b**_")
        #expect(WF.inline(WF.t("a", [.strong, .emphasis]), WF.t(" b", .emphasis)) == "_**a** b_")
    }

    @Test func emphasisFallsBackToStarIntraword() {
        #expect(WF.inline(WF.t("foo"), WF.t("bar", .emphasis), WF.t("baz")) == "foo*bar*baz")
        #expect(WF.inline(WF.t("a", .strong), WF.t("b", .emphasis), WF.t("c")) == "**a***b*c")
    }

    @Test func whitespaceMovesOutsideMarks() {
        #expect(WF.inline(WF.t("a"), WF.t(" b ", .strong), WF.t("c")) == "a **b** c")
        #expect(WF.inline(WF.t("a"), WF.t(" ", .strong), WF.t("b")) == "a b")
        #expect(WF.inline(WF.t("a"), WF.t("\u{00A0}b", .emphasis)) == "a\u{00A0}*b*")
    }

    @Test func sameMarksMergeAcrossWhitespaceGaps() {
        #expect(WF.inline(WF.t("a", .strong), WF.t(" "), WF.t("b", .strong)) == "**a b**")
        #expect(WF.inline(WF.t("a", [.strong, .emphasis]), WF.t(" "), WF.t("b", .strong)) == "**_a_ b**")
        #expect(WF.inline(WF.t("a", .strong), WF.t("b", .strong)) == "**ab**")
    }

    static let nonFlankingDelimiters: [[NSAttributedString]] = [
        [WF.t("foo.", .strong), WF.t("bar")],
        [WF.t("a"), WF.t("(b)", .strong)],
        [WF.t("see"), WF.t("[x]", .strong, link: "u")],
        [WF.t("a"), WF.t("(b)", .strikethrough), WF.t("c")],
        [WF.t("x"), WF.t("(y)", .emphasis), WF.t("z")],
        [WF.t("中文"), WF.t("「重要」", .strong), WF.t("继续")],
        [WF.t("a"), WF.t("(b)", [.strong, .strikethrough]), WF.t("c")]
    ]

    @Test(arguments: nonFlankingDelimiters)
    func delimitersNextToPunctuationReloadAsMarks(content: [NSAttributedString]) {
        let storage = WF.storage([WF.Para(content: content, block: .paragraph, lists: [])])
        let written = MarkdownWriter().markdown(from: storage)
        let reloaded = LoaderFixture.load(written).storage
        #expect(reloaded.string == storage.string, "\(written)")
        #expect(LoaderFixture.intentRuns(reloaded).map(\.0) == LoaderFixture.intentRuns(storage).map(\.0), "\(written)")
        #expect(LoaderFixture.intentRuns(reloaded).map(\.1) == LoaderFixture.intentRuns(storage).map(\.1), "\(written)")
        #expect(MarkdownWriter().markdown(from: reloaded) == written)
    }

    @Test func flankingDelimitersEncodeOnlyTheBlockingNeighbor() {
        #expect(WF.inline(WF.t("foo.", .strong), WF.t("bar")) == "**foo.**&#98;ar")
        #expect(WF.inline(WF.t("a"), WF.t("(b)", .strong)) == "&#97;**(b)**")
        #expect(WF.inline(WF.t("a "), WF.t("(b)", .strong), WF.t(" c")) == "a **(b)** c")
        #expect(WF.inline(WF.t("a"), WF.t("b.", .strong), WF.t(",")) == "a**b.**,")
    }

    @Test func noEscapesAreAdded() {
        let text = "2 * 3 = _x_ # [a](b) <b> \\ ` ~ | & 1. - >"
        #expect(WF.inline(WF.t(text)) == text)
        #expect(WF.inline(WF.t("snake_case_name")) == "snake_case_name")
    }

    @Test func codeSpansPadAndOutgrowBackticks() {
        #expect(WF.inline(WF.t("a`b", .code)) == "``a`b``")
        #expect(WF.inline(WF.t("`x", .code)) == "`` `x ``")
        #expect(WF.inline(WF.t("x``", .code)) == "``` x`` ```")
        #expect(WF.inline(WF.t(" a ", .code)) == "`  a  `")
        #expect(WF.inline(WF.t(" a", .code)) == "` a`")
        #expect(WF.inline(WF.t("a"), WF.t(" ", .code)) == "a` `")
        #expect(WF.inline(WF.t("a "), WF.t(" b ", .code)) == "a `  b  `")
    }

    @Test func codeRunsIgnoreLiterals() {
        #expect(WF.inline(WF.t("*", .code, literal: "\\*")) == "`*`")
    }

    @Test func literalsEmitTheirSourceWhileUnchanged() {
        #expect(WF.inline(WF.t("*", literal: "\\*"), WF.t("a")) == "\\*a")
        #expect(WF.inline(WF.t("**", literal: "\\*")) == "\\*\\*")
        #expect(WF.inline(WF.t("*y", literal: "\\*")) == "\\*y")
        #expect(WF.inline(WF.t("x", literal: "\\*")) == "x")
        #expect(WF.inline(WF.t("&", literal: "&amp;")) == "&amp;")
        #expect(WF.inline(WF.t("\u{00A9}", literal: "&copy;")) == "&copy;")
        #expect(WF.inline(WF.t("A", literal: "&#x41;")) == "&#x41;")
        #expect(WF.inline(WF.t("\u{FFFD}", literal: "&#0;")) == "&#0;")
        #expect(WF.inline(WF.t("\u{1F600}", literal: "&#x1F600;")) == "&#x1F600;")
        #expect(WF.inline(WF.t("b", literal: "&amp;")) == "b")
        #expect(WF.inline(WF.t("*", .strong, literal: "\\*")) == "**\\***")
    }

    @Test func links() {
        let url = "https://example.com/d"
        #expect(WF.inline(WF.t("see "), WF.t("docs", link: url)) == "see [docs](https://example.com/d)")
        #expect(WF.inline(WF.t("a ", link: url), WF.t("b", .strong, link: url)) == "[a **b**](https://example.com/d)")
        #expect(WF.inline(WF.t("y", .strong, link: url)) == "**[y](https://example.com/d)**")
        #expect(WF.inline(WF.t("x", .strong), WF.t("y", .strong, link: url)) == "**x[y](https://example.com/d)**")
        #expect(WF.inline(WF.t("a", .strong), WF.t("b", .strong, link: "u"), WF.t("c", link: "u")) == "**a**[**b**c](u)")
        #expect(WF.inline(WF.t("a", link: "u"), WF.t("b", link: "v")) == "[a](u)[b](v)")
        #expect(WF.inline(WF.t("a", link: "u"), WF.t(" "), WF.t("b", link: "u")) == "[a b](u)")
        #expect(WF.inline(WF.t("c", .code, link: "u")) == "[`c`](u)")
    }

    @Test func linkDestinationsUseAnglesWhenNeeded() {
        #expect(WF.inline(WF.t("a", link: "u v")) == "[a](<u v>)")
        #expect(WF.inline(WF.t("a", link: "x(1)")) == "[a](x(1))")
        #expect(WF.inline(WF.t("a", link: "x(1")) == "[a](<x(1>)")
    }

    @Test(arguments: [
        ("a<b c", "a%3Cb%20c"),
        ("<x>", "%3Cx%3E"),
        ("a\nb", "a%0Ab"),
        ("a\\*b", "a%5C*b"),
        ("x(1<", "x(1%3C"),
        ("日本 <語>", "%E6%97%A5%E6%9C%AC%20%3C%E8%AA%9E%3E")
    ])
    func unsafeLinkDestinationsReloadAsLinks(url: String, reloaded: String) {
        let storage = WF.storage([WF.p(WF.t("see", link: url), WF.t(" after"))])
        let written = MarkdownWriter().markdown(from: storage)
        let loaded = LoaderFixture.load(written).storage
        #expect(loaded.string == "see after", "\(written)")
        #expect(loaded.markdownLink(at: 0) == reloaded, "\(written)")
    }

    @Test func linkValuesMayBeURLs() {
        let storage = NSMutableAttributedString(string: "docs", attributes: [.link: URL(string: "https://e.com")!])
        storage.addAttribute(.markdownBlock, value: MarkdownBlock.paragraph, range: NSRange(location: 0, length: 4))
        #expect(MarkdownWriter().markdown(from: storage) == "[docs](https://e.com)")
    }

    @Test func autolinksStayBare() {
        #expect(WF.inline(WF.t("go "), WF.t("https://e.com/x", link: "https://e.com/x"), WF.t(" now")) == "go https://e.com/x now")
        #expect(WF.inline(WF.t("www.e.com", link: "http://www.e.com"), WF.t(".")) == "www.e.com.")
        #expect(WF.inline(WF.t("me@x.com", link: "mailto:me@x.com")) == "me@x.com")
        #expect(WF.inline(WF.t("https://e.com", .strong, link: "https://e.com")) == "**https://e.com**")
        #expect(WF.inline(WF.t("x"), WF.t("https://e.com", link: "https://e.com")) == "x[https://e.com](https://e.com)")
        #expect(WF.inline(WF.t("https://e.com.", link: "https://e.com.")) == "[https://e.com.](https://e.com.)")
        #expect(WF.inline(WF.t("e.com", link: "e.com")) == "[e.com](e.com)")
    }

    @Test func breaks() {
        #expect(WF.inline(WF.t("a"), WF.hard, WF.t("b")) == "a  \nb")
        #expect(WF.inline(WF.t("a"), WF.soft, WF.t("b")) == "a\nb")
        #expect(WF.inline(WF.t("a", .strong), WF.hard, WF.t("b", .strong)) == "**a**  \n**b**")
        #expect(WF.inline(WF.t("a", .strong), WF.soft, WF.t("b", .strong)) == "**a**\n**b**")
        #expect(WF.inline(WF.t("a"), WF.soft, WF.hard, WF.t("b")) == "a  \nb")
        #expect(WF.inline(WF.t("a"), WF.soft, WF.t("  "), WF.soft, WF.t("b")) == "a\nb")
        #expect(WF.inline(WF.hard, WF.t("a"), WF.hard) == "a")
        #expect(WF.inline(WF.t("a  "), WF.soft, WF.t("  b")) == "a\nb")
    }

    @Test func inlineAtomsWriteTheirSource() {
        #expect(WF.inline(WF.t("x "), WF.atom("{nav,  icon=file}")) == "x {nav,  icon=file}")
        #expect(WF.inline(WF.atom("![alt *t*](i.png)", kind: AtomKind.image, .strong)) == "**![alt *t*](i.png)**")
        #expect(WF.inline(WF.t("a", link: "u"), WF.atom("<b>", kind: AtomKind.inlineHTML)) == "[a](u)<b>")
    }

    @Test func attachmentsWithoutSourceAreDropped() {
        let storage = NSMutableAttributedString(string: "a")
        storage.append(NSAttributedString(attachment: NSTextAttachment()))
        storage.append(NSAttributedString(string: "b\u{FFFC}"))
        #expect(MarkdownWriter().markdown(from: storage) == "ab")
    }
}
