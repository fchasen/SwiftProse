#if canImport(AppKit) && os(macOS)
import AppKit
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
final class EditorHarness: NSObject, NSTextViewDelegate {
    enum Pipeline {
        case controller
        case normalizer
    }

    let controller: EditorController
    let window: NSWindow
    let textView: ProseNSTextView
    let pipeline: Pipeline
    private(set) var pushes: [String] = []
    private var storageDelegate: NormalizingStorageDelegate?

    var storage: NSTextStorage { controller.textStorage }
    var undoManager: UndoManager { controller.undoManager }
    var string: String { storage.string }

    init(markdown: String = "", pipeline: Pipeline = .controller, width: CGFloat = 480) {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        controller = EditorController(markdown: markdown, undoManager: undoManager)
        self.pipeline = pipeline
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        controller.textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView = ProseNSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600), textContainer: controller.textContainer)
        super.init()

        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.markdownController = controller
        window.contentView = textView
        controller.hostTextView = textView
        controller.textSink = { [weak self] markdown in self?.pushes.append(markdown) }

        if pipeline == .normalizer {
            let delegate = NormalizingStorageDelegate(controller: controller, textView: textView)
            storageDelegate = delegate
            controller.textStorage.delegate = delegate
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func load(_ attributed: NSAttributedString) {
        storageDelegate?.isSuspended = true
        storage.beginEditing()
        storage.setAttributedString(attributed)
        controller.restyler.restyleAll(storage)
        storage.endEditing()
        storageDelegate?.isSuspended = false
        undoManager.removeAllActions()
        pushes.removeAll()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func clearPushes() {
        pushes.removeAll()
    }

    func step(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
    }

    func select(_ location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    var selection: NSRange { textView.selectedRange() }

    func type(_ text: String) {
        step { textView.insertText(text, replacementRange: textView.selectedRange()) }
    }

    func insertNewline() {
        step { textView.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    }

    func insertLineBreak() {
        step { textView.doCommand(by: #selector(NSResponder.insertLineBreak(_:))) }
    }

    func insertTab() {
        step { textView.doCommand(by: #selector(NSResponder.insertTab(_:))) }
    }

    func insertBacktab() {
        step { textView.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
    }

    func deleteBackward() {
        step { textView.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
    }

    func setMarkedText(_ text: String, selected: NSRange? = nil) {
        storageDelegate?.isMarking = true
        defer { storageDelegate?.isMarking = false }
        step {
            textView.setMarkedText(
                text,
                selectedRange: selected ?? NSRange(location: (text as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
    }

    func unmarkText() {
        step { textView.unmarkText() }
    }

    func undo() {
        undoManager.undo()
    }

    func redo() {
        undoManager.redo()
    }

    func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    var isTextKit2: Bool {
        spin()
        return textView.textLayoutManager != nil
    }

    func block(at index: Int) -> MarkdownBlock? {
        storage.markdownBlock(at: index)
    }

    var paragraphBlocks: [MarkdownBlock?] {
        storage.markdownParagraphRanges()
            .filter { $0.length > 0 }
            .map { storage.markdownBlock(at: $0.location) }
    }

    var paragraphTexts: [String] {
        let ns = storage.string as NSString
        return storage.markdownParagraphRanges()
            .filter { $0.length > 0 }
            .map { ns.substring(with: $0).trimmingCharacters(in: CharacterSet(charactersIn: "\n")) }
    }

    func textLists(at index: Int) -> [NSTextList] {
        (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        controller.undoManager
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString {
            for plugin in controller.plugins {
                if plugin.props.handleTextInput?(controller, affectedCharRange, replacementString) == true { return false }
            }
        }
        return controller.shouldChangeText(in: affectedCharRange, replacement: replacementString)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard pipeline == .controller else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if controller.handleNewline() { return true }
        case #selector(NSResponder.deleteBackward(_:)):
            if controller.handleBackspace() { return true }
        case #selector(NSResponder.insertTab(_:)):
            if controller.handleTab(backward: false) { return true }
        case #selector(NSResponder.insertBacktab(_:)):
            if controller.handleTab(backward: true) { return true }
        default:
            break
        }
        return controller.handleCommand(commandSelector)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        controller.selectionDidChange(textView.selectedRange())
    }
}

final class NormalizingStorageDelegate: NSObject, NSTextStorageDelegate {
    unowned let controller: EditorController
    weak var textView: NSTextView?
    var isSuspended = false
    var isMarking = false
    private(set) var normalizedRanges: [NSRange] = []

    init(controller: EditorController, textView: NSTextView?) {
        self.controller = controller
        self.textView = textView
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isSuspended else { return }
        PasteSanitizer.captureForeignAttributes(in: textStorage, range: editedRange)
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isSuspended else { return }
        let undoManager = controller.undoManager
        var marked: NSRange? = textView.flatMap { $0.hasMarkedText() ? $0.markedRange() : nil }
        if isMarking {
            marked = marked.map { NSUnionRange($0, editedRange) } ?? editedRange
        }
        if undoManager.isUndoing || undoManager.isRedoing {
            let affected = Normalizer.affectedRange(for: editedRange, in: textStorage)
            controller.restyler.restyle(textStorage, in: affected, excluding: marked)
            return
        }
        let result = controller.normalizer.normalizeRecordingRevert(
            textStorage,
            editedRange: editedRange,
            changeInLength: editedMask.contains(.editedCharacters) ? delta : 0,
            markedRange: marked
        )
        normalizedRanges.append(result.touched)
        result.revert?.registerUndo(on: undoManager, storage: textStorage)
        controller.restyler.restyle(textStorage, in: result.touched, excluding: marked)
    }
}
#endif
