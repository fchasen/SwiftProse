import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport

@Suite("Writer performance")
struct WriterPerformanceTests {
    #if DEBUG
    static let budget = Duration.milliseconds(30)
    #else
    static let budget = Duration.milliseconds(5)
    #endif

    static func fiftyKilobyteStorage() -> NSAttributedString {
        var paragraphs: [WF.Para] = []
        var index = 0
        let bullet = WF.bullet()
        let ordered = WF.ordered()
        let quote = GroupToken.mint()
        var length = 0
        while length < 50_000 {
            let group = GroupToken.mint()
            let batch: [WF.Para] = [
                WF.p(WF.t("Section \(index)"), block: MarkdownBlock(leaf: .heading(level: 2))),
                WF.p(
                    WF.t("Plain text with "), WF.t("strong", .strong), WF.t(" and "), WF.t("emphasis", .emphasis),
                    WF.t(", a "), WF.t("link label", link: "https://bugzilla.mozilla.org/show_bug.cgi?id=\(index)"),
                    WF.t(" and "), WF.t("inline_code()", .code), WF.soft,
                    WF.t("a second line with "), WF.t("*", literal: "\\*"), WF.t(" literal and "), WF.t("both", [.strong, .emphasis])
                ),
                WF.item("first bullet item with some words", [bullet]),
                WF.item("second bullet item", [bullet], task: .checked),
                WF.item("nested ordered item", [bullet, ordered]),
                WF.item("continuation paragraph", [bullet], continuation: true),
                WF.p("quoted text that spans a reasonable length of characters", block: MarkdownBlock(containers: [.quote(quote)])),
                WF.code("func example\(index)() -> Int {", group, language: "swift"),
                WF.code("    return \(index)", group, language: "swift"),
                WF.code("}", group, language: "swift"),
                WF.p("")
            ]
            paragraphs.append(contentsOf: batch)
            length += batch.reduce(0) { total, paragraph in total + paragraph.content.reduce(1) { $0 + $1.length } }
            index += 1
        }
        return WF.storage(paragraphs)
    }

    @Test func serializingFiftyKilobytesTakesUnderFiveMilliseconds() {
        let storage = Self.fiftyKilobyteStorage()
        #expect(storage.length >= 50_000)
        let writer = MarkdownWriter()
        let clock = ContinuousClock()
        var output = ""
        var best = Duration.seconds(1)
        for _ in 0..<7 {
            let elapsed = clock.measure { output = writer.markdown(from: storage) }
            best = min(best, elapsed)
        }
        #expect(output.utf8.count >= 50_000)
        #expect(best < Self.budget, "best of 7 runs took \(best)")
    }
}

@Suite("Loader performance")
struct LoaderPerformanceTests {
    #if DEBUG
    static let budget = Duration.milliseconds(600)
    #else
    static let budget = Duration.milliseconds(300)
    #endif

    @Test(arguments: [("-\n", 8_000), ("***\n", 6_000)])
    func recoveringThousandsOfLinesIsLinear(line: String, count: Int) {
        let markdown = String(repeating: line, count: count)
        let clock = ContinuousClock()
        var storage = NSMutableAttributedString()
        let elapsed = clock.measure { storage = MarkdownLoader().load(markdown) }
        #expect(LoaderFixture.paragraphs(storage).count == count)
        #expect(elapsed < Self.budget, "load took \(elapsed)")
    }
}
