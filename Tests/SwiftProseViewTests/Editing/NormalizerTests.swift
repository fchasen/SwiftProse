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

@Suite("Normalizer")
struct NormalizerTests {
    let normalizer = Normalizer()

    @Test func blockBecomesUniformFromFirstCharacter() {
        let storage = StorageBuilder.build { $0.paragraph("abc") }
        storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .heading(level: 2)), range: NSRange(location: 0, length: 1))
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: 4))
        #expect(storage.markdownBlock(at: 3)?.headingLevel == 2)
        #expect(storage.isBlockUniform(in: NSRange(location: 0, length: 4)))
    }

    @Test func typedCharacterAtParagraphStartKeepsExistingBlock() {
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        let storage = StorageBuilder.build {
            $0.paragraph("intro")
            $0.paragraph("Title", heading)
        }
        storage.insert(NSAttributedString(string: "x", attributes: [.markdownBlock: MarkdownBlock.paragraph]), at: 6)
        normalizer.normalize(storage, editedRange: NSRange(location: 6, length: 1), changeInLength: 1)
        #expect(storage.blocks() == [.paragraph, heading])
    }

    @Test func mergedParagraphTakesFirstParagraphBlock() {
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        let storage = StorageBuilder.build {
            $0.paragraph("Title", heading)
            $0.paragraph("body")
        }
        storage.deleteCharacters(in: NSRange(location: 5, length: 1))
        normalizer.normalize(storage, editedRange: NSRange(location: 5, length: 0), changeInLength: -1)
        #expect(storage.string == "Titlebody\n")
        #expect(storage.blocks() == [heading])
    }

    @Test func paragraphWithoutBlockBecomesPlainParagraph() {
        let storage = NSMutableAttributedString(string: "loose\n")
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: 6))
        #expect(storage.blocks() == [.paragraph])
    }

    @Test func nativeNestingAddsListItemContainer() {
        let outer = NSTextList(markerFormat: .disc, options: 0)
        let inner = NSTextList(markerFormat: .hyphen, options: 0)
        let storage = StorageBuilder.build {
            $0.paragraph("one", MarkdownBlock(containers: [.listItem]), lists: [outer])
            $0.paragraph("two", MarkdownBlock(containers: [.listItem]), lists: [outer, inner])
        }
        normalizer.normalize(storage, editedRange: NSRange(location: 4, length: 4))
        #expect(storage.markdownBlock(at: 4)?.containers == [.listItem, .listItem])
        #expect(storage.markdownBlock(at: 0)?.containers == [.listItem])
    }

    @Test func removedListDropsContainerContinuationAndTask() {
        let quote = GroupToken.mint()
        let storage = StorageBuilder.build {
            $0.paragraph("done", MarkdownBlock(containers: [.quote(quote), .listItem], task: .checked))
        }
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: 5))
        #expect(storage.markdownBlock(at: 0) == MarkdownBlock(containers: [.quote(quote)]))
    }

    @Test func nonParagraphLeavesDropTheirTask() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let storage = StorageBuilder.build {
            $0.paragraph("h", MarkdownBlock(leaf: .heading(level: 2), containers: [.listItem], task: .unchecked), lists: [list])
            $0.paragraph("p", MarkdownBlock(containers: [.listItem], task: .checked), lists: [list])
        }
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: storage.length))
        #expect(storage.markdownBlock(at: 0) == MarkdownBlock(leaf: .heading(level: 2), containers: [.listItem]))
        #expect(storage.markdownBlock(at: 2)?.task == .checked)
        #expect(MarkdownWriter().markdown(from: storage) == "- ## h\n- [x] p")
    }

    @Test func emptyMarkerListsDoNotCountAsListItems() {
        let list = NSTextList(markerFormat: .decimal, options: 0)
        let empty = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: ""), options: 0)
        let continuation = MarkdownBlock(containers: [.listItem], isContinuation: true)
        let storage = StorageBuilder.build {
            $0.paragraph("item", MarkdownBlock(containers: [.listItem]), lists: [list])
            $0.paragraph("more", continuation, lists: [list, empty])
        }
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: storage.length))
        #expect(storage.markdownBlock(at: 5) == continuation)
    }

    @Test func staleLiteralIsDroppedFromTypedCharacters() {
        let storage = StorageBuilder.build { $0.paragraph("*ab") }
        storage.addAttribute(.markdownLiteral, value: "\\*", range: NSRange(location: 0, length: 3))
        normalizer.normalize(storage, editedRange: NSRange(location: 1, length: 2), changeInLength: 2)
        #expect(storage.markdownLiteral(at: 0) == "\\*")
        #expect(storage.markdownLiteral(at: 1) == nil)
        #expect(storage.markdownLiteral(at: 2) == nil)
    }

    @Test func repeatedLiteralCharactersAreKept() {
        let storage = StorageBuilder.build { $0.paragraph("**") }
        storage.addAttribute(.markdownLiteral, value: "\\*", range: NSRange(location: 0, length: 2))
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: 2))
        #expect(storage.markdownLiteral(at: 0) == "\\*")
        #expect(storage.markdownLiteral(at: 1) == "\\*")
    }

    @Test func entityLiteralsSurviveWhenMatching() {
        let storage = StorageBuilder.build { $0.paragraph("&\u{00A0}\u{00A9}A?") }
        storage.addAttribute(.markdownLiteral, value: "&amp;", range: NSRange(location: 0, length: 1))
        storage.addAttribute(.markdownLiteral, value: "&nbsp;", range: NSRange(location: 1, length: 1))
        storage.addAttribute(.markdownLiteral, value: "&#169;", range: NSRange(location: 2, length: 1))
        storage.addAttribute(.markdownLiteral, value: "&#x41;", range: NSRange(location: 3, length: 1))
        storage.addAttribute(.markdownLiteral, value: "&amp;", range: NSRange(location: 4, length: 1))
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: storage.length))
        #expect(storage.markdownLiteral(at: 0) == "&amp;")
        #expect(storage.markdownLiteral(at: 1) == "&nbsp;")
        #expect(storage.markdownLiteral(at: 2) == "&#169;")
        #expect(storage.markdownLiteral(at: 3) == "&#x41;")
        #expect(storage.markdownLiteral(at: 4) == nil)
    }

    @Test func literalRenderingDecodesEscapesAndEntities() {
        #expect(Normalizer.renderedText(forLiteral: "\\_") == "_")
        #expect(Normalizer.renderedText(forLiteral: "&lt;") == "<")
        #expect(Normalizer.renderedText(forLiteral: "&#0;") == "\u{FFFD}")
        #expect(Normalizer.renderedText(forLiteral: "&#xD800;") == "\u{FFFD}")
        #expect(Normalizer.renderedText(forLiteral: "&hearts;") == "\u{2665}")
        #expect(Normalizer.renderedText(forLiteral: "plain") == nil)
    }

    @Test func codeBlocksLoseMarksLinksAndLiterals() {
        let code = MarkdownBlock(leaf: .code(language: "swift", group: GroupToken.mint()))
        let storage = StorageBuilder.build { $0.paragraph("let *x", code) }
        storage.addIntent([.stronglyEmphasized], NSRange(location: 0, length: 3))
        storage.addAttribute(.link, value: "https://example.com", range: NSRange(location: 0, length: 3))
        storage.addAttribute(.markdownLiteral, value: "\\*", range: NSRange(location: 4, length: 1))
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: storage.length))
        #expect(storage.markdownInlineIntent(at: 0).isEmpty)
        #expect(storage.markdownLink(at: 0) == nil)
        #expect(storage.markdownLiteral(at: 4) == nil)
    }

    @Test func inlineCodeLosesLiteralsButKeepsLink() {
        let storage = StorageBuilder.build { $0.paragraph("a*b") }
        storage.addIntent(.code, NSRange(location: 0, length: 3))
        storage.addAttribute(.link, value: "https://example.com", range: NSRange(location: 0, length: 3))
        storage.addAttribute(.markdownLiteral, value: "\\*", range: NSRange(location: 1, length: 1))
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: storage.length))
        #expect(storage.markdownLiteral(at: 1) == nil)
        #expect(storage.markdownLink(at: 1) == "https://example.com")
        #expect(storage.markdownInlineIntent(at: 1) == .code)
    }

    @Test func softBreakBitStaysOnlyOnBreakCharacters() {
        let storage = StorageBuilder.build { $0.paragraph("a\u{2028}bc") }
        storage.addIntent([.softBreak], NSRange(location: 1, length: 1))
        storage.addIntent([.softBreak, .emphasized], NSRange(location: 2, length: 1))
        storage.addIntent([.softBreak], NSRange(location: 3, length: 1))
        normalizer.normalize(storage, editedRange: NSRange(location: 2, length: 2), changeInLength: 2)
        #expect(storage.isMarkdownSoftBreak(at: 1))
        #expect(storage.markdownInlineIntent(at: 2) == .emphasized)
        #expect(storage.markdownInlineIntent(at: 3).isEmpty)
    }

    @Test func separatorLosesLinkAndLiteral() {
        let storage = StorageBuilder.build {
            $0.paragraph("link")
            $0.paragraph("next")
        }
        storage.addAttribute(.link, value: "https://example.com", range: NSRange(location: 0, length: 5))
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: 5))
        #expect(storage.markdownLink(at: 3) == "https://example.com")
        #expect(storage.markdownLink(at: 4) == nil)
    }

    @Test func atomLeafWithoutAttachmentBecomesParagraph() {
        let storage = StorageBuilder.build {
            $0.paragraph("", MarkdownBlock(leaf: .thematicBreak))
            $0.paragraph("", MarkdownBlock(leaf: .thematicBreak))
        }
        let rule = NSAttributedString(attachment: HorizontalRuleAttachment(color: .gray))
        storage.insert(rule, at: 1)
        storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .thematicBreak), range: NSRange(location: 1, length: 1))
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: storage.length))
        #expect(storage.markdownBlock(at: 0)?.leaf == .paragraph)
        #expect(storage.markdownBlock(at: 1)?.leaf == .thematicBreak)
    }

    @Test func returnAtEndOfCheckedTaskUnchecksNewItem() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let checked = MarkdownBlock(containers: [.listItem], task: .checked)
        let storage = StorageBuilder.build {
            $0.paragraph("done", checked, lists: [list])
            $0.paragraph("after")
        }
        storage.insert(NSAttributedString(string: "\n", attributes: [.markdownBlock: checked]), at: 4)
        normalizer.normalize(storage, editedRange: NSRange(location: 4, length: 1), changeInLength: 1)
        #expect(storage.string == "done\n\nafter\n")
        #expect(storage.markdownBlock(at: 0)?.task == .checked)
        #expect(storage.markdownBlock(at: 5)?.task == .unchecked)
        #expect(storage.markdownBlock(at: 6) == .paragraph)
    }

    @Test func returnAtStartOfCheckedTaskUnchecksEmptyItem() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let checked = MarkdownBlock(containers: [.listItem], task: .checked)
        let storage = StorageBuilder.build { $0.paragraph("done", checked, lists: [list]) }
        let style = storage.paragraphStyle(at: 0) ?? NSParagraphStyle()
        storage.insert(NSAttributedString(string: "\n", attributes: [.markdownBlock: checked, .paragraphStyle: style]), at: 0)
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: 1), changeInLength: 1)
        #expect(storage.markdownBlock(at: 0)?.task == .unchecked)
        #expect(storage.markdownBlock(at: 1)?.task == .checked)
    }

    @Test func pastedCheckedTasksStayChecked() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let checked = MarkdownBlock(containers: [.listItem], task: .checked)
        let storage = StorageBuilder.build {
            $0.paragraph("a", checked, lists: [list])
            $0.paragraph("b", checked, lists: [list])
        }
        normalizer.normalize(storage, editedRange: NSRange(location: 0, length: storage.length), changeInLength: storage.length)
        #expect(storage.blocks().map { $0?.task } == [.checked, .checked])
    }

    @Test func markedParagraphIsSkipped() {
        let storage = StorageBuilder.build {
            $0.paragraph("one")
            $0.paragraph("two")
        }
        storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .heading(level: 1)), range: NSRange(location: 0, length: 1))
        storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .heading(level: 1)), range: NSRange(location: 4, length: 1))
        let touched = normalizer.normalize(
            storage,
            editedRange: NSRange(location: 0, length: storage.length),
            markedRange: NSRange(location: 5, length: 2)
        )
        #expect(storage.isBlockUniform(in: NSRange(location: 0, length: 4)))
        #expect(!storage.isBlockUniform(in: NSRange(location: 4, length: 4)))
        #expect(touched == NSRange(location: 0, length: 4))
    }

    @Test func onlyEditedParagraphsAndNeighboursAreTouched() {
        let heading = MarkdownBlock(leaf: .heading(level: 3))
        let storage = StorageBuilder.build {
            for name in ["p0", "p1", "p2", "p3", "p4"] { $0.paragraph(name) }
        }
        for location in stride(from: 0, to: 15, by: 3) {
            storage.addAttribute(.markdownBlock, value: heading, range: NSRange(location: location, length: 1))
        }
        let touched = normalizer.normalize(storage, editedRange: NSRange(location: 7, length: 1))
        #expect(touched == NSRange(location: 3, length: 9))
        #expect(!storage.isBlockUniform(in: NSRange(location: 0, length: 3)))
        #expect(storage.isBlockUniform(in: NSRange(location: 3, length: 3)))
        #expect(storage.isBlockUniform(in: NSRange(location: 9, length: 3)))
        #expect(!storage.isBlockUniform(in: NSRange(location: 12, length: 3)))
    }

    @Test func revertSnapshotIsRecordedOnlyWhenSomethingChanged() {
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        let storage = StorageBuilder.build {
            $0.paragraph("Head", heading)
            $0.paragraph("body")
        }
        let clean = normalizer.normalizeRecordingRevert(storage, editedRange: NSRange(location: 0, length: storage.length))
        #expect(clean.revert == nil)

        storage.deleteCharacters(in: NSRange(location: 4, length: 1))
        let merged = normalizer.normalizeRecordingRevert(storage, editedRange: NSRange(location: 4, length: 0), changeInLength: -1)
        #expect(storage.blocks() == [heading])
        #expect(merged.revert != nil)
        merged.revert?.apply(to: storage)
        #expect(storage.markdownBlock(at: 4) == .paragraph)
        #expect(storage.markdownBlock(at: 0) == heading)
    }

    @Test func revertRegistersUndoThatRedoes() {
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        let storage = StorageBuilder.build { $0.paragraph("Headbody", .paragraph) }
        storage.addAttribute(.markdownBlock, value: heading, range: NSRange(location: 0, length: 4))
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let result = normalizer.normalizeRecordingRevert(storage, editedRange: NSRange(location: 4, length: 0))
        result.revert?.registerUndo(on: manager, storage: storage)
        manager.endUndoGrouping()
        #expect(storage.isBlockUniform(in: NSRange(location: 0, length: 9)))
        manager.undo()
        #expect(storage.markdownBlock(at: 5) == .paragraph)
        manager.redo()
        #expect(storage.markdownBlock(at: 5) == heading)
    }
}

@Suite("Normalizer over loaded storage")
struct NormalizerLoadedStorageTests {
    @Test(arguments: CorpusFixtures.canonical)
    func normalizerLeavesLoadedStorageSerializingIdentically(_ sample: CorpusSample) {
        let storage = Corpus.load(sample.source)
        Normalizer().normalizeAll(storage)
        #expect(Corpus.write(storage) == sample.source)
    }

    @Test func separatorLiteralsSurviveEditsInCode() {
        let storage = Corpus.load("```\na\u{2028}b\n```")
        storage.insert(NSAttributedString(string: "z"), at: 0)
        Normalizer().normalizeAll(storage)
        #expect(Corpus.write(storage) == "```\nza\u{2028}b\n```")
    }
}
