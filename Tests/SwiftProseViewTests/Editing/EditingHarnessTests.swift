#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Editing harness (macOS, .serialized)")
@MainActor
struct EditingHarnessTests {
    private func listHarness(_ items: [String], task: TaskState? = nil) -> (EditorHarness, NSTextList) {
        let harness = EditorHarness(pipeline: .normalizer)
        let list = NSTextList(markerFormat: .disc, options: 0)
        harness.load(StorageBuilder.build { builder in
            for (index, item) in items.enumerated() {
                builder.paragraph(
                    item,
                    MarkdownBlock(containers: [.listItem], task: task),
                    lists: [list],
                    separator: index < items.count - 1
                )
            }
        })
        return (harness, list)
    }

    @Test func harnessStaysOnTextKit2() {
        let harness = EditorHarness(pipeline: .normalizer)
        harness.load(StorageBuilder.build { $0.paragraph("hello", separator: false) })
        harness.select(5)
        harness.type(" world")
        #expect(harness.string == "hello world")
        #expect(harness.isTextKit2)
    }

    @Test func typingAtHeadingStartKeepsHeading() {
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        let harness = EditorHarness(pipeline: .normalizer)
        harness.load(StorageBuilder.build {
            $0.paragraph("intro")
            $0.paragraph("Title", heading, separator: false)
        })
        harness.select(6)
        harness.type("A ")
        #expect(harness.paragraphTexts == ["intro", "A Title"])
        #expect(harness.paragraphBlocks == [.paragraph, heading])
        let font = harness.storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        #expect(font == harness.controller.theme.headingFont(level: 1))
    }

    @Test func returnSplitsBlockUniformly() {
        let heading = MarkdownBlock(leaf: .heading(level: 2))
        let harness = EditorHarness(pipeline: .normalizer)
        harness.load(StorageBuilder.build { $0.paragraph("Heading", heading, separator: false) })
        harness.select(4)
        harness.insertNewline()
        #expect(harness.paragraphTexts == ["Head", "ing"])
        #expect(harness.paragraphBlocks == [heading, heading])
    }

    @Test func backspaceMergeKeepsFirstBlock() {
        let heading = MarkdownBlock(leaf: .heading(level: 2))
        let harness = EditorHarness(pipeline: .normalizer)
        harness.load(StorageBuilder.build {
            $0.paragraph("Head", heading)
            $0.paragraph("body", separator: false)
        })
        harness.select(5)
        harness.deleteBackward()
        #expect(harness.string == "Headbody")
        #expect(harness.paragraphBlocks == [heading])
        let font = harness.storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        #expect(font == harness.controller.theme.headingFont(level: 2))
    }

    @Test func nativeListReturnContinuesItem() {
        let (harness, list) = listHarness(["one", "two"])
        harness.select(3)
        harness.insertNewline()
        #expect(harness.paragraphTexts == ["one", "", "two"])
        #expect(harness.textLists(at: 4).first === list)
        #expect(harness.block(at: 4) == MarkdownBlock(containers: [.listItem]))
    }

    @Test func nativeTabNestingAddsContainer() {
        let (harness, _) = listHarness(["one", "two"])
        harness.select(4)
        harness.insertTab()
        #expect(harness.string == "one\ntwo")
        #expect(harness.textLists(at: 4).count == 2)
        #expect(harness.block(at: 4)?.containers == [.listItem, .listItem])
        let style = harness.storage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.headIndent == Restyler.listIndent * 2)

        harness.insertBacktab()
        #expect(harness.textLists(at: 4).count == 1)
        #expect(harness.block(at: 4)?.containers == [.listItem])
    }

    @Test func nativeReturnOnCheckedTaskCreatesUncheckedItem() {
        let (harness, _) = listHarness(["done", "next"], task: .checked)
        harness.select(4)
        harness.insertNewline()
        #expect(harness.paragraphTexts == ["done", "", "next"])
        #expect(harness.block(at: 0)?.task == .checked)
        #expect(harness.block(at: 5)?.task == .unchecked)
        #expect(harness.block(at: 6)?.task == .checked)
    }

    @Test func emptyItemReturnEndsListAndDropsContainer() {
        let (harness, _) = listHarness(["one", "", "three"])
        harness.select(4)
        harness.insertNewline()
        #expect(harness.textLists(at: 4).isEmpty)
        #expect(harness.block(at: 4) == .paragraph)
        #expect(harness.block(at: 0)?.isListItem == true)
    }

    @Test func shiftReturnKeepsParagraphBlock() {
        let quote = GroupToken.mint()
        let block = MarkdownBlock(containers: [.quote(quote)])
        let harness = EditorHarness(pipeline: .normalizer)
        harness.load(StorageBuilder.build { $0.paragraph("ab", block, separator: false) })
        harness.select(1)
        harness.insertLineBreak()
        #expect(harness.string == "a\u{2028}b")
        #expect(harness.paragraphBlocks == [block])
        #expect(harness.storage.isMarkdownHardBreak(at: 1))
    }

    @Test func markedTextBlocksNormalizationUntilCommitted() {
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        let harness = EditorHarness(pipeline: .normalizer)
        let storage = StorageBuilder.build { $0.paragraph("Title", separator: false) }
        storage.addAttribute(.markdownBlock, value: heading, range: NSRange(location: 0, length: 1))
        harness.load(storage)
        harness.select(5)
        harness.setMarkedText("に")
        #expect(harness.textView.hasMarkedText())
        #expect(!harness.storage.isBlockUniform(in: NSRange(location: 0, length: harness.storage.length)))
        harness.unmarkText()
        harness.select(6)
        harness.type("x")
        #expect(harness.string == "Titleにx")
        #expect(harness.paragraphBlocks == [heading])
        #expect(harness.storage.isBlockUniform(in: NSRange(location: 0, length: harness.storage.length)))
    }

    @Test func undoRestoresBlockAndRestyles() {
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        let harness = EditorHarness(pipeline: .normalizer)
        harness.load(StorageBuilder.build {
            $0.paragraph("Head", heading)
            $0.paragraph("body", separator: false)
        })
        harness.select(5)
        harness.deleteBackward()
        #expect(harness.paragraphBlocks == [heading])
        harness.undo()
        #expect(harness.string == "Head\nbody")
        #expect(harness.paragraphBlocks == [heading, .paragraph])
        let font = harness.storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        #expect(font == harness.controller.theme.bodyFont)

        harness.redo()
        #expect(harness.string == "Headbody")
        #expect(harness.storage.isBlockUniform(in: NSRange(location: 0, length: 8)))
        harness.undo()
        #expect(harness.paragraphBlocks == [heading, .paragraph])
    }

    @Test func typedCharacterAfterBoldRunInheritsMarks() {
        guard Marks.keyIsCustom else { return }
        let harness = EditorHarness(pipeline: .normalizer)
        let storage = StorageBuilder.build { $0.paragraph("bold", separator: false) }
        storage.addIntent(.stronglyEmphasized, NSRange(location: 0, length: 4))
        harness.load(storage)
        harness.select(4)
        harness.type("er")
        #expect(harness.storage.markdownInlineIntent(at: 5) == .stronglyEmphasized)
        #expect((harness.storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.fontTraits == [.bold])
    }
}
#endif
