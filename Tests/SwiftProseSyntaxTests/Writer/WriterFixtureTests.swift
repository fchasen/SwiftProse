import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Writer fixture")
struct WriterFixtureTests {
    @Test func fixtureBuildsVocabularyAttributes() {
        let list = WF.bullet()
        let storage = WF.storage([WF.p(WF.t("a", .strong)), WF.item("b", [list])])
        #expect(storage.string == "a\nb")
        #expect(storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        #expect(storage.markdownBlock(at: 2)?.isListItemStart == true)
        let style = storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textLists.first === list)
    }

    @Test func readerBuildsDocumentTree() {
        let list = WF.ordered(3)
        let quote = GroupToken.mint()
        let document = StorageReader().document(from: WF.storage([
            WF.p(WF.t("x", [.strong, .emphasis])),
            WF.item("a", [list], task: .checked),
            WF.item("b", [list], quotes: [quote])
        ]))
        #expect(document.blocks == [
            .paragraph([.text("x", marks: [.strong, .emphasis])]),
            .list(.init(kind: .ordered(start: 3), items: [
                .init(task: .checked, blocks: [.paragraph([.text("a")])])
            ])),
            .quote([
                .list(.init(kind: .ordered(start: 3), items: [
                    .init(blocks: [.paragraph([.text("b")])])
                ]))
            ])
        ])
    }

    @Test func rangeSerializationClipsToParagraphs() {
        let storage = WF.storage([WF.p("abc"), WF.p("def")])
        #expect(MarkdownWriter().markdown(from: storage, range: NSRange(location: 1, length: 4)) == "bc\n\nd")
    }
}
