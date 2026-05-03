import Foundation
import MarginaliaSyntax
import MarginaliaRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class EditorController {

    public typealias Dialect = MarginaliaView.Dialect

    public let textStorage: NSTextStorage
    public let contentStorage: NSTextContentStorage
    public let layoutManager: NSTextLayoutManager
    public let textContainer: NSTextContainer

    public var theme: MarginaliaTheme {
        didSet { recompile() }
    }
    public var dialect: Dialect {
        didSet { recompile() }
    }
    public var mode: Mode {
        didSet { recompile() }
    }

    public private(set) var blocks: [BlockSegment] = []

    public let undoManager: UndoManager = UndoManager()
    public weak var hostTextView: AnyObject?
    public var intrinsicSizeInvalidator: (() -> Void)?
    public var onDiagnostic: ((SpecDiagnostic) -> Void)?

    private(set) var compiler: MarkdownAttributedCompiler
    private(set) var serializer: AttributedMarkdownSerializer
    private let layoutDelegate: LayoutManagerDelegate
    private var storageObserver: NSObjectProtocol?
    private var applyingMarkdown = false

    public init(
        initialMarkdown: String = "",
        theme: MarginaliaTheme = .default,
        dialect: Dialect = .commonMark,
        mode: Mode = .rich,
        containerSize: CGSize = CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
    ) throws {
        self.theme = theme
        self.dialect = dialect
        self.mode = mode
        self.compiler = try MarkdownAttributedCompiler()
        self.serializer = AttributedMarkdownSerializer()

        self.textStorage = NSTextStorage()
        self.contentStorage = NSTextContentStorage()
        self.contentStorage.textStorage = textStorage
        self.layoutManager = NSTextLayoutManager()
        self.contentStorage.addTextLayoutManager(layoutManager)
        self.textContainer = NSTextContainer(size: containerSize)
        self.layoutManager.textContainer = textContainer

        self.layoutDelegate = LayoutManagerDelegate()
        layoutManager.delegate = layoutDelegate
        layoutDelegate.controller = self

        applyingMarkdown = true
        let initial = compileFor(initialMarkdown)
        textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: initial)
        applyingMarkdown = false
        resegment()

        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: nil
        ) { [weak self] _ in
            guard let self, !self.applyingMarkdown else { return }
            if self.textStorage.editedMask.contains(.editedCharacters) {
                self.scrubTypedAttributes()
                self.repairEditedLine()
                self.demoteEmptyStyledLines()
                self.resegment()
                self.intrinsicSizeInvalidator?()
            }
        }
    }

    private func repairEditedLine() {
        let total = textStorage.length
        guard total > 0 else { return }
        let edited = textStorage.editedRange
        guard edited.location >= 0,
              edited.location <= total,
              edited.location + edited.length <= total else { return }
        // paragraphRange(for:) on the full edit range gives the union of
        // every paragraph the edit overlaps. Repairing only the line at
        // editedRange.location would miss multi-line pastes.
        let ns = textStorage.string as NSString
        let probe = NSRange(
            location: max(0, min(edited.location, max(0, total - 1))),
            length: min(edited.length, total - min(edited.location, total))
        )
        let lineRange = ns.paragraphRange(for: probe)
        applyingMarkdown = true
        SpecValidator.repair(in: textStorage, range: lineRange)
        applyingMarkdown = false
    }


    private func scrubTypedAttributes() {
        let editedRange = textStorage.editedRange
        guard editedRange.length > 0 else { return }
        let safe = NSRange(
            location: max(0, min(editedRange.location, textStorage.length)),
            length: max(0, min(editedRange.length, textStorage.length - max(0, min(editedRange.location, textStorage.length))))
        )
        guard safe.length > 0 else { return }
        applyingMarkdown = true
        textStorage.beginEditing()
        let ns = textStorage.string as NSString
        var i = safe.location
        let endIdx = min(safe.location + safe.length, textStorage.length)
        while i < endIdx {
            let charRange = NSRange(location: i, length: 1)
            let isAttachmentGlyph = ns.character(at: i) == 0xFFFC
                && textStorage.safeAttribute(.attachment, at: i) != nil
            if !isAttachmentGlyph {
                textStorage.removeAttribute(.attachment, range: charRange)
                textStorage.removeAttribute(.marginaliaListMarker, range: charRange)
            }
            i += 1
        }
        textStorage.endEditing()
        applyingMarkdown = false
    }

    /// After a character edit, scan the edited paragraphs and reset any
    /// non-paragraph block attribution on lines whose content text is now
    /// empty. Without this, deleting all of a heading's text leaves the
    /// heading block attribute on the trailing newline (or on the text
    /// view's `typingAttributes`) so the next keystroke continues to
    /// render in heading style.
    private func demoteEmptyStyledLines() {
        let plainAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: NSParagraphStyle(),
            .marginaliaBlockSpec: BlockSpecBox(.paragraph)
        ]
        if textStorage.length == 0 {
            applyTypingAttributes(plainAttrs)
            return
        }
        let editedRange = textStorage.editedRange
        let ns = textStorage.string as NSString
        guard editedRange.length >= 0, editedRange.location >= 0 else { return }
        let probeRange = NSRange(
            location: max(0, min(editedRange.location, ns.length)),
            length: 0
        )
        let lineRange = ns.paragraphRange(for: probeRange)
        guard lineRange.length > 0 else { return }

        let lineText = ns.substring(with: lineRange)
        let stripped = lineText
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard stripped.isEmpty else { return }

        let probe = lineRange.location
        guard probe < textStorage.length,
              let spec = textStorage.blockSpec(at: probe),
              spec.kind != .paragraph,
              !spec.isListItem else { return }

        textStorage.beginEditing()
        textStorage.addAttributes(plainAttrs, range: lineRange)
        textStorage.endEditing()
        applyTypingAttributes(plainAttrs)
    }

    /// Push our desired typing attributes into the host text view's cache.
    ///
    /// Deferred to the next main-runloop tick because callers can fire from
    /// inside `NSTextStorage.didProcessEditingNotification` (e.g. when the
    /// user deletes the last character). At that moment the storage edit
    /// transaction is still in flight: the storage length has shrunk but
    /// the text view's `selectedRange` has not yet been clamped. AppKit's
    /// `setTypingAttributes:` synchronously calls `updateFontPanel` →
    /// `fallbackFontInfoForSelectedRange:` → `enumerateAttribute:inRange:`,
    /// which then raises `NSRangeException` against the stale selection.
    /// Deferring lets AppKit settle the selection first.
    private func applyTypingAttributes(_ attrs: [NSAttributedString.Key: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            #if canImport(AppKit) && os(macOS)
            if let tv = self.hostTextView as? NSTextView {
                tv.typingAttributes = attrs
            }
            #elseif canImport(UIKit)
            if let tv = self.hostTextView as? UITextView {
                tv.typingAttributes = attrs
            }
            #endif
        }
    }

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    public func setMarkdown(_ markdown: String) {
        let compiled = compileFor(markdown)
        replaceStorage(with: compiled)
    }

    public var text: String {
        get { markdown() }
        set { setMarkdown(newValue) }
    }

    public func markdown() -> String {
        return serializer.serialize(textStorage, dialect: dialect)
    }

    public func recompile() {
        let md = markdown()
        setMarkdown(md)
    }

    var testSelection: NSRange?

    public var currentSelection: NSRange {
        if let testSelection { return testSelection }
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView { return tv.selectedRange() }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView { return tv.selectedRange }
        #endif
        return NSRange(location: 0, length: 0)
    }

    /// Insert plain text at the host text view's cursor (or replace its
    /// selection). Cursor lands after the inserted text.
    @discardableResult
    public func insert(text: String) -> NSRange {
        let selection = currentSelection
        var result = NSRange(location: 0, length: 0)
        withCharacterMutation(range: selection) {
            result = Operations.insertText(in: textStorage, replacing: selection, with: text)
        }
        setHostSelection(result)
        return result
    }

    public func makeStepEnvironment() -> StepEnvironment {
        StepEnvironment(
            compiler: compiler,
            serializer: serializer,
            theme: theme,
            dialect: dialect,
            mode: mode
        )
    }

    /// Apply a transaction. Wraps each step in the controller's undo
    /// machinery so an arbitrary spec mutation is reversible from the
    /// menu/keyboard. Returns the mapped range of the last applied step
    /// (the host text view's selection lands there).
    @discardableResult
    public func apply(_ transaction: Transaction) -> NSRange {
        guard !transaction.steps.isEmpty else { return currentSelection }
        let env = makeStepEnvironment()
        var lastRange = currentSelection
        let preMutationRange = mutationRange(for: transaction)
        withCharacterMutation(range: preMutationRange) {
            applyingMarkdown = true
            let preLength = textStorage.length
            let applied = transaction.apply(to: textStorage, env: env)
            lastRange = applied.mappedRange
            // Validate the union of every range the transaction touched —
            // not just the last step's range. Approximate the post-mutation
            // union as `[preMutationRange.location, preMutationRange.location + length + delta]`
            // which is a superset of every step's mappedRange.
            let delta = textStorage.length - preLength
            let unionLength = max(0, preMutationRange.length + max(0, delta))
            let validationRange = NSRange(
                location: min(preMutationRange.location, max(0, textStorage.length)),
                length: min(unionLength, textStorage.length - min(preMutationRange.location, max(0, textStorage.length)))
            )
            validateAndRepair(in: validationRange)
            applyingMarkdown = false
            resegment()
            intrinsicSizeInvalidator?()
        }
        let cursor = max(lastRange.location, lastRange.location + lastRange.length - 1)
        let cursorRange = NSRange(location: cursor, length: 0)
        setHostSelection(cursorRange)
        refreshTypingAttributes(at: cursor)
        return cursorRange
    }

    /// Validate the spec invariants in `range`, repair drift, and forward
    /// any diagnostics. Called after every transaction so corrupted state
    /// auto-heals before the user sees it.
    func validateAndRepair(in range: NSRange) {
        let diagnostics = SpecValidator.validate(in: textStorage, range: range)
        for diagnostic in diagnostics {
            onDiagnostic?(diagnostic)
        }
        if !diagnostics.isEmpty {
            SpecValidator.repair(in: textStorage, range: range)
        }
    }

    private func mutationRange(for transaction: Transaction) -> NSRange {
        var lo = textStorage.length
        var hi = 0
        for step in transaction.steps {
            switch step {
            case .replaceText(let range, _),
                 .setSpec(let range, _),
                 .toggleInlineMark(let range, _):
                lo = min(lo, range.location)
                hi = max(hi, range.location + range.length)
            }
        }
        guard hi > lo else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lo, length: hi - lo)
    }

    /// Apply an editor action against the host text view's current
    /// selection. The text view owns the selection; this is the path the
    /// `@objc` action methods call from the responder chain.
    @discardableResult
    public func perform(_ action: EditorAction) -> NSRange {
        let range = currentSelection
        defer { refreshTypingAttributes(at: currentSelection.location) }
        let resulting: NSRange
        switch action {
        case .bold:
            resulting = wrappedToggleBold(range: range)
        case .italic:
            resulting = wrappedToggleItalic(range: range)
        case .strikethrough:
            resulting = wrappedToggleStrikethrough(range: range)
        case .codeSpan:
            resulting = wrappedToggleCodeSpan(range: range)
        case .link(let url, let label):
            var out = NSRange(location: range.location, length: 0)
            withCharacterMutation(range: range) {
                out = Operations.insertLink(
                    in: textStorage,
                    replacing: range,
                    label: label ?? "label",
                    url: url ?? "url",
                    theme: theme
                )
            }
            resulting = out
        case .heading(let level):
            resulting = wrappedBlockOp(range: range) {
                Operations.setHeading(
                    in: textStorage, range: range, level: level,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .unorderedList:
            resulting = wrappedBlockOp(range: range) {
                Operations.toggleUnorderedList(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .orderedList:
            resulting = wrappedBlockOp(range: range) {
                Operations.toggleOrderedList(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .taskList:
            resulting = wrappedBlockOp(range: range) {
                Operations.toggleTaskList(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .blockquote:
            resulting = wrappedBlockOp(range: range) {
                Operations.toggleBlockquote(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .codeBlock:
            resulting = wrappedBlockOp(range: range) {
                Operations.insertCodeBlock(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .horizontalRule:
            resulting = wrappedBlockOp(range: range) {
                Operations.insertHorizontalRule(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .indent:
            resulting = wrappedBlockOp(range: range) {
                Operations.indent(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        case .outdent:
            resulting = wrappedBlockOp(range: range) {
                Operations.outdent(
                    in: textStorage, range: range,
                    compiler: compiler, serializer: serializer,
                    dialect: dialect, mode: mode, theme: theme
                )
            }
        }
        setHostSelection(resulting)
        return resulting
    }

    private func wrappedBlockOp(range: NSRange, _ body: () -> NSRange) -> NSRange {
        let safe = clamp(range, in: textStorage.length)
        let lineRange = (textStorage.string as NSString).paragraphRange(for: safe)
        var out = NSRange(location: lineRange.location, length: 0)
        withCharacterMutation(range: lineRange) {
            applyingMarkdown = true
            out = body()
            applyingMarkdown = false
            resegment()
            intrinsicSizeInvalidator?()
        }
        return out
    }

    private func wrappedToggleBold(range: NSRange) -> NSRange {
        if range.length == 0 {
            var out = NSRange(location: range.location, length: 0)
            withCharacterMutation(range: NSRange(location: range.location, length: 0)) {
                out = Operations.toggleBold(in: textStorage, range: range, theme: theme)
            }
            return out
        }
        let safe = clamp(range, in: textStorage.length)
        var out = safe
        withAttributeMutation(range: safe) {
            out = Operations.toggleBold(in: textStorage, range: range, theme: theme)
        }
        return out
    }

    private func wrappedToggleItalic(range: NSRange) -> NSRange {
        if range.length == 0 {
            var out = NSRange(location: range.location, length: 0)
            withCharacterMutation(range: NSRange(location: range.location, length: 0)) {
                out = Operations.toggleItalic(in: textStorage, range: range, theme: theme)
            }
            return out
        }
        let safe = clamp(range, in: textStorage.length)
        var out = safe
        withAttributeMutation(range: safe) {
            out = Operations.toggleItalic(in: textStorage, range: range, theme: theme)
        }
        return out
    }

    private func wrappedToggleStrikethrough(range: NSRange) -> NSRange {
        if range.length == 0 {
            var out = NSRange(location: range.location, length: 0)
            withCharacterMutation(range: NSRange(location: range.location, length: 0)) {
                out = Operations.toggleStrikethrough(in: textStorage, range: range, theme: theme)
            }
            return out
        }
        let safe = clamp(range, in: textStorage.length)
        var out = safe
        withAttributeMutation(range: safe) {
            out = Operations.toggleStrikethrough(in: textStorage, range: range, theme: theme)
        }
        return out
    }

    private func wrappedToggleCodeSpan(range: NSRange) -> NSRange {
        if range.length == 0 {
            var out = NSRange(location: range.location, length: 0)
            withCharacterMutation(range: NSRange(location: range.location, length: 0)) {
                out = Operations.toggleCodeSpan(in: textStorage, range: range, theme: theme)
            }
            return out
        }
        let safe = clamp(range, in: textStorage.length)
        var out = safe
        withAttributeMutation(range: safe) {
            out = Operations.toggleCodeSpan(in: textStorage, range: range, theme: theme)
        }
        return out
    }

    /// Insert a link at the host text view's cursor. If the user has a
    /// non-empty selection, that text becomes the link's display label;
    /// otherwise the supplied `label` (e.g. `"bug 12345"`) is used. The URL
    /// rides on a `.link` attribute and round-trips as `[label](url)`.
    @discardableResult
    public func insertLink(label: String, url: String) -> NSRange {
        let selection = currentSelection
        var actualLabel = label
        if selection.length > 0,
           selection.location + selection.length <= textStorage.length {
            let selected = (textStorage.string as NSString).substring(with: selection)
            if !selected.isEmpty {
                actualLabel = selected
            }
        }
        var result = NSRange(location: selection.location, length: 0)
        withCharacterMutation(range: selection) {
            result = Operations.insertLink(
                in: textStorage,
                replacing: selection,
                label: actualLabel,
                url: url,
                theme: theme
            )
        }
        setHostSelection(result)
        refreshTypingAttributes(at: result.location)
        return result
    }

    // MARK: - undo plumbing

    func withCharacterMutation(range: NSRange, _ body: () -> Void) {
        let preLength = textStorage.length
        let preRange = clamp(range, in: preLength)
        let pre = textStorage.attributedSubstring(from: preRange)
        let preSelection = currentSelection
        body()
        let delta = textStorage.length - preLength
        let postRange = NSRange(location: preRange.location, length: preRange.length + delta)
        undoManager.beginUndoGrouping()
        registerCharacterInverse(at: postRange, with: pre, selection: preSelection)
        undoManager.endUndoGrouping()
    }

    func withAttributeMutation(range: NSRange, _ body: () -> Void) {
        let safe = clamp(range, in: textStorage.length)
        let runs = captureAttributeRuns(in: safe)
        let preSelection = currentSelection
        body()
        undoManager.beginUndoGrouping()
        registerAttributeInverse(at: safe, runs: runs, selection: preSelection)
        undoManager.endUndoGrouping()
    }

    private func registerCharacterInverse(
        at range: NSRange,
        with content: NSAttributedString,
        selection: NSRange
    ) {
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            guard let self else { return }
            let safe = self.clamp(range, in: self.textStorage.length)
            let redoContent = self.textStorage.attributedSubstring(from: safe)
            let redoSelection = self.currentSelection
            self.applyingMarkdown = true
            self.textStorage.beginEditing()
            self.textStorage.replaceCharacters(in: safe, with: content)
            self.textStorage.endEditing()
            self.applyingMarkdown = false
            self.setHostSelection(selection)
            self.refreshTypingAttributes(at: selection.location)
            self.resegment()
            let redoRange = NSRange(location: safe.location, length: content.length)
            self.registerCharacterInverse(at: redoRange, with: redoContent, selection: redoSelection)
        }
    }

    private func registerAttributeInverse(
        at range: NSRange,
        runs: [AttributeRun],
        selection: NSRange
    ) {
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            guard let self else { return }
            let safe = self.clamp(range, in: self.textStorage.length)
            let redoRuns = self.captureAttributeRuns(in: safe)
            let redoSelection = self.currentSelection
            self.applyingMarkdown = true
            self.textStorage.beginEditing()
            for run in runs {
                let runSafe = self.clamp(run.range, in: self.textStorage.length)
                if runSafe.length > 0 {
                    self.textStorage.setAttributes(run.attrs, range: runSafe)
                }
            }
            self.textStorage.endEditing()
            self.applyingMarkdown = false
            self.setHostSelection(selection)
            self.refreshTypingAttributes(at: selection.location)
            self.resegment()
            self.registerAttributeInverse(at: safe, runs: redoRuns, selection: redoSelection)
        }
    }

    private struct AttributeRun {
        let range: NSRange
        let attrs: [NSAttributedString.Key: Any]
    }

    private func captureAttributeRuns(in range: NSRange) -> [AttributeRun] {
        var runs: [AttributeRun] = []
        textStorage.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            runs.append(AttributeRun(range: subRange, attrs: attrs))
        }
        return runs
    }

    private func clamp(_ range: NSRange, in length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        let remaining = max(0, length - location)
        return NSRange(location: location, length: max(0, min(range.length, remaining)))
    }

    /// After programmatic storage edits, NSTextView's `typingAttributes`
    /// can still hold attributes from the prior content (heading font,
    /// bullet marker color, etc.). Re-derive them from the storage at the
    /// cursor — or fall back to plain paragraph defaults when storage is
    /// empty — so the user's next keystroke renders as expected.
    private func refreshTypingAttributes(at location: Int) {
        let total = textStorage.length
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: NSParagraphStyle(),
            .marginaliaBlockSpec: BlockSpecBox(.paragraph)
        ]
        if total > 0 {
            let probe = max(0, min(location, total - 1))
            let raw = textStorage.safeAttributes(at: probe)
            for key: NSAttributedString.Key in [
                .font,
                .foregroundColor,
                .paragraphStyle,
                .marginaliaBlockSpec
            ] {
                if let v = raw[key] { attrs[key] = v }
            }
            // Inline-only flags must NOT bleed into typed text.
            attrs.removeValue(forKey: .marginaliaListMarker)
            attrs.removeValue(forKey: .marginaliaInline)
            attrs.removeValue(forKey: .attachment)
            attrs.removeValue(forKey: .link)
            attrs.removeValue(forKey: .marginaliaLink)
            attrs.removeValue(forKey: .strikethroughStyle)
        }
        applyTypingAttributes(attrs)
    }

    @discardableResult
    public func toggleCheckbox(at location: Int) -> Bool {
        let total = textStorage.length
        guard location >= 0, location < total else { return false }
        guard let existing = textStorage.safeAttribute(.attachment, at: location) as? CheckboxAttachment,
              let spec = textStorage.blockSpec(at: location) else { return false }
        guard case .taskListItem = spec.kind else { return false }
        let newChecked = !existing.isChecked
        let newAttachment = CheckboxAttachment()
        newAttachment.isChecked = newChecked
        let newSpec = BlockSpec(
            kind: .taskListItem(checked: newChecked),
            blockquoteDepth: spec.blockquoteDepth,
            listLevel: spec.listLevel
        )
        let newSpecBox = BlockSpecBox(newSpec)
        let ns = textStorage.string as NSString
        let lineRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
        withAttributeMutation(range: lineRange) {
            textStorage.beginEditing()
            textStorage.addAttribute(.attachment, value: newAttachment, range: NSRange(location: location, length: 1))
            textStorage.addAttribute(.marginaliaBlockSpec, value: newSpecBox, range: lineRange)
            textStorage.endEditing()
        }
        return true
    }

    @discardableResult
    public func handleNewline() -> Bool {
        let cursor = currentSelection.location
        let ns = textStorage.string as NSString
        if textStorage.length > 0 {
            let probe = max(0, min(cursor, ns.length - 1))
            let lineRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))
            let spec = textStorage.blockSpec(at: probe)
            let isListItem = spec?.isListItem ?? false
            let isBlockquote = !isListItem && (spec?.blockquoteDepth ?? 0) > 0
            let orphanEmpty = !isListItem && !isBlockquote && isOrphanedEmptyMarkerLine(lineRange: lineRange)

            if isListItem {
                var resulting: NSRange?
                withCharacterMutation(range: lineRange) {
                    applyingMarkdown = true
                    resulting = InsertNewline.handle(
                        in: textStorage,
                        cursor: cursor,
                        compiler: compiler,
                        serializer: serializer,
                        dialect: dialect,
                        mode: mode,
                        theme: theme
                    )
                    applyingMarkdown = false
                    resegment()
                    intrinsicSizeInvalidator?()
                }
                if let result = resulting {
                    setHostSelection(result)
                    refreshTypingAttributes(at: result.location)
                    return true
                }
            } else if isBlockquote {
                let result = handleBlockquoteNewline(lineRange: lineRange, depth: spec?.blockquoteDepth ?? 1)
                setHostSelection(result)
                refreshTypingAttributes(at: result.location)
                return true
            } else if orphanEmpty {
                let result = demoteOrphanLineToPlain(lineRange: lineRange)
                setHostSelection(result)
                refreshTypingAttributes(at: result.location)
                return true
            }
        }
        if isHeadingAt(location: cursor) {
            return splitHeadingIntoParagraph(at: cursor)
        }
        return false
    }

    private func handleBlockquoteNewline(lineRange: NSRange, depth: Int) -> NSRange {
        let ns = textStorage.string as NSString
        let lineText = lineRange.length > 0 ? ns.substring(with: lineRange) : ""
        let stripped = lineText
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty {
            // Empty blockquote line — exit to plain paragraph at this line.
            let plainAttrs: [NSAttributedString.Key: Any] = [
                .font: theme.bodyFont,
                .foregroundColor: theme.foregroundColor,
                .paragraphStyle: NSParagraphStyle(),
                .marginaliaBlockSpec: BlockSpecBox(.paragraph)
            ]
            let blank = NSAttributedString(string: "\n", attributes: plainAttrs)
            withCharacterMutation(range: lineRange) {
                applyingMarkdown = true
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: lineRange, with: blank)
                textStorage.endEditing()
                applyingMarkdown = false
                resegment()
                intrinsicSizeInvalidator?()
            }
            applyTypingAttributes(plainAttrs)
            return NSRange(location: lineRange.location, length: 0)
        }
        // Continuation: append a fresh empty blockquote line after this one.
        let nextLine = compiler.makeBlockquoteLine(depth: depth, theme: theme)
        let insertLocation = lineRange.location + lineRange.length
        withCharacterMutation(range: NSRange(location: insertLocation, length: 0)) {
            applyingMarkdown = true
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: insertLocation, length: 0), with: nextLine)
            textStorage.endEditing()
            applyingMarkdown = false
            resegment()
            intrinsicSizeInvalidator?()
        }
        let cursor = insertLocation + nextLine.length - 1
        return NSRange(location: max(insertLocation, cursor), length: 0)
    }

    private func isOrphanedEmptyMarkerLine(lineRange: NSRange) -> Bool {
        let total = textStorage.length
        guard total > 0,
              lineRange.location > 0,
              lineRange.location <= total,
              lineRange.location + lineRange.length <= total else {
            return false
        }
        let prev = lineRange.location - 1
        guard prev < total,
              let prevSpec = textStorage.blockSpec(at: prev),
              prevSpec.isListItem else {
            return false
        }
        let ns = textStorage.string as NSString
        let stripped = ns.substring(with: lineRange)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\n", with: "")
        // Require a literal marker character (-, *, +, digit+. , a-z+. , roman+. )
        // to be present. Otherwise a plain paragraph following a list would be
        // misclassified as orphaned and consume Returns.
        let pattern = "^\\s*([-*+]|\\d+[.)]|[a-z]+[.)]|[ivxlcdm]+[.)])\\s*(\\[[ xX]\\]\\s*)?\\s*$"
        return stripped.range(of: pattern, options: .regularExpression) != nil
    }

    private func demoteOrphanLineToPlain(lineRange: NSRange) -> NSRange {
        let plainAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: NSParagraphStyle(),
            .marginaliaBlockSpec: BlockSpecBox(.paragraph)
        ]
        let blank = NSAttributedString(string: "\n", attributes: plainAttrs)
        withCharacterMutation(range: lineRange) {
            applyingMarkdown = true
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: lineRange, with: blank)
            textStorage.endEditing()
            applyingMarkdown = false
            resegment()
            intrinsicSizeInvalidator?()
        }
        applyTypingAttributes(plainAttrs)
        return NSRange(location: lineRange.location, length: 0)
    }

    @discardableResult
    public func handleBackspace() -> Bool {
        let selection = currentSelection
        guard selection.length == 0 else { return false }
        let cursor = selection.location
        let total = textStorage.length
        guard total > 0, cursor > 0, cursor <= total else { return false }
        let ns = textStorage.string as NSString
        let lineRange = ns.paragraphRange(for: NSRange(location: max(0, cursor - 1), length: 0))
        guard lineRange.length > 0,
              lineRange.location + lineRange.length <= total,
              lineRange.location < total else {
            return false
        }
        let probe = max(lineRange.location, min(cursor - 1, total - 1))
        guard probe < total,
              let probeSpec = textStorage.blockSpec(at: probe),
              probeSpec.isListItem else {
            return false
        }
        var markerRange = NSRange(location: lineRange.location, length: 0)
        _ = textStorage.safeAttribute(.marginaliaListMarker, at: lineRange.location, longestEffectiveRange: &markerRange, in: lineRange)
        guard let flag = textStorage.safeAttribute(.marginaliaListMarker, at: lineRange.location) as? Bool, flag else {
            return false
        }
        let bodyStart = markerRange.location + markerRange.length
        guard cursor == bodyStart else { return false }

        let plainAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: NSParagraphStyle(),
            .marginaliaBlockSpec: BlockSpecBox(.paragraph)
        ]
        let bodyRange = NSRange(location: bodyStart, length: lineRange.length - markerRange.length)
        withCharacterMutation(range: lineRange) {
            applyingMarkdown = true
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: markerRange, with: "")
            let demoteRange = NSRange(location: lineRange.location, length: bodyRange.length)
            if demoteRange.length > 0 {
                textStorage.setAttributes(plainAttrs, range: demoteRange)
            }
            textStorage.endEditing()
            applyingMarkdown = false
            resegment()
        }
        setHostSelection(NSRange(location: lineRange.location, length: 0))
        applyTypingAttributes(plainAttrs)
        return true
    }

    private func isHeadingAt(location: Int) -> Bool {
        let total = textStorage.length
        guard total > 0 else { return false }
        let probe = max(0, min(location, total - 1))
        guard let spec = textStorage.blockSpec(at: probe) else { return false }
        if case .heading = spec.kind { return true }
        return false
    }

    private func splitHeadingIntoParagraph(at cursor: Int) -> Bool {
        let ns = textStorage.string as NSString
        let lineRange = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
        let trailingLength = max(0, lineRange.location + lineRange.length - cursor)

        let plainAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: NSParagraphStyle(),
            .marginaliaBlockSpec: BlockSpecBox(.paragraph)
        ]
        let inserted = NSAttributedString(string: "\n", attributes: plainAttrs)

        withCharacterMutation(range: lineRange) {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: cursor, length: 0), with: inserted)
            if trailingLength > 0 {
                let trailingRange = NSRange(location: cursor + 1, length: trailingLength)
                textStorage.addAttributes(plainAttrs, range: trailingRange)
            }
            textStorage.endEditing()
        }
        setHostSelection(NSRange(location: cursor + 1, length: 0))
        return true
    }

    private func setHostSelection(_ range: NSRange) {
        let total = textStorage.length
        let safeLocation = max(0, min(range.location, total))
        let remaining = max(0, total - safeLocation)
        let safe = NSRange(
            location: safeLocation,
            length: max(0, min(range.length, remaining))
        )
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView { tv.setSelectedRange(safe) }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView { tv.selectedRange = safe }
        #endif
    }

    // MARK: - private

    private func compileFor(_ markdown: String) -> NSAttributedString {
        return compiler.compile(markdown, dialect: dialect, mode: mode, theme: theme)
    }

    private func replaceStorage(with attributed: NSAttributedString) {
        applyingMarkdown = true
        let total = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: total, with: attributed)
        textStorage.endEditing()
        applyingMarkdown = false
        resegment()
    }

    private func resegment() {
        var segs: [BlockSegment] = []
        let total = textStorage.length
        guard total > 0 else { self.blocks = []; return }
        textStorage.enumerateBlockSpecs { range, spec in
            segs.append(BlockSegment(
                range: range,
                tag: tagFor(spec: spec),
                level: levelFor(spec: spec),
                blockquoteDepth: spec.blockquoteDepth,
                language: languageFor(spec: spec),
                listLevel: spec.listLevel,
                orderedIndex: orderedIndexFor(spec: spec),
                isChecked: isCheckedFor(spec: spec),
                firstInListItem: false
            ))
        }
        self.blocks = segs
    }

    private func tagFor(spec: BlockSpec) -> BlockTag {
        switch spec.kind {
        case .paragraph: return .paragraph
        case .heading: return .heading
        case .unorderedListItem: return .unorderedListItem
        case .orderedListItem: return .orderedListItem
        case .taskListItem: return .taskListItem
        case .fencedCode: return .fencedCode
        case .indentedCode: return .indentedCode
        case .horizontalRule: return .horizontalRule
        case .htmlBlock: return .htmlBlock
        case .linkReferenceDefinition: return .linkReferenceDefinition
        case .pipeTable: return .pipeTable
        }
    }

    private func levelFor(spec: BlockSpec) -> Int {
        if case .heading(let level) = spec.kind { return level }
        return spec.listLevel
    }

    private func languageFor(spec: BlockSpec) -> String? {
        if case .fencedCode(let language) = spec.kind { return language }
        return nil
    }

    private func orderedIndexFor(spec: BlockSpec) -> Int? {
        if case .orderedListItem(let index) = spec.kind { return index }
        return nil
    }

    private func isCheckedFor(spec: BlockSpec) -> Bool? {
        if case .taskListItem(let checked) = spec.kind { return checked }
        return nil
    }
}
