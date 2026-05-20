import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct ClipboardTests {

    private final class TrackingPlugin: EditorPlugin {
        let key = AnyPluginKey(name: "clipboard.test")
        var consume: Bool = false
        var lastEvent: PasteEvent?
        var lastSource: PasteEvent.Source?
        var transformPastedTextSeen: String?
        var transformPastedSeen: PasteEvent?

        var props: PluginProps {
            PluginProps(
                handlePaste: { [weak self] _, event in
                    guard let self else { return false }
                    self.lastEvent = event
                    self.lastSource = event.source
                    return self.consume
                },
                transformPastedText: { [weak self] _, text, _ in
                    self?.transformPastedTextSeen = text
                    return text
                },
                transformPasted: { [weak self] _, event in
                    self?.transformPastedSeen = event
                    return event
                }
            )
        }
    }

    @Test func handlePasteCanConsume() throws {
        let controller = try EditorController(initialMarkdown: "hello", theme: .default)
        controller.testSelection = NSRange(location: 5, length: 0)
        let plugin = TrackingPlugin()
        plugin.consume = true
        controller.register(plugin: plugin)
        let event = PasteEvent(text: " world", selection: NSRange(location: 5, length: 0))
        let consumed = controller.dispatchPaste(event)
        #expect(consumed == true)
        // Default insertion was suppressed — storage is unchanged.
        #expect(controller.markdown() == "hello\n")
        #expect(plugin.lastSource == .paste)
        // transformPasted{,Text} should not run when handlePaste consumed.
        #expect(plugin.transformPastedTextSeen == nil)
        #expect(plugin.transformPastedSeen == nil)
    }

    @Test func defaultBranchInsertsPlainText() throws {
        let controller = try EditorController(initialMarkdown: "hi", theme: .default)
        controller.testSelection = NSRange(location: 2, length: 0)
        let event = PasteEvent(
            text: " there",
            selection: NSRange(location: 2, length: 0)
        )
        #expect(controller.dispatchPaste(event) == true)
        #expect(controller.markdown() == "hi there\n")
    }

    @Test func multiBlockSplitOnBlankLineRuns() throws {
        let controller = try EditorController(initialMarkdown: "start", theme: .default)
        controller.testSelection = NSRange(location: 5, length: 0)
        let event = PasteEvent(
            text: "\n\nfirst\n\nsecond",
            selection: NSRange(location: 5, length: 0)
        )
        _ = controller.dispatchPaste(event)
        // \n\n runs collapse to single \n in storage; the segmenter +
        // repair pass turns each \n into a paragraph boundary in the
        // markdown round-trip.
        #expect(controller.markdown() == "start\n\nfirst\n\nsecond\n")
    }

    @Test func collapseBlankLineRunsCollapsesAllRunsToSingleNewline() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        #expect(controller.collapseBlankLineRuns("a\n\nb") == "a\nb")
        #expect(controller.collapseBlankLineRuns("a\n\n\n\nb") == "a\nb")
        #expect(controller.collapseBlankLineRuns("a\nb") == "a\nb")
        #expect(controller.collapseBlankLineRuns("no newlines") == "no newlines")
        // The plain branch then relies on the segmenter to turn single \n
        // into block boundaries during repair.
    }

    @Test func plainBranchCollapsesMultiBlankRuns() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.dispatchPaste(
            PasteEvent(
                text: "a\n\n\n\nb",
                selection: NSRange(location: 0, length: 0)
            )
        )
        // Any run of 2+ blank lines lands as exactly one paragraph break.
        #expect(controller.markdown() == "a\n\nb\n")
    }

    @Test func plainTextRouteSkipsHtmlEvenWhenPresent() throws {
        let controller = try EditorController(initialMarkdown: "x", theme: .default)
        controller.testSelection = NSRange(location: 1, length: 0)
        let event = PasteEvent(
            text: "y",
            html: "<b>y</b>",
            plainText: true,
            selection: NSRange(location: 1, length: 0)
        )
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown() == "xy\n")
    }

    @Test func transformPastedTextChainsBeforeInsert() throws {
        let controller = try EditorController(initialMarkdown: "a", theme: .default)
        controller.testSelection = NSRange(location: 1, length: 0)

        final class UpperPlugin: EditorPlugin {
            let key = AnyPluginKey(name: "upper")
            var props: PluginProps {
                PluginProps(
                    transformPastedText: { _, text, _ in text.uppercased() }
                )
            }
        }
        controller.register(plugin: UpperPlugin())
        let event = PasteEvent(text: "bc", selection: NSRange(location: 1, length: 0))
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown() == "aBC\n")
    }

    @Test func transformPastedRewritesEvent() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)

        final class RewritePlugin: EditorPlugin {
            let key = AnyPluginKey(name: "rewrite")
            var props: PluginProps {
                PluginProps(transformPasted: { _, event in
                    var copy = event
                    copy.text = "swapped"
                    return copy
                })
            }
        }
        controller.register(plugin: RewritePlugin())
        let event = PasteEvent(text: "ignored", selection: NSRange(location: 0, length: 0))
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown() == "swapped\n")
    }

    @Test func dictationLandsAsOneUndoStep() throws {
        let controller = try EditorController(initialMarkdown: "hi", theme: .default)
        controller.testSelection = NSRange(location: 2, length: 0)
        let event = PasteEvent(
            text: " hello\n\nworld",
            plainText: true,
            source: .dictation,
            selection: NSRange(location: 2, length: 0)
        )
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown() == "hi hello\n\nworld\n")
        #expect(controller.undoManager.canUndo)
        controller.undoManager.undo()
        // One undo step reverts the whole insertion.
        #expect(controller.markdown() == "hi\n")
    }

    @Test func emptyTextEventIsNoOp() throws {
        let controller = try EditorController(initialMarkdown: "abc", theme: .default)
        controller.testSelection = NSRange(location: 3, length: 0)
        let event = PasteEvent(text: "", selection: NSRange(location: 3, length: 0))
        #expect(controller.dispatchPaste(event) == false)
        #expect(controller.markdown() == "abc\n")
    }

    @Test func nilTextEventIsNoOp() throws {
        let controller = try EditorController(initialMarkdown: "abc", theme: .default)
        controller.testSelection = NSRange(location: 3, length: 0)
        let event = PasteEvent(text: nil, selection: NSRange(location: 3, length: 0))
        #expect(controller.dispatchPaste(event) == false)
        #expect(controller.markdown() == "abc\n")
    }

    @Test func readOnlyControllerSkipsDefaultInsertion() throws {
        let controller = try EditorController(initialMarkdown: "abc", theme: .default)
        controller.testSelection = NSRange(location: 3, length: 0)
        controller.isEditable = false
        let event = PasteEvent(text: " more", selection: NSRange(location: 3, length: 0))
        #expect(controller.dispatchPaste(event) == false)
        #expect(controller.markdown() == "abc\n")
    }

    @Test func crlfNormalization() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)
        let event = PasteEvent(
            text: "one\r\ntwo\rthree",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        // \r\n and bare \r are folded to \n. Single \n stays as soft break
        // inside the same paragraph — markdown emits it as a line continuation.
        let md = controller.markdown()
        #expect(!md.contains("\r"))
        #expect(md.contains("one"))
        #expect(md.contains("two"))
        #expect(md.contains("three"))
    }
}

