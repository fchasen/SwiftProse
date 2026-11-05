import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class SourceEditorController: NSObject, NSTextStorageDelegate {
    public typealias ObserverToken = EditorController.ObserverToken

    public let textStorage: NSTextStorage
    public let textContentStorage: NSTextContentStorage
    public let textLayoutManager: NSTextLayoutManager
    public let textContainer: NSTextContainer
    public let undoManager: UndoManager
    public let formatter = MarkdownSourceFormatter()

    public var theme: ProseTheme {
        didSet {
            guard theme != oldValue else { return }
            styler.theme = theme
            restyleAll()
            applyThemeToHost()
        }
    }

    public var codeBlockHighlighter: CodeBlockHighlighter? { codeHighlighting.highlighter }
    public var keymap: Keymap = .mac
    public var isEditable: Bool = true
    public var intrinsicSizeInvalidator: (() -> Void)?

    public weak var hostTextView: PlatformTextView?

    public var text: String { textStorage.string }

    let styler: SourceStyler
    let codeHighlighting = CodeHighlighting()
    var textSink: ((String) -> Void)?
    private(set) var lastPushed: String
    private var isLoading = false
    private(set) var historyEpoch = 0
    private var isStyling = false
    var commandDepth = 0
    var headlessSelection = NSRange(location: 0, length: 0)
    private var pendingChange: DocumentChange?
    private var flushScheduled = false
    private var deferredEdits: [() -> Void] = []
    private var deferredDrainScheduled = false
    private var pluginStates: [AnyPluginKey: Any] = [:]
    private var changeObservers: [(UUID, (DocumentChange) -> Void)] = []
    private var selectionObservers: [(UUID, (NSRange) -> Void)] = []
    private var keyHandlers: [(UUID, (String) -> Bool)] = []
    private var inputHandlers: [(UUID, (NSRange, String) -> Bool)] = []
    private var queuedChanges: [DocumentChange] = []
    private var isFanningOut = false

    public init(
        text: String = "",
        theme: ProseTheme = .default,
        codeBlockHighlighter: CodeBlockHighlighter? = nil,
        undoManager: UndoManager = UndoManager()
    ) {
        self.theme = theme
        self.undoManager = undoManager
        self.styler = SourceStyler(theme: theme)
        self.styler.preservesCodeForeground = codeBlockHighlighter != nil
        self.codeHighlighting.highlighter = codeBlockHighlighter
        self.textStorage = NSTextStorage()
        self.textContentStorage = NSTextContentStorage()
        self.textLayoutManager = NSTextLayoutManager()
        self.textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        self.lastPushed = text
        super.init()
        textContentStorage.textStorage = textStorage
        textContentStorage.addTextLayoutManager(textLayoutManager)
        textLayoutManager.textContainer = textContainer
        textStorage.delegate = self
        setText(text)
    }

    public func markdown() -> String {
        textStorage.string
    }

    public func setText(_ text: String) {
        isLoading = true
        unmarkHostText()
        let previousLength = textStorage.length
        textStorage.beginEditing()
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: styler.baseAttributes))
        styler.styleAll(textStorage)
        codeHighlighting.resetAll(in: textStorage, baseColor: styler.codeBaseColor)
        textStorage.endEditing()
        isLoading = false
        historyEpoch += 1
        undoManager.removeAllActions()
        pendingChange = nil
        deferredEdits.removeAll()
        lastPushed = text
        let caret = min(currentSelection.location, textStorage.length)
        setSelection(NSRange(location: caret, length: 0))
        applyTypingAttributes()
        intrinsicSizeInvalidator?()
        fanout(DocumentChange(
            editedRange: NSRange(location: 0, length: textStorage.length),
            changeInLength: textStorage.length - previousLength,
            origin: .load
        ))
    }

    func applyExternalText(_ text: String) {
        guard text != lastPushed else { return }
        setText(text)
    }

    func loadIfChanged(_ text: String) {
        guard text != textStorage.string else {
            lastPushed = text
            return
        }
        setText(text)
    }

    func loadRecordingUndo(_ text: String, selection: NSRange, actionName: String) {
        let old = textStorage.string as NSString
        let new = text as NSString
        guard !old.isEqual(to: text) else {
            lastPushed = text
            setSelection(selection)
            return
        }
        unmarkHostText()
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        let replaced = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        lastPushed = text
        let manager = effectiveUndoManager
        manager.beginUndoGrouping()
        replaceRegisteringUndo(
            replaced,
            with: replacement,
            selectionBefore: currentSelection,
            selectionAfter: selection,
            label: actionName,
            manager: manager
        )
        manager.endUndoGrouping()
        flushDocumentChanges()
    }

    public func setCodeBlockHighlighter(_ highlighter: CodeBlockHighlighter?) {
        guard highlighter !== codeHighlighting.highlighter else { return }
        codeHighlighting.highlighter = highlighter
        styler.preservesCodeForeground = highlighter != nil
        restyleAll()
    }

    func restyleAll() {
        let wasStyling = isStyling
        isStyling = true
        defer { isStyling = wasStyling }
        textStorage.beginEditing()
        styler.styleAll(textStorage)
        if codeHighlighting.isActive {
            codeHighlighting.resetAll(in: textStorage, baseColor: styler.codeBaseColor)
        } else {
            codeHighlighting.removeAll()
        }
        textStorage.endEditing()
        applyTypingAttributes()
    }

    var baseAttributes: [NSAttributedString.Key: Any] { styler.baseAttributes }

    func applyTypingAttributes() {
        #if canImport(AppKit) && os(macOS)
        hostTextView?.typingAttributes = styler.baseAttributes
        #elseif canImport(UIKit)
        hostTextView?.typingAttributes = styler.baseAttributes
        #endif
    }

    func applyThemeToHost() {
        guard let hostTextView else { return }
        let inset = theme.textContainerInset
        #if canImport(AppKit) && os(macOS)
        if hostTextView.textContainerInset != inset { hostTextView.textContainerInset = inset }
        #elseif canImport(UIKit)
        let insets = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
        if hostTextView.textContainerInset != insets { hostTextView.textContainerInset = insets }
        #endif
        applyTypingAttributes()
    }

    public var currentSelection: NSRange {
        #if canImport(AppKit) && os(macOS)
        if let hostTextView { return hostTextView.selectedRange() }
        #elseif canImport(UIKit)
        if let hostTextView { return hostTextView.selectedRange }
        #endif
        return headlessSelection
    }

    public func setSelection(_ range: NSRange) {
        let clamped = Normalizer.clamp(range, to: textStorage.length)
        headlessSelection = clamped
        #if canImport(AppKit) && os(macOS)
        hostTextView?.setSelectedRange(clamped)
        #elseif canImport(UIKit)
        hostTextView?.selectedRange = clamped
        #endif
    }

    var hostHasMarkedText: Bool {
        guard let hostTextView else { return false }
        #if canImport(AppKit) && os(macOS)
        return hostTextView.hasMarkedText()
        #elseif canImport(UIKit)
        return hostTextView.markedTextRange != nil
        #else
        return false
        #endif
    }

    var hostMarkedRange: NSRange? {
        guard let hostTextView else { return nil }
        #if canImport(AppKit) && os(macOS)
        guard hostTextView.hasMarkedText() else { return nil }
        let range = hostTextView.markedRange()
        return range.location == NSNotFound ? nil : range
        #elseif canImport(UIKit)
        guard let marked = hostTextView.markedTextRange else { return nil }
        let start = hostTextView.offset(from: hostTextView.beginningOfDocument, to: marked.start)
        let end = hostTextView.offset(from: hostTextView.beginningOfDocument, to: marked.end)
        return NSRange(location: start, length: max(0, end - start))
        #else
        return nil
        #endif
    }

    func unmarkHostText() {
        guard hostHasMarkedText, let hostTextView else { return }
        hostTextView.unmarkText()
    }

    var isApplyingCommand: Bool { commandDepth > 0 }

    public func canPerform(_ action: EditorAction) -> Bool {
        isEditable && formatter.canPerform(action, in: text, selection: currentSelection)
    }

    public func isActive(_ action: EditorAction) -> Bool {
        formatter.isActive(action, in: text, selection: currentSelection)
    }

    public func actionStates(for actions: [EditorAction]) -> MarkdownSourceFormatter.ActionStates {
        var states = formatter.states(for: actions, in: text, selection: currentSelection)
        if !isEditable { states.disabled = Set(actions.map(\.stableID)) }
        return states
    }

    @discardableResult
    public func perform(_ action: EditorAction) -> Bool {
        guard isEditable, let edit = formatter.edit(for: action, in: text, selection: currentSelection) else { return false }
        return apply(edit, label: action.title)
    }

    @discardableResult
    public func apply(_ edit: MarkdownSourceEdit, label: String = "Edit") -> Bool {
        guard isEditable else { return false }
        let total = textStorage.length
        guard edit.range.location >= 0, NSMaxRange(edit.range) <= total else { return false }
        unmarkHostText()
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            guard replace(edit.range, with: edit.replacement, selection: edit.selection, label: label) else { return false }
        } else {
            setSelection(edit.selection)
        }
        scrollSelectionToVisible()
        flushDocumentChanges()
        return true
    }

    private func replace(_ range: NSRange, with replacement: String, selection: NSRange, label: String) -> Bool {
        #if canImport(AppKit) && os(macOS)
        if let textView = hostTextView, textView.isEditable {
            textView.breakUndoCoalescing()
            commandDepth += 1
            defer { commandDepth -= 1 }
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
            textStorage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            if !label.isEmpty { textView.undoManager?.setActionName(label) }
            textView.breakUndoCoalescing()
            setSelection(selection)
            return true
        }
        #endif
        let manager = effectiveUndoManager
        manager.beginUndoGrouping()
        replaceRegisteringUndo(range, with: replacement, selectionBefore: currentSelection, selectionAfter: selection, label: label, manager: manager)
        manager.endUndoGrouping()
        return true
    }

    var effectiveUndoManager: UndoManager {
        #if canImport(UIKit) && !os(macOS)
        if let manager = hostTextView?.undoManager { return manager }
        #endif
        return undoManager
    }

    private func replaceRegisteringUndo(
        _ range: NSRange,
        with replacement: String,
        selectionBefore: NSRange,
        selectionAfter: NSRange,
        label: String,
        manager: UndoManager
    ) {
        let target = Normalizer.clamp(range, to: textStorage.length)
        let previous = (textStorage.string as NSString).substring(with: target)
        let inserted = NSRange(location: target.location, length: (replacement as NSString).length)
        manager.registerUndo(withTarget: self) { [weak manager] controller in
            guard let manager else { return }
            controller.unmarkHostText()
            let opens = manager.groupingLevel == 0
            if opens { manager.beginUndoGrouping() }
            controller.replaceRegisteringUndo(
                inserted,
                with: previous,
                selectionBefore: selectionAfter,
                selectionAfter: selectionBefore,
                label: label,
                manager: manager
            )
            if opens { manager.endUndoGrouping() }
            controller.flushDocumentChanges()
        }
        if !label.isEmpty { manager.setActionName(label) }
        commandDepth += 1
        textStorage.replaceCharacters(in: target, with: replacement)
        commandDepth -= 1
        setSelection(selectionAfter)
    }

    private func scrollSelectionToVisible() {
        #if canImport(AppKit) && os(macOS)
        hostTextView?.scrollRangeToVisible(currentSelection)
        #elseif canImport(UIKit)
        hostTextView?.scrollRangeToVisible(currentSelection)
        #endif
    }

    @discardableResult
    public func insertMarkdown(_ markdown: String, replacing range: NSRange, label: String = "Insert") -> Bool {
        let target = Normalizer.clamp(range, to: textStorage.length)
        return apply(.insertion(PasteSanitizer.normalizeLineEndings(markdown), replacing: target), label: label)
    }

    @discardableResult
    public func insertMarkdown(_ markdown: String, label: String = "Insert") -> Bool {
        insertMarkdown(markdown, replacing: currentSelection, label: label)
    }

    @discardableResult
    public func replaceText(in range: NSRange, with text: String, label: String = "Replace") -> Bool {
        insertMarkdown(text, replacing: range, label: label)
    }

    @discardableResult
    public func insertLink(label: String, url: String) -> Bool {
        let selection = currentSelection
        let edit = formatter.edit(for: .link(url: url, label: label), in: text, selection: selection)
            ?? .insertion("[\(label)](\(url))", replacing: selection)
        return apply(edit, label: "Insert Link")
    }

    @discardableResult
    public func insertInlineContent(
        _ content: ProseInlineContent,
        markdownSource: String,
        replacing range: NSRange,
        trailingText: String = " ",
        label: String = "Insert"
    ) -> Bool {
        insertMarkdown(markdownSource + trailingText, replacing: range, label: label)
    }

    @discardableResult
    public func insertMarkdownAtLineStart(_ markdown: String, replacingLeading rule: InlineContentRule?, label: String = "Insert") -> Bool {
        guard isEditable else { return false }
        let ns = textStorage.string as NSString
        let caret = min(currentSelection.location, ns.length)
        let line = SourceLineSpan.at(caret, in: ns)
        let content = line.content
        let start = content.location + SourceDocument.parsePrefix(ns, content).contentStart
        let target = rule?.leadingMatch(in: ns, at: start, limit: line.contentsEnd) ?? NSRange(location: start, length: 0)
        return insertMarkdown(markdown, replacing: target, label: label)
    }

    public func isLocationInCode(_ location: Int) -> Bool {
        let total = textStorage.length
        guard total > 0 else { return false }
        let ns = textStorage.string as NSString
        let line = SourceLineSpan.at(min(location, total), in: ns)
        if line.range.length > 0, textStorage.markdownBlock(at: line.range.location)?.isCode == true { return true }
        if line.range.length == 0, line.range.location > 0,
           let state = textStorage.attribute(.markdownSourceLineState, at: line.range.location - 1, effectiveRange: nil) as? SourceLineState,
           state.fenceGroup != nil {
            return true
        }
        guard location > line.range.location, location < line.contentsEnd else { return false }
        return textStorage.markdownInlineIntent(at: location - 1).contains(.code)
            && textStorage.markdownInlineIntent(at: location).contains(.code)
    }

    public func caretRect() -> CGRect? {
        rect(forCharacterAt: currentSelection.location)
    }

    public func rect(forCharacterAt index: Int) -> CGRect? {
        guard index >= 0, index <= textStorage.length else { return nil }
        let docStart = textContentStorage.documentRange.location
        guard let location = textContentStorage.location(docStart, offsetBy: index) else { return nil }
        textLayoutManager.ensureLayout(for: NSTextRange(location: location))
        var rect: CGRect?
        textLayoutManager.enumerateTextSegments(
            in: NSTextRange(location: location),
            type: .standard,
            options: [.upstreamAffinity, .rangeNotRequired]
        ) { _, frame, _, _ in
            rect = frame
            return false
        }
        guard var result = rect else { return nil }
        #if canImport(AppKit) && os(macOS)
        if let hostTextView {
            result.origin.x += hostTextView.textContainerOrigin.x
            result.origin.y += hostTextView.textContainerOrigin.y
        }
        #elseif canImport(UIKit)
        if let hostTextView {
            result.origin.x += hostTextView.textContainerInset.left
            result.origin.y += hostTextView.textContainerInset.top
        }
        #endif
        return result
    }

    public func pluginState<State>(for key: PluginKey<State>) -> State? {
        pluginStates[key.any] as? State
    }

    public func setPluginState<State>(_ state: State, for key: PluginKey<State>) {
        pluginStates[key.any] = state
    }

    public func clearPluginState<State>(for key: PluginKey<State>) {
        pluginStates.removeValue(forKey: key.any)
    }

    @discardableResult
    public func addOnTextChange(_ handler: @escaping (DocumentChange) -> Void) -> ObserverToken {
        let id = UUID()
        changeObservers.append((id, handler))
        return ObserverToken(id: id)
    }

    @discardableResult
    public func addOnSelectionChanged(_ handler: @escaping (NSRange) -> Void) -> ObserverToken {
        let id = UUID()
        selectionObservers.append((id, handler))
        return ObserverToken(id: id)
    }

    @discardableResult
    public func addKeyHandler(_ handler: @escaping (String) -> Bool) -> ObserverToken {
        let id = UUID()
        keyHandlers.append((id, handler))
        return ObserverToken(id: id)
    }

    @discardableResult
    public func addTextInputHandler(_ handler: @escaping (NSRange, String) -> Bool) -> ObserverToken {
        let id = UUID()
        inputHandlers.append((id, handler))
        return ObserverToken(id: id)
    }

    public func removeObserver(_ token: ObserverToken) {
        changeObservers.removeAll { $0.0 == token.id }
        selectionObservers.removeAll { $0.0 == token.id }
        keyHandlers.removeAll { $0.0 == token.id }
        inputHandlers.removeAll { $0.0 == token.id }
    }

    var hasKeyHandlers: Bool { !keyHandlers.isEmpty }

    func dispatchKey(_ name: String) -> Bool {
        guard !hostHasMarkedText else { return false }
        for (_, handler) in keyHandlers where handler(name) { return true }
        return false
    }

    func hostShouldChangeText(in range: NSRange, replacement: String?) -> Bool {
        guard !isApplyingCommand, let replacement else { return true }
        for (_, handler) in inputHandlers where handler(range, replacement) { return false }
        return true
    }

    func selectionDidChange(_ range: NSRange) {
        headlessSelection = range
        for (_, handler) in selectionObservers { handler(range) }
    }

    func performKeymapAction(_ action: EditorAction) -> Bool {
        guard isEditable, !hostHasMarkedText else { return false }
        perform(action)
        return true
    }

    func action(forCommandKey key: String, shift: Bool, option: Bool) -> EditorAction? {
        keymap.action(forKey: KeySpec.make(key: key, mod: true, shift: shift, alt: option))
    }

    func pushBinding() {
        guard !isLoading, !hostHasMarkedText else { return }
        let value = textStorage.string
        guard value != lastPushed else { return }
        lastPushed = value
        textSink?(value)
    }

    func compositionDidEnd() {
        pushBinding()
        let caret = min(currentSelection.location, textStorage.length)
        let wasStyling = isStyling
        isStyling = true
        let pass = styler.restyle(textStorage, editedRange: NSRange(location: caret, length: 0))
        if codeHighlighting.isActive {
            codeHighlighting.update(
                textStorage,
                editedRange: NSRange(location: caret, length: 0),
                examined: pass.restyled,
                charactersEdited: false,
                scansStructure: pass.structureChanged,
                excluding: nil,
                baseColor: styler.codeBaseColor
            )
        }
        isStyling = wasStyling
        flushDocumentChanges()
    }

    var hasPendingDocumentChange: Bool { pendingChange != nil }

    func flushDocumentChanges() {
        guard let change = pendingChange else { return }
        pendingChange = nil
        fanout(change)
    }

    private func fanout(_ change: DocumentChange) {
        queuedChanges.append(change)
        guard !isFanningOut else { return }
        isFanningOut = true
        defer { isFanningOut = false }
        while !queuedChanges.isEmpty {
            let next = queuedChanges.removeFirst()
            for (_, handler) in changeObservers { handler(next) }
        }
    }

    func deferEdit(_ work: @escaping () -> Void) {
        deferredEdits.append(work)
        guard !deferredDrainScheduled else { return }
        deferredDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainDeferredEdits()
        }
    }

    func drainDeferredEdits() {
        deferredDrainScheduled = false
        while !deferredEdits.isEmpty {
            deferredEdits.removeFirst()()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushDocumentChanges()
        }
    }

    private func recordChange(_ editedRange: NSRange, delta: Int, origin: DocumentChange.Origin) {
        if let existing = pendingChange {
            pendingChange = DocumentChange(
                editedRange: existing.editedRange.merged(withEdit: editedRange, changeInLength: delta),
                changeInLength: existing.changeInLength + delta,
                origin: existing.origin == origin ? origin : (origin == .user ? existing.origin : origin)
            )
        } else {
            pendingChange = DocumentChange(editedRange: editedRange, changeInLength: delta, origin: origin)
        }
    }

    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: PlatformTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isLoading, !isStyling, editedMask.contains(.editedCharacters) else { return }
        isStyling = true
        defer { isStyling = false }
        let pass = styler.restyle(textStorage, editedRange: editedRange)
        if codeHighlighting.isActive {
            codeHighlighting.update(
                textStorage,
                editedRange: editedRange,
                examined: pass.restyled,
                charactersEdited: true,
                scansStructure: pass.structureChanged,
                excluding: hostMarkedRange,
                baseColor: styler.codeBaseColor
            )
        }
        let manager = effectiveUndoManager
        let origin: DocumentChange.Origin = (manager.isUndoing || manager.isRedoing) ? .undo : (isApplyingCommand ? .command : .user)
        recordChange(editedRange, delta: delta, origin: origin)
        pushBinding()
        intrinsicSizeInvalidator?()
        scheduleFlush()
    }
}

extension SourceEditorController: CompletionSupporting {
    var isComposingText: Bool { hostHasMarkedText }

    func allowsCompletionTrigger(at location: Int, replacing range: NSRange, allowedInCode: Bool) -> Bool {
        allowedInCode || !isLocationInCode(location)
    }
}
