import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class EditorController {

    public let textStorage: NSTextStorage
    public let contentStorage: NSTextContentStorage
    public let layoutManager: NSTextLayoutManager
    public let textContainer: NSTextContainer

    public var theme: ProseTheme {
        didSet { recompile() }
    }

    public private(set) var blocks: [BlockSegment] = []

    /// Tree view of the current storage. Cached between accesses and
    /// invalidated by the storage observer on every edit, so repeated reads
    /// hand back the same `ProseDocument` instance until the user (or a
    /// step) mutates the storage.
    public var document: ProseDocument {
        if let cached = cachedDocument { return cached }
        let fresh = ProseDocument.from(storage: textStorage, schema: compiler.schema)
        cachedDocument = fresh
        return fresh
    }

    private var cachedDocument: ProseDocument?

    public let undoManager: UndoManager = UndoManager()
    public weak var hostTextView: AnyObject?
    public var intrinsicSizeInvalidator: (() -> Void)?
    public var onDiagnostic: ((SpecDiagnostic) -> Void)?
    /// Fires whenever the host text view's selection moves, with the new
    /// selection range. Hosts wire this to keep an observable selection in
    /// sync without polling. Forwarded by the platform coordinators in
    /// `ProseTextViewMac` / `ProseTextViewIOS`.
    public var onSelectionChanged: ((NSRange) -> Void)?
    /// Fires after each character edit with the freshly-derived
    /// `ProseDocument` and a `Step.replaceText` describing the storage
    /// edit. Wire this to maintain a tree mirror, drive collaborative-
    /// editing transport, or react to document changes in general. Skipped
    /// for attribute-only edits (font traits etc.) since those don't have
    /// a clean `replaceText` mapping; the cache still invalidates.
    public var onDocumentChange: ((ProseDocument, Step) -> Void)?

    public let commands: CommandRegistry
    public let inputRules: InputRuleRunner

    private(set) var compiler: MarkdownAttributedCompiler
    private(set) var serializer: AttributedMarkdownSerializer

    private static let carryForwardAttributeKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .paragraphStyle,
        .proseNodePath, .proseMarks
    ]
    private let layoutDelegate: LayoutManagerDelegate
    private var storageObserver: NSObjectProtocol?
    private var applyingMarkdown = false

    /// Marks queued for the next typed character. ProseMirror's storedMarks:
    /// click bold with no selection, then the next char you type is bold.
    /// Anchored to the cursor location at the time of the toggle so a click
    /// elsewhere drops them; a typed character consumes them.
    private(set) var storedInlineMarks: Set<InlineMark> = []
    private var storedMarksAnchor: Int? = nil

    /// Single-flight flag for the keystroke-path `resegment()` deferral. We
    /// rebuild `blocks` on every typed character; coalescing rapid bursts to
    /// one rebuild per main-runloop tick is a real win on long documents.
    private var resegmentScheduled = false

    /// Union of `editedRange` values seen by the storage observer since the
    /// last `resegment()` ran. Used by `resegment()` to find code-block runs
    /// that were touched and re-stamp syntax highlight colors on their body
    /// text. Cleared after the rehighlight pass.
    private var pendingHighlightRange: NSRange?

    /// Generation counter for `setMarkdown(_:async:)`. Each call bumps this
    /// so that a compile result arriving back from the background queue can
    /// detect that a newer call has superseded it and drop on the floor
    /// (latest-wins). Wraparound is fine — only equality matters.
    private var compileGeneration: UInt64 = 0

    /// Serial queue for off-main markdown compilation. Background compiles
    /// from rapid external binding writes serialize here so the dedicated
    /// `backgroundCompiler` is touched from one thread at a time.
    private let compileQueue = DispatchQueue(
        label: "dev.swiftprose.compile",
        qos: .userInitiated
    )

    /// Separate compiler instance reserved for background work. Sharing the
    /// main-thread `compiler` with off-main calls would race on the
    /// underlying `MarkdownParser` state — `Step` operations regularly call
    /// `compiler.compile` from main during a transaction.
    private let backgroundCompiler: MarkdownAttributedCompiler

    public init(
        initialMarkdown: String = "",
        theme: ProseTheme = .default,
        commands: CommandRegistry = .makeDefault(),
        inputRules: InputRuleRunner = .makeDefault(),
        codeBlockHighlighter: CodeBlockHighlighter? = nil,
        containerSize: CGSize = CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
    ) throws {
        self.theme = theme
        self.commands = commands
        self.inputRules = inputRules
        self.compiler = try MarkdownAttributedCompiler(codeBlockHighlighter: codeBlockHighlighter)
        self.backgroundCompiler = try MarkdownAttributedCompiler(codeBlockHighlighter: codeBlockHighlighter)
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
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Cache invalidation runs even during programmatic loads so that
            // the next `document` read after `setMarkdown` / `replaceStorage`
            // re-derives from the new content.
            if !self.textStorage.editedMask.isEmpty {
                self.cachedDocument = nil
            }
            if self.textStorage.editedMask.contains(.editedCharacters),
               let onDocumentChange = self.onDocumentChange {
                let derived = self.deriveReplaceTextStep()
                onDocumentChange(self.document, derived)
            }
            guard !self.applyingMarkdown else { return }
            if self.textStorage.editedMask.contains(.editedCharacters) {
                let changeInLength = self.textStorage.changeInLength
                self.accumulateHighlightRange(self.textStorage.editedRange)
                self.scrubTypedAttributes()
                self.repairEditedLine()
                self.demoteEmptyStyledLines()
                // Defer `resegment()` to the next runloop tick when a host
                // text view is attached so rapid typing rebuilds `blocks`
                // once instead of per character. Headless callers (tests,
                // programmatic users) keep the synchronous path so reads of
                // `controller.blocks` after a storage edit see fresh data.
                if self.hostTextView != nil {
                    self.scheduleResegment()
                } else {
                    self.resegment()
                }
                self.intrinsicSizeInvalidator?()
                // The typed character already received our storedMarks via
                // typingAttributes; further typing should inherit naturally
                // from the new cursor position, not from the storedMark set.
                self.clearStoredInlineMarks()
                // Input rules: only on a single typed character — paste,
                // cut, multi-char inserts, undo/redo, programmatic edits all
                // skip. Composition (CJK / dictation) skips too.
                //
                // When a host text view is attached, defer to the next
                // runloop tick: running synchronously here re-enters
                // NSTextView/UITextView while it's still completing its
                // post-edit work, which clobbered host selection updates
                // and caused stale-range crashes in the text system
                // ("Range {10,1} out of bounds; string length 9"). With no
                // host (unit tests, headless use), run synchronously —
                // there's no run loop to defer onto.
                if changeInLength == 1, !self.isComposingIME {
                    if self.hostTextView != nil {
                        DispatchQueue.main.async { [weak self] in
                            self?.evaluateInputRules()
                        }
                    } else {
                        self.evaluateInputRules()
                    }
                }
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
        let probe = edited.clamped(to: total)
        let lineRange = ns.paragraphRange(for: probe)
        applyingMarkdown = true
        SpecValidator.repair(in: textStorage, range: lineRange)
        applyingMarkdown = false
    }


    private func scrubTypedAttributes() {
        let editedRange = textStorage.editedRange
        guard editedRange.length > 0 else { return }
        let safe = editedRange.clamped(to: textStorage.length)
        guard safe.length > 0 else { return }
        let ns = textStorage.string as NSString

        // Enumerate runs where each attribute is actually present. AppKit
        // sometimes copies the previous run's .attachment / .proseListMarker
        // onto adjacent typed text — those copies live on non-FFFC chars
        // and need to be cleared. Runs that already lack the attribute
        // contribute no work.
        var attachmentStrays: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: safe) { value, runRange, _ in
            guard value != nil else { return }
            attachmentStrays.append(contentsOf: Self.nonAttachmentSubranges(of: runRange, in: ns))
        }
        var markerStrays: [NSRange] = []
        textStorage.enumerateAttribute(.proseListMarker, in: safe) { value, runRange, _ in
            guard (value as? Bool) == true else { return }
            markerStrays.append(contentsOf: Self.nonAttachmentSubranges(of: runRange, in: ns))
        }
        if attachmentStrays.isEmpty && markerStrays.isEmpty { return }

        applyingMarkdown = true
        textStorage.beginEditing()
        for r in attachmentStrays { textStorage.removeAttribute(.attachment, range: r) }
        for r in markerStrays { textStorage.removeAttribute(.proseListMarker, range: r) }
        textStorage.endEditing()
        applyingMarkdown = false
    }

    /// Subranges of `range` whose characters are NOT the FFFC attachment
    /// glyph. Used by scrubTypedAttributes to spot positions where AppKit
    /// stamped a run-level attribute onto typed text.
    private static func nonAttachmentSubranges(of range: NSRange, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start: Int?
        let end = range.location + range.length
        for i in range.location..<end {
            if ns.character(at: i) == 0xFFFC {
                if let s = start {
                    out.append(NSRange(location: s, length: i - s))
                    start = nil
                }
            } else if start == nil {
                start = i
            }
        }
        if let s = start {
            out.append(NSRange(location: s, length: end - s))
        }
        return out
    }

    /// After a character edit, scan every line the edit touched and reset
    /// the block attribution on any line whose content text is now empty —
    /// "delete clears the formatting." Without this, emptying a heading
    /// (or a blockquote, or an HR, …) leaves that line's spec on the
    /// trailing newline so the next keystroke renders in the prior style.
    ///
    /// Skipped:
    /// - plain paragraphs (depth 0): nothing to demote.
    /// - list items: demote runs through `handleBackspace` at body-start
    ///   so forward-delete / select-and-delete don't pull markers out.
    /// - fenced/indented code and pipe tables: structural multi-line
    ///   blocks. Demoting one body line would split the surrounding
    ///   fence/table apart.
    private func demoteEmptyStyledLines() {
        let plainAttrs = theme.plainParagraphAttributes()
        if textStorage.length == 0 {
            applyTypingAttributes(plainAttrs)
            return
        }
        let editedRange = textStorage.editedRange
        let ns = textStorage.string as NSString
        guard editedRange.length >= 0, editedRange.location >= 0 else { return }
        let scanRange = editedRange.clamped(to: ns.length)
        let unionRange: NSRange = scanRange.length > 0
            ? ns.paragraphRange(for: scanRange)
            : ns.paragraphRange(for: NSRange(location: scanRange.location, length: 0))
        guard unionRange.length > 0 else { return }

        var demoted = false
        var cursor = unionRange.location
        let end = unionRange.location + unionRange.length
        textStorage.beginEditing()
        while cursor < end {
            let lineRange = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            if demoteLineIfEmpty(lineRange: lineRange, plainAttrs: plainAttrs) {
                demoted = true
            }
            let next = lineRange.location + lineRange.length
            cursor = next > cursor ? next : cursor + 1
        }
        textStorage.endEditing()
        if demoted {
            applyTypingAttributes(plainAttrs)
        }
    }

    /// Returns true when the given line's spec was reset to plain paragraph.
    private func demoteLineIfEmpty(
        lineRange: NSRange,
        plainAttrs: [NSAttributedString.Key: Any]
    ) -> Bool {
        guard lineRange.length > 0,
              lineRange.location + lineRange.length <= textStorage.length else {
            return false
        }
        let ns = textStorage.string as NSString
        let lineText = ns.substring(with: lineRange)
        let stripped = lineText
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard stripped.isEmpty else { return false }

        let probe = lineRange.location
        guard probe < textStorage.length,
              let spec = textStorage.blockSpec(at: probe) else { return false }
        if spec.kind == .paragraph, spec.blockquoteDepth == 0 { return false }
        if spec.isListItem { return false }
        if spec.isCodeBlock { return false }

        textStorage.addAttributes(plainAttrs, range: lineRange)
        return true
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

    /// Replace the document with `markdown`. When a host text view is
    /// attached we compile off the main thread on `compileQueue` and apply
    /// the result back on main; the latest-wins generation counter discards
    /// stale results when rapid binding writes pile up. Headless callers
    /// (no host) and explicit `async: false` callers stay synchronous so
    /// existing tests reading `markdown()` immediately after `setMarkdown`
    /// see the new content on return.
    public func setMarkdown(_ markdown: String, async: Bool = true) {
        if async, hostTextView != nil {
            setMarkdownAsync(markdown)
        } else {
            let compiled = compileFor(markdown)
            replaceStorage(with: compiled)
        }
    }

    private func setMarkdownAsync(_ markdown: String) {
        compileGeneration &+= 1
        let myGeneration = compileGeneration
        let theme = self.theme
        compileQueue.async { [weak self] in
            guard let self else { return }
            let compiled = self.backgroundCompiler.compile(
                markdown,
                theme: theme
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Newer setMarkdown call has bumped the generation; this
                // result is stale.
                guard self.compileGeneration == myGeneration else { return }
                self.replaceStorage(with: compiled)
            }
        }
    }

    public var text: String {
        get { markdown() }
        set { setMarkdown(newValue) }
    }

    public func markdown() -> String {
        return serializer.serializeFromTree(textStorage)
    }

    public func loadProseMirrorJSON(_ json: String, schemaMap: SchemaMap = .basic) throws {
        let codec = ProseMirrorCodec(schemaMap: schemaMap, theme: theme)
        let compiled = try codec.decode(json)
        replaceStorage(with: compiled)
    }

    public func loadProseMirrorJSON(_ data: Data, schemaMap: SchemaMap = .basic) throws {
        let codec = ProseMirrorCodec(schemaMap: schemaMap, theme: theme)
        let compiled = try codec.decode(data)
        replaceStorage(with: compiled)
    }

    public func exportProseMirrorJSON(schemaMap: SchemaMap = .basic) throws -> Data {
        let codec = ProseMirrorCodec(schemaMap: schemaMap, theme: theme)
        return try codec.encodeToJSON(textStorage)
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
            theme: theme
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
        // Inline-mark toggles preserve the selection so the user can chain
        // (e.g. bold then italic). Block-level steps emit content ending in
        // "\n" — land the cursor just before that newline so further typing
        // extends the same line instead of starting a new one.
        let resultRange: NSRange
        if case .toggleInlineMark = transaction.steps.last, lastRange.length > 0 {
            resultRange = lastRange
        } else {
            let cursor = max(lastRange.location, lastRange.location + lastRange.length - 1)
            resultRange = NSRange(location: cursor, length: 0)
        }
        setHostSelection(resultRange)
        refreshTypingAttributes(at: resultRange.location)
        return resultRange
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
                 .toggleInlineMark(let range, _),
                 .addMark(let range, _),
                 .removeMark(let range, _):
                lo = min(lo, range.location)
                hi = max(hi, range.location + range.length)
            case .replaceAround(let outer, _, _, _):
                lo = min(lo, outer.location)
                hi = max(hi, outer.location + outer.length)
            case .setNodeAttrs:
                // Identity-addressed; no positional bounds — leave as the
                // current accumulator. The apply path resolves the leaf
                // range from the stored NodePath.
                continue
            }
        }
        guard hi > lo else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lo, length: hi - lo)
    }

    public func canPerform(_ action: EditorAction) -> Bool {
        commands.canExecute(action, storage: textStorage, selection: currentSelection)
    }

    @discardableResult
    public func perform(_ action: EditorAction) -> NSRange {
        defer { refreshTypingAttributes(at: currentSelection.location) }
        if case .link(let url, let label) = action {
            return performLink(url: url, label: label)
        }
        // Parameterized table actions don't fit the registry's
        // stableID-based dispatch (rows/columns/alignment payloads aren't
        // carried by the id). Build a fresh command per call.
        if case .insertTable(let rows, let columns) = action {
            let cmd = InsertTableCommand(rows: rows, columns: columns)
            return runCommand(cmd)
        }
        if case .setTableColumnAlignment(let alignment) = action {
            let cmd = SetTableColumnAlignmentCommand(alignment: alignment)
            return runCommand(cmd)
        }
        if currentSelection.length == 0, let mark = inlineMark(for: action) {
            toggleStoredInlineMark(mark)
            return currentSelection
        }
        guard let command = commands.command(for: action) else {
            return currentSelection
        }
        return runCommand(command)
    }

    private func runCommand(_ command: Command) -> NSRange {
        guard let tx = command.transaction(
            storage: textStorage,
            selection: currentSelection,
            env: makeStepEnvironment()
        ) else {
            return currentSelection
        }
        return apply(tx)
    }

    /// Apply a single-cell edit dispatched from the SwiftUI sheet. Builds a
    /// transaction that swaps the entire table source for the re-rendered
    /// version with the cell text updated. Returns the affected range.
    @discardableResult
    public func applyTableCellEdit(
        tableRange: NSRange,
        row: Int,
        column: Int,
        text: String
    ) -> NSRange {
        guard let tx = makeSetTableCellTextTransaction(
            storage: textStorage,
            tableRange: tableRange,
            row: row,
            column: column,
            text: text,
            env: makeStepEnvironment()
        ) else {
            return currentSelection
        }
        return apply(tx)
    }

    private func inlineMark(for action: EditorAction) -> InlineMark? {
        switch action {
        case .bold: return .bold
        case .italic: return .italic
        case .strikethrough: return .strikethrough
        case .codeSpan: return .codeSpan
        default: return nil
        }
    }

    private func toggleStoredInlineMark(_ mark: InlineMark) {
        let cursor = currentSelection.location
        if storedMarksAnchor != cursor {
            storedInlineMarks.removeAll()
            storedMarksAnchor = cursor
        }
        if storedInlineMarks.contains(mark) {
            storedInlineMarks.remove(mark)
        } else {
            storedInlineMarks.insert(mark)
        }
        if storedInlineMarks.isEmpty {
            storedMarksAnchor = nil
        }
    }

    private func clearStoredInlineMarks() {
        storedInlineMarks.removeAll()
        storedMarksAnchor = nil
    }

    /// Coalesce rapid keystroke-path resegment requests onto the next main-
    /// runloop tick. Multiple keystrokes within a tick share one rebuild.
    /// Internal (not private) so tests can drive it directly without going
    /// through the storage-observer flow, which has its own repair-induced
    /// amplification of resegment counts.
    func scheduleResegment() {
        guard !resegmentScheduled else { return }
        resegmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resegmentScheduled = false
            self.resegment()
        }
    }

    private var isComposingIME: Bool {
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView { return tv.hasMarkedText() }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView { return tv.markedTextRange != nil }
        #endif
        return false
    }

    func evaluateInputRules() {
        let cursor = currentSelection.location
        _ = inputRules.evaluate(
            storage: textStorage,
            cursor: cursor,
            env: makeStepEnvironment(),
            apply: { [weak self] tx in
                _ = self?.apply(tx)
            }
        )
    }

    private func performLink(url: String?, label: String?) -> NSRange {
        let range = currentSelection
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
        setHostSelection(out)
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
        let preRange = range.clamped(to: preLength)
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
        let safe = range.clamped(to: textStorage.length)
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
            let safe = range.clamped(to: self.textStorage.length)
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
            let safe = range.clamped(to: self.textStorage.length)
            let redoRuns = self.captureAttributeRuns(in: safe)
            let redoSelection = self.currentSelection
            self.applyingMarkdown = true
            self.textStorage.beginEditing()
            for run in runs {
                let runSafe = run.range.clamped(to: self.textStorage.length)
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

    /// After programmatic storage edits, NSTextView's `typingAttributes`
    /// can still hold attributes from the prior content (heading font,
    /// bullet marker color, etc.). Re-derive them from the storage at the
    /// cursor — or fall back to plain paragraph defaults when storage is
    /// empty — so the user's next keystroke renders as expected.
    private func refreshTypingAttributes(at location: Int) {
        let total = textStorage.length
        var attrs = theme.plainParagraphAttributes()
        if total > 0 {
            let probe = max(0, min(location, total - 1))
            let raw = textStorage.safeAttributes(at: probe)
            // Carry forward only the paragraph-level attributes. Inline-only
            // flags (.proseListMarker, .proseInline, .attachment, .link,
            // .proseLink, .strikethroughStyle) deliberately do not appear in
            // this whitelist so they cannot bleed into typed text.
            let onLink = raw[.link] != nil || raw[.proseLink] != nil
            for key in EditorController.carryForwardAttributeKeys {
                if onLink && key == .foregroundColor { continue }
                if let v = raw[key] { attrs[key] = v }
            }
        }
        if let anchor = storedMarksAnchor, anchor == location, !storedInlineMarks.isEmpty {
            attrs = applyingStoredMarks(to: attrs)
        } else if !storedInlineMarks.isEmpty {
            clearStoredInlineMarks()
        }
        applyTypingAttributes(attrs)
    }

    private func applyingStoredMarks(
        to base: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var attrs = base
        let baseFont = (attrs[.font] as? PlatformFont) ?? theme.bodyFont
        var font = baseFont
        if storedInlineMarks.contains(.codeSpan) {
            font = theme.monospaceFont
            attrs[.proseInline] = InlineTag.codeSpan
        }
        if storedInlineMarks.contains(.bold) {
            font = font.togglingProseTrait(.bold, enable: true)
        }
        if storedInlineMarks.contains(.italic) {
            font = font.togglingProseTrait(.italic, enable: true)
        }
        attrs[.font] = font
        if storedInlineMarks.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
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
        let ns = textStorage.string as NSString
        let lineRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
        withAttributeMutation(range: lineRange) {
            textStorage.beginEditing()
            textStorage.addAttribute(.attachment, value: newAttachment, range: NSRange(location: location, length: 1))
            textStorage.setBlockSpec(newSpec, in: lineRange)
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

            if !isListItem, !isBlockquote, !orphanEmpty,
               openFencedCodeFromLanguageLine(cursor: cursor, lineRange: lineRange, spec: spec) {
                return true
            }

            if isListItem {
                var resulting: NSRange?
                withCharacterMutation(range: lineRange) {
                    applyingMarkdown = true
                    resulting = InsertNewline.handle(
                        in: textStorage,
                        cursor: cursor,
                        compiler: compiler,
                        serializer: serializer,
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

    /// If the current paragraph is exactly ` ```<language> ` (e.g.
    /// ` ```swift `) and the user pressed Enter at end of that line, splice
    /// in a fresh fenced code block carrying that language and place the
    /// cursor on the body line. Complements the bare-`` ``` `` input rule
    /// (which can't capture a language because it fires on the third
    /// backtick before the user has typed any tag). Returns true when it
    /// handled the keystroke.
    private func openFencedCodeFromLanguageLine(
        cursor: Int,
        lineRange: NSRange,
        spec: BlockSpec?
    ) -> Bool {
        // Only convert paragraph-shaped lines. Headings, lists, quotes,
        // existing code blocks, etc. shouldn't transmute.
        guard let kind = spec?.kind, case .paragraph = kind else { return false }
        guard cursor == lineRange.location + lineRange.length ||
              cursor == lineRange.location + lineRange.length - 1 else { return false }
        let ns = textStorage.string as NSString
        let lineText = ns.substring(with: lineRange)
            .replacingOccurrences(of: "\n", with: "")
        let pattern = "^```([\\w+#.-]+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: lineText,
                  range: NSRange(location: 0, length: (lineText as NSString).length)
              ),
              match.numberOfRanges >= 2 else {
            return false
        }
        let langRange = match.range(at: 1)
        let language = (lineText as NSString).substring(with: langRange)

        let block = compiler.compile("```\(language)\n\n```\n", theme: theme)
        // Body line begins after "```<language>\n" — three backticks plus
        // the language UTF-16 length plus one newline.
        let bodyOffset = 4 + (language as NSString).length
        let transaction = Transaction(steps: [
            .replaceText(range: lineRange, with: block),
            .replaceText(
                range: NSRange(location: lineRange.location + bodyOffset, length: 0),
                with: NSAttributedString()
            )
        ], label: "Code block")
        _ = apply(transaction)
        return true
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
            let plainAttrs = theme.plainParagraphAttributes()
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
        let plainAttrs = theme.plainParagraphAttributes()
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
        _ = textStorage.safeAttribute(.proseListMarker, at: lineRange.location, longestEffectiveRange: &markerRange, in: lineRange)
        guard let flag = textStorage.safeAttribute(.proseListMarker, at: lineRange.location) as? Bool, flag else {
            return false
        }
        let bodyStart = markerRange.location + markerRange.length
        guard cursor == bodyStart else { return false }

        let plainAttrs = theme.plainParagraphAttributes()
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

        let plainAttrs = theme.plainParagraphAttributes()
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
        let safe = range.clamped(to: textStorage.length)
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView { tv.setSelectedRange(safe) }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView { tv.selectedRange = safe }
        #endif
    }

    /// Set the host text view's selection to `range`. Use this to restore a
    /// selection captured before a focus-stealing UI (sheet, popover, picker)
    /// took over, so a subsequent `insertLink` / `insert(text:)` lands at the
    /// intended position rather than wherever the resigned-first-responder
    /// text view ended up reporting.
    public func setSelection(_ range: NSRange) {
        setHostSelection(range)
    }

    /// Build a `Step.replaceText` describing the most recent storage edit,
    /// using `editedRange` and `changeInLength` from the in-flight notification.
    /// The pre-edit range is reconstructed by subtracting `changeInLength`;
    /// the post-edit content is read from current storage. The returned step
    /// is forward-only — callers that want an inverse must capture pre-edit
    /// content separately.
    private func deriveReplaceTextStep() -> Step {
        let editedRange = textStorage.editedRange
        let changeInLength = textStorage.changeInLength
        let preLength = max(0, editedRange.length - changeInLength)
        let preRange = NSRange(location: editedRange.location, length: preLength)
        let safeEdited = editedRange.clamped(to: textStorage.length)
        let content = textStorage.attributedSubstring(from: safeEdited)
        return .replaceText(range: preRange, with: content)
    }

    // MARK: - private

    private func compileFor(_ markdown: String) -> NSAttributedString {
        return compiler.compile(markdown, theme: theme)
    }

    /// No-op kept for ABI stability. Pipe-table row-height stamping was
    /// retired alongside the rendered table chrome; tables now render as
    /// plain monospace paragraphs.
    public func scheduleTableHeightStamp(containerWidth: CGFloat) {}

    private func replaceStorage(with attributed: NSAttributedString) {
        // Storage mutations and the host text view both require main-thread
        // access — but headless callers (unit tests, programmatic users
        // without a host attached) may legitimately drive the controller
        // from any thread. Only enforce the main-thread invariant when a
        // host is attached; the async setMarkdown path explicitly marshals
        // back to main before reaching here.
        if hostTextView != nil {
            precondition(Thread.isMainThread,
                         "replaceStorage must be called on the main thread when a host text view is attached")
        }
        applyingMarkdown = true
        let total = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: total, with: attributed)
        textStorage.endEditing()
        applyingMarkdown = false
        resegment()
    }

    /// Test-only invocation counter; bumped at the start of every
    /// resegmentation pass so tests can verify coalescing behavior without
    /// stubbing out the work itself.
    var resegmentRunCount: Int = 0

    private func resegment() {
        resegmentRunCount += 1
        var segs: [BlockSegment] = []
        let total = textStorage.length
        if total == 0 {
            self.blocks = []
            self.pendingHighlightRange = nil
            return
        }
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

        if let pending = pendingHighlightRange {
            rehighlightCodeBlocks(intersecting: pending)
            pendingHighlightRange = nil
        }
    }

    /// Union the freshly-edited range into `pendingHighlightRange` so that
    /// the next deferred `resegment()` knows which code blocks to re-color.
    /// Clamped to current storage length on read.
    private func accumulateHighlightRange(_ range: NSRange) {
        guard range.location != NSNotFound else { return }
        if let existing = pendingHighlightRange {
            let lo = min(existing.location, range.location)
            let hi = max(existing.location + existing.length, range.location + range.length)
            pendingHighlightRange = NSRange(location: lo, length: hi - lo)
        } else {
            pendingHighlightRange = range
        }
    }

    /// Walk `blocks` for fenced/indented code runs overlapping `range` and
    /// ask the compiler to re-stamp syntax-highlight colors on their
    /// bodies. Adjacent same-tag segments are merged into one logical block
    /// — `NodePathBox` uses reference equality so each compiler-emitted
    /// line is its own attribute run, and the highlighter needs the full
    /// fence-body-fence span to peel the fences from the body. Recompile-
    /// free path — the parser doesn't run, so the spec attribution is
    /// trusted from the previous compile and only the colors refresh.
    private func rehighlightCodeBlocks(intersecting range: NSRange) {
        let total = textStorage.length
        let safe = range.clamped(to: total)
        let safeEnd = safe.location + safe.length

        var i = 0
        while i < blocks.count {
            let tag = blocks[i].tag
            guard tag == .fencedCode || tag == .indentedCode else {
                i += 1
                continue
            }
            // Greedy-extend through adjacent same-tag segments to recover
            // the full code block.
            var j = i
            while j + 1 < blocks.count,
                  blocks[j + 1].tag == tag,
                  blocks[j].range.location + blocks[j].range.length == blocks[j + 1].range.location {
                j += 1
            }
            let runStart = blocks[i].range.location
            let runEnd = blocks[j].range.location + blocks[j].range.length
            // Intersect with `safe`.
            if runStart < safeEnd, safe.location < runEnd {
                let language = blocks[i].language ?? blocks[j].language
                applyingMarkdown = true
                compiler.rehighlightCodeBlock(
                    in: textStorage,
                    blockRange: NSRange(location: runStart, length: runEnd - runStart),
                    language: language,
                    isFenced: tag == .fencedCode,
                    theme: theme
                )
                applyingMarkdown = false
            }
            i = j + 1
        }
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

    // MARK: - Pipe-table presentation state (retired no-ops)

    /// No-op kept for ABI stability. Tables no longer have an "expanded"
    /// raw-mode toggle since the rendered chrome was retired.
    public func isTableExpanded(tableRange: NSRange) -> Bool { false }

    /// No-op kept for ABI stability.
    public func toggleTableExpansion(tableRange: NSRange) {}

    /// No-op kept for ABI stability.
    public func compactExpandedTableRanges() {}
}