#if canImport(AppKit) && os(macOS)
@MainActor
@Suite(.serialized) struct MacDictationHeuristicTests {

    @Test func multiCharWithNewlineRoutesToPaste() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)
        let view = ProseTextViewMac(
            controller: controller,
            text: .constant("")
        )
        let coordinator = view.makeCoordinator()
        let tv = NSTextView()
        // Simulate AppKit dispatching a dictated phrase via the delegate.
        let should = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "hello\n\nworld"
        )
        #expect(should == false, "structured branch should swallow the default insert")
        #expect(controller.markdown() == "hello\n\nworld\n")
    }

    @Test func singleCharStaysOnDefaultPath() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)
        let view = ProseTextViewMac(
            controller: controller,
            text: .constant("")
        )
        let coordinator = view.makeCoordinator()
        let tv = NSTextView()
        // Single char must not route — input rules need to see typing.
        // Returning true authorizes AppKit's per-char insertion path.
        let should = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "a"
        )
        #expect(should == true)
    }

    @Test func multiCharWithoutWhitespaceStaysOnDefaultPath() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)
        let view = ProseTextViewMac(
            controller: controller,
            text: .constant("")
        )
        let coordinator = view.makeCoordinator()
        let tv = NSTextView()
        // Multi-byte token without whitespace looks like IME-finalized text;
        // leave it to AppKit so composition completes normally.
        let should = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "東京"
        )
        #expect(should == true)
    }

    @Test func optOutKeepsRawInsertSemantics() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.useStructuredBulkInsert = false
        let view = ProseTextViewMac(
            controller: controller,
            text: .constant("")
        )
        let coordinator = view.makeCoordinator()
        let tv = NSTextView()
        let should = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "hello world"
        )
        #expect(should == true, "opt-out flag must restore the raw insert path")
    }
}
#endif
