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
    /// Same object as `textStorage`, typed. Carries the capture hook and
    /// the `EditOrigin` stack.
    let proseStorage: ProseTextStorage
    public let contentStorage: NSTextContentStorage
    public let layoutManager: NSTextLayoutManager
    public let textContainer: NSTextContainer

    public var theme: ProseTheme {
        didSet {
            recompile()
            refreshTypingAttributes(at: currentSelection.location)
        }
    }

    /// Line-level segmentation of the current storage, derived on demand.
    ///
    /// O(document). Nothing in the editor reads this — it exists for hosts
    /// that want a flat outline. It used to be a cached array rebuilt on
    /// every keystroke, which was the single largest per-character cost in
    /// the editor.
    public var blocks: [BlockSegment] {
        drainPendingEnvelopes()
        var segs: [BlockSegment] = []
        proseStorage.contents.enumerateBlockSpecs { range, spec in
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
        return segs
    }

    /// Tree view of the current storage. Cached between accesses and
    /// invalidated by the storage observer on every edit, so repeated reads
    /// hand back the same `ProseDocument` instance until the user (or a
    /// step) mutates the storage.
    public var document: ProseDocument {
        drainPendingEnvelopes()
        if let cached = cachedDocument { return cached }
        if let spliced = projection.spliced(
            storage: proseStorage.contents,
            schema: compiler.schema
        ) {
            splicedProjectionRunCount += 1
            cachedDocument = spliced
            projection.adopt(spliced)
            return spliced
        }
        projectionRunCount += 1
        let fresh = ProseDocument.from(storage: proseStorage.contents, schema: compiler.schema)
        cachedDocument = fresh
        projection.adopt(fresh)
        return fresh
    }

    private var cachedDocument: ProseDocument?
    private var projection = IncrementalProjection()

    /// Test-only counter; bumped when `document` was rebuilt by splicing
    /// rather than re-projecting the whole storage.
    var splicedProjectionRunCount: Int = 0

    /// Test-only invocation counter; bumped whenever `document` misses the
    /// cache and re-projects the storage. Lets tests assert that a
    /// keystroke costs zero projections when nobody reads the tree.
    var projectionRunCount: Int = 0

    /// Test seam: drop the projected-tree cache without mutating storage.
    func invalidateDocumentCacheForBenchmark() {
        cachedDocument = nil
        projection.reset()
    }

    /// The controller does its own grouping — one `HistoryRecord` per
    /// group — so `groupsByEvent` is off. Left on, `UndoManager` wraps
    /// everything an event produces in one outer group, and the typed
    /// character plus the input rule it triggered would collapse into a
    /// single undo instead of two.
    public let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    /// Set by the platform `UIViewRepresentable` / `NSViewRepresentable`
    /// when the host text view is created. Hosts that need to configure the
    /// underlying view (e.g. attach an iOS `inputAccessoryView`) observe
    /// `onHostTextViewChange` rather than polling this property.
    public weak var hostTextView: AnyObject? {
        didSet {
            guard hostTextView !== oldValue else { return }
            onHostTextViewChange?(hostTextView)
            if hostTextView != nil {
                refreshTypingAttributes(at: currentSelection.location)
            }
        }
    }
    /// Fires when `hostTextView` is set or cleared. Receives the new value
    /// (a `UITextView` on iOS or `NSTextView` on macOS, or `nil` when the
    /// view tears down). Use this in lieu of polling to react to platform
    /// view availability.
    public var onHostTextViewChange: ((AnyObject?) -> Void)?
    public var intrinsicSizeInvalidator: (() -> Void)?
    public var onDiagnostic: ((SpecDiagnostic) -> Void)?
    /// Fires for each `SchemaDiagnostic` produced after a transaction —
    /// typed-tree-level violations (unknown node/mark types, content-rule
    /// mismatches, marks on disallowed parents). Distinct from
    /// `onDiagnostic` so hosts can route them to a separate sink (e.g.
    /// surface schema drift as warnings rather than user-facing errors).
    public var onSchemaDiagnostic: ((SchemaDiagnostic) -> Void)?

    // Multi-subscriber observer lists. Single-callback properties above
    // remain for the common case; `addOn…` registers additional
    // subscribers and returns a token usable with `removeObserver`.
    private var documentChangeObservers: [(UUID, (DocumentChange) -> Void)] = []
    private var diagnosticObservers: [(UUID, (SpecDiagnostic) -> Void)] = []
    private var selectionChangedObservers: [(UUID, (NSRange) -> Void)] = []

    public struct ObserverToken: Hashable, Sendable {
        let id: UUID
    }

    @discardableResult
    public func addOnDocumentChange(_ handler: @escaping (DocumentChange) -> Void) -> ObserverToken {
        let id = UUID()
        documentChangeObservers.append((id, handler))
        return ObserverToken(id: id)
    }

    @discardableResult
    public func addOnDiagnostic(_ handler: @escaping (SpecDiagnostic) -> Void) -> ObserverToken {
        let id = UUID()
        diagnosticObservers.append((id, handler))
        return ObserverToken(id: id)
    }

    @discardableResult
    public func addOnSelectionChanged(_ handler: @escaping (NSRange) -> Void) -> ObserverToken {
        let id = UUID()
        selectionChangedObservers.append((id, handler))
        return ObserverToken(id: id)
    }

    public func removeObserver(_ token: ObserverToken) {
        documentChangeObservers.removeAll { $0.0 == token.id }
        diagnosticObservers.removeAll { $0.0 == token.id }
        selectionChangedObservers.removeAll { $0.0 == token.id }
    }

    func fanoutDocumentChange(_ change: DocumentChange) {
        onDocumentChange?(change)
        for (_, handler) in documentChangeObservers { handler(change) }
    }

    func fanoutDiagnostic(_ diagnostic: SpecDiagnostic) {
        onDiagnostic?(diagnostic)
        for (_, handler) in diagnosticObservers { handler(diagnostic) }
    }

    func fanoutSelectionChanged(_ range: NSRange) {
        onSelectionChanged?(range)
        for (_, handler) in selectionChangedObservers { handler(range) }
    }
    /// Fires whenever the host text view's selection moves, with the new
    /// selection range. Hosts wire this to keep an observable selection in
    /// sync without polling. Forwarded by the platform coordinators in
    /// `ProseTextViewMac` / `ProseTextViewIOS`.
    public var onSelectionChanged: ((NSRange) -> Void)?
    /// Fires once per edit group with a `DocumentChange` carrying a
    /// `Step.replaceText` describing the storage edit and a lazily-projected
    /// `document`. Wire this to maintain a tree mirror, drive collaborative-
    /// editing transport, or react to document changes in general.
    ///
    /// One publish per group, not per storage write: an N-step transaction
    /// fires once, and the normalization the controller runs on its own
    /// edits (attribute scrubbing, the trailing paragraph, code-block
    /// rehighlighting) does not fire separately. Attribute-only edits are
    /// skipped since they have no clean `replaceText` mapping; the cache
    /// still invalidates.
    public var onDocumentChange: ((DocumentChange) -> Void)?

    public let commands: CommandRegistry
    public let inputRules: InputRuleRunner
    /// Key spec → EditorAction bindings. Platform text views consult
    /// `keymap.action(forKey:)` before falling back to default behavior.
    public var keymap: Keymap = .mac
    /// When `false`, `perform(_:)` / `canPerform(_:)` / `toggleCheckbox(_:)`
    /// short-circuit so toolbar buttons, keymap dispatch, and checkbox
    /// taps can't mutate the document. The platform text view's own
    /// `isEditable` gates typing. Programmatic mutations (`apply(_:)`,
    /// `setMarkdown(_:)`, `insert(text:)`, …) stay available so hosts can
    /// still drive content. Kept in sync by the SwiftUI surface from
    /// `Configuration.isEditable`; direct callers set it themselves.
    public var isEditable: Bool = true {
        didSet {
            guard oldValue != isEditable else { return }
            TableAttachmentViewProvider.sharedIsEditable = isEditable
            propagateIsEditableToTables()
        }
    }
    /// Escape hatch for `toggleCheckbox(at:)` while `isEditable == false`.
    /// Lets read-only documents keep interactive task-list checkboxes.
    /// No effect when `isEditable == true`.
    public var allowsCheckboxToggle: Bool = false
    /// Last input rule that fired and the line range it touched. Backspace
    /// consults this; if the cursor hasn't moved since the rule fired,
    /// Backspace undoes the rule rather than deleting a character.
    public private(set) var lastInputRule: (id: String, lineRange: NSRange)?

    /// Record that an input rule fired. Called by InputRuleRunner.
    public func didFireInputRule(id: String, lineRange: NSRange) {
        lastInputRule = (id, lineRange)
    }

    /// Try to undo the most-recently-fired input rule. Returns true when
    /// an undo was performed. Bound as the head of the Backspace chain
    /// so a stray autoprompt rule doesn't confuse the user.
    @discardableResult
    public func undoInputRule() -> Bool {
        guard lastInputRule != nil else { return false }
        guard undoManager.canUndo else {
            lastInputRule = nil
            return false
        }
        undoManager.undo()
        lastInputRule = nil
        return true
    }
    /// Registered plugins — order matters: filterTransaction / appendTransaction
    /// run in registration order.
    public private(set) var plugins: [EditorPlugin] = []
    private var pluginStates: [AnyPluginKey: Any] = [:]
    private var runningAppendTransactions = false
    /// Undo / redo configuration. Setting applies depth to the
    /// undoManager; newGroupDelay is consulted by `closeHistoryGroup`.
    public var historyConfig: HistoryConfig = .default {
        didSet {
            if let depth = historyConfig.depth {
                undoManager.levelsOfUndo = depth
            }
        }
    }

    /// Force the next transaction into a fresh undo group. Mirrors PM's
    /// `closeHistory(tr)`.
    public func closeHistoryGroup() {
        drainPendingEnvelopes()
        closeTypingRecord()
        if undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
    }

    /// Whether anything is undoable. UI bind-target.
    public var undoDepth: Int {
        undoManager.canUndo ? 1 : 0
    }

    /// Whether anything is redoable.
    public var redoDepth: Int {
        undoManager.canRedo ? 1 : 0
    }

    /// Whether `transaction` would be recorded as a history step. False
    /// for transactions tagged `meta["addToHistory"] == false`.
    public func isHistoryTransaction(_ transaction: Transaction) -> Bool {
        (transaction.getMeta("addToHistory") as? Bool) != false
    }
    /// Registry of `NodeViewProvider`s keyed by node-type name. Hosts
    /// register providers at startup to take over the rendering of an
    /// `isolating`-flagged node type (today: `table`). Empty by default —
    /// no provider means the legacy flat-storage rendering applies.
    public let nodeViewRegistry: NodeViewRegistry = NodeViewRegistry()

    private(set) var compiler: MarkdownAttributedCompiler
    private(set) var serializer: AttributedMarkdownSerializer

    private static let carryForwardAttributeKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .paragraphStyle,
        .proseNodePath, .proseMarks
    ]
    private let layoutDelegate: LayoutManagerDelegate

    /// Marks queued for the next typed character. ProseMirror's storedMarks:
    /// click bold with no selection, then the next char you type is bold.
    /// Anchored to the cursor location at the time of the toggle so a click
    /// elsewhere drops them; a typed character consumes them.
    private(set) var storedInlineMarks: Set<InlineMark> = []
    private(set) var storedMarksAnchor: Int? = nil

    /// Single-flight flag for the deferred code-block rehighlight.
    private var rehighlightScheduled = false

    /// Union of `editedRange` values seen since the last rehighlight ran.
    /// Used to find the code blocks that were touched and re-stamp syntax
    /// highlight colors on their body text. Cleared after the pass.
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
        // Register the table view provider class once — TextKit 2 looks
        // up view providers by attachment file type, so the registration
        // must happen before the first compile produces an attachment.
        TableAttachmentViewProvider.registerOnce()
        TableAttachmentViewProvider.sharedTheme = theme

        let storage = ProseTextStorage()
        self.proseStorage = storage
        self.textStorage = storage
        self.contentStorage = NSTextContentStorage()
        self.contentStorage.textStorage = textStorage
        self.layoutManager = NSTextLayoutManager()
        self.contentStorage.addTextLayoutManager(layoutManager)
        self.textContainer = NSTextContainer(size: containerSize)
        self.layoutManager.textContainer = textContainer

        self.layoutDelegate = LayoutManagerDelegate()
        layoutManager.delegate = layoutDelegate
        layoutDelegate.controller = self

        proseStorage.withOrigin(.load) {
            let initial = compileFor(initialMarkdown)
            textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: initial)
        }
        ensureTrailingParagraph()
        scheduleCodeBlockRehighlight()

        // Wire the table view provider's dispatch back into this
        // controller now that `self` is fully initialized.
        TableAttachmentViewProvider.sharedDispatch = { [weak self] tx in
            _ = self?.apply(tx)
        }
        // When a cell edit / structural mutation changes the table's
        // measured size, the view provider asks us to invalidate the
        // attachment's storage range so TextKit 2 re-queries
        // `attachmentBounds`. Without this, line fragments host the
        // table at its stale height and clip the taller rows.
        TableAttachmentViewProvider.sharedInvalidateAttachment = { [weak self] att in
            self?.invalidateTableAttachmentLayout(att)
        }

        proseStorage.captureContextProvider = { [weak self] in
            guard let self else {
                return CaptureContext(
                    selectionBefore: NSRange(location: 0, length: 0),
                    markedTextActive: false,
                    hint: nil,
                    timestamp: 0
                )
            }
            let hint = self.nextEditHint
            self.nextEditHint = nil
            return CaptureContext(
                selectionBefore: self.currentSelection,
                markedTextActive: self.isComposingIME,
                hint: hint,
                timestamp: self.historyClock()
            )
        }
        proseStorage.editObserver = { [weak self] record in
            self?.storageDidProcessEditing(record)
        }
    }

    // MARK: - envelopes

    /// One platform edit group, held from `processEditing` until the drain
    /// closes it. Deferring lets the text view finish its own post-edit
    /// work (selection, typing attributes) before we normalize, validate,
    /// and publish.
    struct PendingEnvelope {
        var record: EditRecord
    }

    private(set) var pendingEnvelopes: [PendingEnvelope] = []
    private var drainScheduled = false
    private var isDraining = false

    /// Hint stamped by the platform delegate for the edit it is about to
    /// allow. Consumed by `captureContextProvider` at the first capture.
    var nextEditHint: EditHint?

    /// Monotonic clock for edit timestamps. A test seam so undo-grouping
    /// tests can drive `newGroupDelay` without sleeping.
    var historyClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Companion seam: tests install this to move `historyClock` forward.
    var testClockAdvance: ((TimeInterval) -> Void)?

    /// A table step changes the document without touching storage, so no
    /// `EditRecord` is produced and none of the storage-driven invalidation
    /// runs. Do it by hand: the attachment's own range is a valid dirty
    /// range, and re-projecting that block re-lifts the live subtree.
    private func invalidateForOutOfBandSubtree(_ applied: AppliedTransaction?) {
        guard let applied, applied.touchesOutOfBandSubtree else { return }
        cachedDocument = nil
        projection.record(editedRange: applied.mappedRange, changeInLength: 0)
    }

    private func storageDidProcessEditing(_ record: EditRecord) {
        // Cache invalidation runs for every origin so the next `document`
        // read after `setMarkdown` / `replaceStorage` re-derives.
        if !record.editedMask.isEmpty {
            cachedDocument = nil
            if record.origin == .load {
                // A load replaces the document; there is nothing to reuse.
                projection.reset()
            } else {
                // Attribute-only edits count too: re-stamping a node path
                // restructures the tree without moving a character. They
                // dirty the range they touched, which is all the splice
                // needs.
                projection.record(
                    editedRange: record.editedRange,
                    changeInLength: record.isCharacterEdit ? record.changeInLength : 0
                )
            }
            layoutDelegate.decorationProvider.invalidate(
                editedRange: record.editedRange,
                changeInLength: record.changeInLength
            )
        }
        // A transaction or history replay that only touched attributes — a
        // mark toggle — still changed the document; platform and
        // normalization attribute writes are not content.
        let publishesAttributeOnly = record.origin == .transaction || record.origin == .history
        guard record.isCharacterEdit || publishesAttributeOnly else { return }

        switch record.origin {
        case .normalize:
            // A side effect of an edit that is publishing on its own
            // behalf. Its inverse joins that edit's undo unit when one is
            // being assembled.
            if collectingInverses != nil, !record.captures.isEmpty {
                collectingInverses?.insert(contentsOf: inverseSteps(from: record), at: 0)
            }
            return
        case .transaction, .history, .load:
            if record.isCharacterEdit { accumulateHighlightRange(record.editedRange) }
            fanoutDocumentChange(DocumentChange(step: derivedStep(from: record), controller: self, origin: record.origin))
        case .platform:
            pendingEnvelopes.append(PendingEnvelope(record: record))
            if hostTextView == nil {
                drainPendingEnvelopes()
            } else {
                scheduleDrain()
            }
        }
    }

    /// Coalesce envelope closes onto the next main-runloop tick when a host
    /// text view is attached. Headless controllers close synchronously so a
    /// read right after a storage write sees settled state.
    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.drainPendingEnvelopes()
        }
    }

    /// Close every queued platform envelope, in order. Idempotent and
    /// re-entrancy guarded — closing an envelope runs input rules and
    /// append transactions, which call back into `apply`, which drains.
    func drainPendingEnvelopes() {
        guard !isDraining else { return }
        guard !pendingEnvelopes.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }
        while !pendingEnvelopes.isEmpty {
            let envelope = pendingEnvelopes.removeFirst()
            closeEnvelope(envelope)
        }
    }

    private func closeEnvelope(_ envelope: PendingEnvelope) {
        let record = envelope.record
        let userEditedRange = record.editedRange
        let editClass = classify(record)
        classificationProbe?(editClass)

        accumulateHighlightRange(userEditedRange)

        // Everything the close does to fix up this edit joins its undo
        // unit: undoing the keystroke also undoes the demotion, the
        // trailing paragraph, and the attribute repair it triggered.
        let outerCollecting = collectingInverses
        collectingInverses = []
        defer { collectingInverses = outerCollecting }

        switch editClass {
        case .compositionInterim, .dictationInterim:
            // Not content yet. Keep the cache and highlight bookkeeping the
            // caller already did, and stop — no normalization, no publish,
            // no input rules, no undo entry.
            scheduleCodeBlockRehighlight()
            return
        case .attributeOnly:
            scheduleCodeBlockRehighlight()
            return
        default:
            break
        }

        let step: Step
        if editClass == .compositionCommit, let baseline = compositionBaseline {
            compositionBaseline = nil
            pendingCompositionPreImage = baseline.preImage
            let end = max(baseline.range.location, userEditedRange.location + userEditedRange.length)
            let span = NSRange(
                location: baseline.range.location,
                length: min(end - baseline.range.location, max(0, textStorage.length - baseline.range.location))
            )
            let post = textStorage.attributedSubstring(from: span.clamped(to: textStorage.length))
            // Esc mid-composition puts the pre-image back; nothing happened.
            if post.isEqual(to: baseline.preImage) {
                scheduleCodeBlockRehighlight()
                return
            }
            committedCompositionLength = post.length
            step = .replaceText(range: baseline.range, with: post)
        } else {
            step = derivedStep(from: record)
        }

        normalizeAfterEdit(in: userEditedRange, accumulateHighlight: false)
        // The typed character already received our storedMarks via
        // typingAttributes; further typing should inherit naturally from
        // the new cursor position, not from the storedMark set.
        clearStoredInlineMarks()

        registerEnvelope(record, class: editClass, step: step)

        fanoutDocumentChange(DocumentChange(step: step, controller: self))

        // Input rules fire only for a typed character. Paste, deletion,
        // autocorrect, composition, and undo/redo all skip: a rule that
        // rewrites what autocorrect just produced is the classic
        // double-transform bug.
        var inputRuleFired = false
        if editClass == .typing {
            inputRuleFired = evaluateInputRules()
        } else {
            lastInputRule = nil
            inputRules.clearLastFiredRule()
        }
        if !inputRuleFired {
            runAppendTransactions(after: [Transaction(steps: [step])])
        }
    }

    /// What a platform edit group turned out to be, decided at drain with
    /// the delegate's hint as a starting point and storage as the truth.
    enum EditClass: Equatable {
        /// Undo or redo replay.
        case history
        /// Interim IME composition — marked text, not content yet.
        case compositionInterim
        /// Marked text resolved. The whole composition collapses to one
        /// edit against the state before it started.
        case compositionCommit
        /// iOS dictation placeholder text. Dropped; the final phrase
        /// arrives through `insertDictationResult` as a paste.
        case dictationInterim
        /// One character at the caret.
        case typing
        /// Backspace / forward-delete / delete selection.
        case deletion
        /// Autocorrect, text replacement, Edit > Find > Replace, smart
        /// substitution — the affected range is not the selection.
        case correction
        /// Paste, drag-move, multi-character insert, Replace All.
        case bulk
        /// Font panel, Format menu — no character change.
        case attributeOnly
    }

    /// State captured when a composition started, so the commit can be
    /// expressed as one edit against the pre-composition document.
    struct CompositionBaseline {
        let range: NSRange
        let preImage: NSAttributedString
        let selectionBefore: NSRange
        let timestamp: TimeInterval
    }

    private(set) var compositionBaseline: CompositionBaseline?

    /// DEBUG-only: turn the post-edit spec assertion off. Tests that
    /// deliberately corrupt storage set this.
    var assertsOnDiagnostics = true

    /// Test seam: fires with the class every closed platform envelope was
    /// assigned.
    var classificationProbe: ((EditClass) -> Void)?

    /// Backing store for the `@_spi(Harness)` string-typed probe, so its
    /// getter hands back what was set rather than the wrapped closure.
    var harnessProbeBox: ((String) -> Void)?

    /// Carried from building a composition-commit step to registering its
    /// inverse a few lines later.
    private var pendingCompositionPreImage: NSAttributedString?
    private var committedCompositionLength = 0

    /// Decide what `record` was. First match wins.
    func classify(_ record: EditRecord) -> EditClass {
        if undoManager.isUndoing || undoManager.isRedoing { return .history }
        if dictationPlaceholderActive { return .dictationInterim }

        let composingNow = isComposingIME
        let context = record.context
        if composingNow {
            if context?.markedTextActive == false || compositionBaseline == nil {
                let first = record.captures.first
                compositionBaseline = CompositionBaseline(
                    range: first?.range ?? record.editedRange,
                    preImage: first?.preImage ?? NSAttributedString(),
                    selectionBefore: context?.selectionBefore ?? currentSelection,
                    timestamp: context?.timestamp ?? historyClock()
                )
            }
            return .compositionInterim
        }
        if compositionBaseline != nil { return .compositionCommit }

        // A single bracket holding several character mutations is
        // structurally bulk — a drag-move, Replace All, or an NSTextFinder
        // pass. Attribute captures don't count: AppKit's `insertText`
        // follows the one character it inserts with `setAttributes` for the
        // typing attributes, in the same bracket.
        let characterCaptures = record.captures.filter {
            if case .characters = $0.kind { return true }
            return false
        }
        if characterCaptures.count > 1 { return .bulk }

        switch context?.hint {
        case .attributeOnly:
            return .attributeOnly
        case .correction:
            return .correction
        case .deletion:
            return .deletion
        case .typing:
            // Storage is the truth: a hint that says typing but a record
            // that grew by more than one character is bulk.
            return record.changeInLength == 1 ? .typing : .bulk
        case .bulk, .composition:
            return .bulk
        case nil:
            // No hint — a host wrote storage directly, or a test did.
            let inserted: Int
            if case .characters(let n)? = characterCaptures.first?.kind {
                inserted = n
            } else {
                inserted = max(0, record.changeInLength)
            }
            if inserted == 1, record.changeInLength == 1 { return .typing }
            if inserted == 0 { return .deletion }
            return .bulk
        }
    }

    /// Run the run-scoped structural invariants — ordered-list
    /// renumbering, list-level clamping, blockquote continuity — over the
    /// structural run the edit landed in.
    ///
    /// `capturing: true` so the fix-up joins the undo unit of the edit that
    /// caused it: one undo of the deletion also puts the numbering back.
    private func enforceDocumentInvariants(around editedRange: NSRange) {
        let env = makeStepEnvironment()
        proseStorage.withOrigin(.normalize, capturing: true) {
            DocumentInvariants.enforce(in: textStorage, around: editedRange, env: env)
        }
    }

    /// Bring storage back to its invariants after an edit touched
    /// `editedRange`. Shared by the platform envelope close and the direct
    /// mutators so both leave the buffer in the same state.
    /// `scrub` cleans up attributes AppKit copies onto typed characters
    /// from the run before them. It is a platform-typing artifact — a
    /// programmatic mutation gets its attributes from the compiler, and
    /// scrubbing there strips the list marker off its own tab.
    private func normalizeAfterEdit(
        in editedRange: NSRange,
        accumulateHighlight: Bool = true,
        scrub: Bool = true,
        demoteEmptyLines: Bool = true
    ) {
        if accumulateHighlight { accumulateHighlightRange(editedRange) }
        if scrub { scrubTypedAttributes(in: editedRange) }
        normalizeInsertedAttributes(in: editedRange)
        if demoteEmptyLines { demoteEmptyStyledLines(in: editedRange) }
        enforceDocumentInvariants(around: editedRange)
        scheduleCodeBlockRehighlight()
        // Reconcile the trailing paragraph only when the edit reached the
        // document end. A mid-document keystroke can't change which block
        // is last, so this avoids a per-keystroke storage mutation (and
        // caret nudge) at the tail for the common typing case.
        if editedRange.location + editedRange.length >= textStorage.length {
            ensureTrailingParagraph()
        }
        intrinsicSizeInvalidator?()
    }

    /// Put the closed envelope on the undo stack.
    ///
    /// Typing, deletion, and correction coalesce into one burst while the
    /// user keeps working in the same place; everything else opens its own
    /// unit. A composition is always one unit measured against the state
    /// before it started.
    private func registerEnvelope(
        _ record: EditRecord,
        class editClass: EditClass,
        step: Step
    ) {
        guard editClass != .history else { return }
        var inverses = collectingInverses ?? []
        if editClass == .compositionCommit, case .replaceText(let range, _) = step {
            // The whole composition inverts to one edit: put back what was
            // there before the first marked-text pass.
            let baselinePre = pendingCompositionPreImage ?? NSAttributedString()
            pendingCompositionPreImage = nil
            let postLength = max(0, textStorage.length - range.location)
            let span = NSRange(
                location: range.location,
                length: min(committedCompositionLength, postLength)
            )
            inverses.append(.replaceText(range: span, with: baselinePre))
        } else {
            inverses.append(contentsOf: inverseSteps(from: record))
        }
        guard !inverses.isEmpty else { return }
        let coalescing: Bool
        switch editClass {
        case .typing, .deletion, .correction: coalescing = true
        default: coalescing = false
        }
        let context = record.context
        registerOrJoin(
            inverseSteps: inverses,
            selectionBefore: context?.selectionBefore ?? currentSelection,
            selectionAfter: currentSelection,
            touched: record.editedRange,
            at: context?.timestamp ?? historyClock(),
            coalescing: coalescing
        )
    }

    /// Forward-only `Step.replaceText` describing `record`. The pre-edit
    /// range is reconstructed by subtracting `changeInLength`; the post-edit
    /// content is read from current storage.
    private func derivedStep(from record: EditRecord) -> Step {
        let editedRange = record.editedRange
        let preLength = max(0, editedRange.length - record.changeInLength)
        let preRange = NSRange(location: editedRange.location, length: preLength)
        let safeEdited = editedRange.clamped(to: textStorage.length)
        return .replaceText(range: preRange, with: textStorage.attributedSubstring(from: safeEdited))
    }

    /// Give characters an edit just inserted the structure of the line
    /// they landed in, without minting anything.
    ///
    /// Replaces the old repair pass. That one derived a `BlockSpec` from
    /// the line and re-stamped it, which mints fresh `ProseNode`s — so
    /// deleting the first item of a list gave the surviving items a brand
    /// new list ancestor, splitting one list into two and losing the
    /// numbering. Here the line's dominant existing `NodePathBox` is
    /// reused, so identity survives every edit.
    private func normalizeInsertedAttributes(in edited: NSRange) {
        let total = textStorage.length
        guard total > 0 else { return }
        guard edited.location >= 0, edited.location <= total else { return }
        let ns = textStorage.string as NSString
        let probe = edited.clamped(to: total)
        var union = ns.paragraphRange(for: probe)
        guard union.length > 0 else { return }
        // An edit that inserted a line break split one block into two, and
        // the second half sits *after* the edited paragraph — a newline
        // terminates the paragraph it belongs to, so `paragraphRange` alone
        // never reaches the new block. Without this the two halves keep one
        // node and serialize as a single paragraph containing a newline.
        if editedRangeIntroducedALineBreak(probe, in: ns),
           union.location + union.length < total {
            let next = ns.paragraphRange(
                for: NSRange(location: union.location + union.length, length: 0)
            )
            union = NSRange(
                location: union.location,
                length: next.location + next.length - union.location
            )
        }

        proseStorage.withOrigin(.normalize, capturing: true) {
            textStorage.beginEditing()
            var cursor = union.location
            let end = union.location + union.length
            var claimed: Set<ObjectIdentifier> = []
            while cursor < end, cursor < textStorage.length {
                let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
                guard line.length > 0 else { break }
                normalizeLineAttributes(line, claimed: &claimed)
                let next = line.location + line.length
                cursor = next > cursor ? next : cursor + 1
            }
            textStorage.endEditing()
        }
    }

    private func editedRangeIntroducedALineBreak(_ range: NSRange, in ns: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let end = min(range.location + range.length, ns.length)
        var i = max(0, range.location)
        while i < end {
            if ns.character(at: i) == 0x0A { return true }
            i += 1
        }
        return false
    }

    /// One line: every character carries the same `proseNodePath` box, and
    /// characters that carry none inherit it. A list marker flag on a line
    /// that isn't a list item is dropped.
    ///
    /// A single-line block's node may not span a newline. Typed and pasted
    /// characters carry the insertion point's node forward, so a multi-line
    /// paste arrives as one paragraph covering every line it created; each
    /// line after the first gets a node of its own here. Multi-line blocks
    /// — code fences, tables — are exempt: one node covering many lines is
    /// exactly what they are.
    private func normalizeLineAttributes(_ line: NSRange, claimed: inout Set<ObjectIdentifier>) {
        var tally: [ObjectIdentifier: (box: NodePathBox, weight: Int)] = [:]
        var unstamped: [NSRange] = []
        textStorage.enumerateAttribute(.proseNodePath, in: line) { value, runRange, _ in
            if let box = value as? NodePathBox {
                tally[ObjectIdentifier(box), default: (box, 0)].weight += runRange.length
            } else {
                unstamped.append(runRange)
            }
        }
        // Ties are broken by the line terminator's node. A character
        // inserted into a line carries the *insertion point's* node
        // forward, which may belong to the block before it; the newline
        // that ends the line never does. Without a deterministic rule here
        // `Dictionary` iteration order decides, and a one-character line
        // resolves differently from run to run.
        let terminator = terminatorBox(of: line)
        guard let winner = tally.values.max(by: { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
            let lhsIsTerminator = terminator.map { $0 === lhs.box } ?? false
            let rhsIsTerminator = terminator.map { $0 === rhs.box } ?? false
            return !lhsIsTerminator && rhsIsTerminator
        })?.box else {
            // Nothing on this line carries structure — content injected
            // straight into storage, or the first character of an empty
            // document. There is no identity to preserve, so minting one
            // is safe. `setBlockSpec` reuses the predecessor's list and
            // blockquote ancestors.
            textStorage.setBlockSpec(BlockSpec(kind: .paragraph), in: line)
            textStorage.addAttribute(.proseMarks, value: MarkSetBox(MarkSet()), range: line)
            if let minted = textStorage.attribute(.proseNodePath, at: line.location, effectiveRange: nil) as? NodePathBox {
                claimed.insert(ObjectIdentifier(minted))
            }
            return
        }
        let key = ObjectIdentifier(winner)
        // The multi-line exemption gates the whole re-stamp, not just the
        // `spansAnEarlierLine` half: a fence's second line finds its own box
        // already `claimed` by its first, and re-stamping there is what split
        // one code block into one block per line.
        if !isMultiLineBlock(winner.path),
           claimed.contains(key) || spansAnEarlierLine(winner, line: line) {
            textStorage.setBlockSpec(
                BlockSpec.fromNodePath(winner.path) ?? BlockSpec(kind: .paragraph),
                in: line
            )
            if let minted = textStorage.attribute(.proseNodePath, at: line.location, effectiveRange: nil) as? NodePathBox {
                claimed.insert(ObjectIdentifier(minted))
            }
        } else {
            claimed.insert(key)
            if tally.count > 1 || !unstamped.isEmpty {
                textStorage.addAttribute(.proseNodePath, value: winner, range: line)
            }
        }
        // Inserted characters inherit the marks of the run before them;
        // there is nothing else they could reasonably belong to.
        for gap in unstamped where gap.length > 0 {
            let donor = gap.location > line.location ? gap.location - 1 : gap.location + gap.length
            let box = donor < textStorage.length
                ? textStorage.attribute(.proseMarks, at: donor, effectiveRange: nil) as? MarkSetBox
                : nil
            textStorage.addAttribute(.proseMarks, value: box ?? MarkSetBox(MarkSet()), range: gap)
        }
        if textStorage.blockSpec(at: line.location)?.isListItem != true {
            textStorage.removeAttribute(.proseListMarker, range: line)
        }
    }

    private func terminatorBox(of line: NSRange) -> NodePathBox? {
        let last = line.location + line.length - 1
        guard last >= 0, last < textStorage.length else { return nil }
        return textStorage.attribute(.proseNodePath, at: last, effectiveRange: nil) as? NodePathBox
    }

    /// True when `box` already covers a line before this one and its block
    /// is single-line, so this line needs a node of its own.
    private func spansAnEarlierLine(_ box: NodePathBox, line: NSRange) -> Bool {
        guard line.location > 0 else { return false }
        if isMultiLineBlock(box.path) { return false }
        let full = NSRange(location: 0, length: textStorage.length)
        var effective = NSRange(location: 0, length: 0)
        _ = textStorage.safeAttribute(
            .proseNodePath,
            at: line.location,
            longestEffectiveRange: &effective,
            in: full
        )
        return effective.location < line.location
    }

    private func isMultiLineBlock(_ path: NodePath) -> Bool {
        if let leaf = path.leaf, ["code_block", "html_block", "table"].contains(leaf.type) {
            return true
        }
        return path.nodes.contains { $0.type == "table" }
    }

    private func scrubTypedAttributes(in editedRange: NSRange) {
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

        proseStorage.withOrigin(.normalize, capturing: true) {
            textStorage.beginEditing()
            for r in attachmentStrays { textStorage.removeAttribute(.attachment, range: r) }
            for r in markerStrays { textStorage.removeAttribute(.proseListMarker, range: r) }
            textStorage.endEditing()
        }
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
    private func demoteEmptyStyledLines(in editedRange: NSRange) {
        let plainAttrs = theme.plainParagraphAttributes()
        if textStorage.length == 0 {
            applyTypingAttributes(plainAttrs)
            return
        }
        let ns = textStorage.string as NSString
        guard editedRange.length >= 0, editedRange.location >= 0 else { return }
        let scanRange = editedRange.clamped(to: ns.length)
        let unionRange: NSRange = scanRange.length > 0
            ? ns.paragraphRange(for: scanRange)
            : ns.paragraphRange(for: NSRange(location: scanRange.location, length: 0))
        guard unionRange.length > 0 else { return }

        var demoted = false
        proseStorage.withOrigin(.normalize, capturing: true) {
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
        }
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

    /// Replace the document with `markdown`. When a host text view is
    /// attached we compile off the main thread on `compileQueue` and apply
    /// the result back on main; the latest-wins generation counter discards
    /// stale results when rapid binding writes pile up. Headless callers
    /// (no host) and explicit `async: false` callers stay synchronous so
    /// existing tests reading `markdown()` immediately after `setMarkdown`
    /// see the new content on return.
    public func setMarkdown(_ markdown: String, async: Bool = true) {
        drainPendingEnvelopes()
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
        drainPendingEnvelopes()
        let md = serializer.serializeFromTree(proseStorage.contents)
        // Public document text matches prosemirror-markdown: blocks are
        // separated by blank lines but the document carries no terminal
        // newline. (The tree serializer newline-terminates each block; the
        // boundary trims the final one.)
        return md.hasSuffix("\n") ? String(md.dropLast()) : md
    }

    public func loadProseMirrorJSON(_ json: String, schemaMap: SchemaMap = .basic) throws {
        drainPendingEnvelopes()
        let codec = ProseMirrorCodec(schemaMap: schemaMap, theme: theme)
        let compiled = try codec.decode(json)
        replaceStorage(with: compiled)
    }

    public func loadProseMirrorJSON(_ data: Data, schemaMap: SchemaMap = .basic) throws {
        drainPendingEnvelopes()
        let codec = ProseMirrorCodec(schemaMap: schemaMap, theme: theme)
        let compiled = try codec.decode(data)
        replaceStorage(with: compiled)
    }

    public func exportProseMirrorJSON(schemaMap: SchemaMap = .basic) throws -> Data {
        drainPendingEnvelopes()
        let codec = ProseMirrorCodec(schemaMap: schemaMap, theme: theme)
        return try codec.encodeToJSON(textStorage)
    }

    public func recompile() {
        let md = markdown()
        setMarkdown(md)
    }

    var testSelection: NSRange?
    /// Test seam next to `testSelection` — lets headless classification
    /// tests drive the composition path without an input system.
    var testMarkedText: Bool?

    public var currentSelection: NSRange {
        if let testSelection { return testSelection }
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView { return tv.selectedRange() }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView { return tv.selectedRange }
        #endif
        return NSRange(location: 0, length: 0)
    }

    /// Typed view of `currentSelection`. For now, every selection
    /// surfaces as `.text` — `.node` and `.all` are reserved for future
    /// commands (Backspace-on-HR selects the node, Cmd+A produces
    /// `.all`). Hosts that want to react differently to a node selection
    /// inspect the case.
    public var currentTypedSelection: Selection {
        let range = currentSelection
        let head = range.location + range.length
        return .text(range: range, anchor: range.location, head: head)
    }


    /// Insert plain text at the host text view's cursor (or replace its
    /// selection). Cursor lands after the inserted text.
    @discardableResult
    public func insert(text: String) -> NSRange {
        drainPendingEnvelopes()
        let selection = currentSelection
        var result = NSRange(location: 0, length: 0)
        withCharacterMutation(range: selection) {
            result = Operations.insertText(
                in: textStorage,
                replacing: selection,
                with: text,
                fallbackAttributes: theme.plainParagraphAttributes()
            )
        }
        setHostSelection(result)
        return result
    }

    /// When `true`, multi-character non-IME insertions arriving through
    /// the macOS text-view delegate (`shouldChangeTextIn`) are routed
    /// through the paste pipeline so dictation, autocomplete, and other
    /// bulk insertions become a single undo step with correct paragraph
    /// splits. Set to `false` if a host relies on raw per-string
    /// `insertText` semantics for those events.
    public var useStructuredBulkInsert: Bool = true

    /// Return the first non-nil value pulled from `props` by `extract`,
    /// walking plugins in registration order. PM-equivalent to
    /// `EditorView.someProp`. Used by paste / dictation dispatch to find
    /// the consuming plugin without ordering surprises.
    public func firstNonNilPluginProp<T>(_ extract: (PluginProps) -> T?) -> T? {
        for plugin in plugins {
            if let value = extract(plugin.props) { return value }
        }
        return nil
    }

    /// Run the paste pipeline for `event`:
    ///   1. `handleDictation` (for `.dictation` events only) then
    ///      `handlePaste` (first that returns true consumes).
    ///   2. `transformPastedText` chain (rewrites the plain-text body).
    ///   3. `transformPasted` chain (rewrites the whole event).
    ///   4. Slice branch — HTML present and not plain-text-only routes
    ///      through `ClipboardParser`; otherwise the plain-text branch
    ///      inserts the text directly (code blocks verbatim, others
    ///      paragraph-split).
    ///
    /// The whole operation lands as one `withCharacterMutation` group,
    /// so dictation and paste become one undo step.
    @discardableResult
    public func dispatchPaste(_ event: PasteEvent) -> Bool {
        drainPendingEnvelopes()
        var current = event
        if current.source == .dictation {
            for plugin in plugins {
                if plugin.props.handleDictation?(self, current) == true { return true }
            }
        }
        for plugin in plugins {
            if plugin.props.handlePaste?(self, current) == true { return true }
        }
        if let raw = current.text {
            var text = raw
            let asPlain = current.inCode || current.plainText
            for plugin in plugins {
                if let transform = plugin.props.transformPastedText {
                    text = transform(self, text, asPlain)
                }
            }
            current.text = text
        }
        for plugin in plugins {
            if let transform = plugin.props.transformPasted {
                current = transform(self, current)
            }
        }
        if let html = current.html, !html.isEmpty, !current.plainText, !current.inCode {
            let parser = ClipboardParser(schema: compiler.schema)
            if let slice = parser.parseFromClipboard(
                controller: self,
                text: current.text,
                html: html,
                plainText: false,
                selection: current.selection
            ) {
                return insertSlice(slice, replacing: current.selection)
            }
        }
        return performDefaultPasteInsertion(current)
    }

    /// Insert a `Slice` at the given storage range via a typed
    /// `Step.replaceRange` transaction. The step's `apply` round-trips
    /// the slice through markdown (a minimal fitter — PM-equivalent
    /// defining / isolating / allowed-marks semantics layer on top in
    /// follow-up work).
    @discardableResult
    private func insertSlice(_ slice: Slice, replacing range: NSRange) -> Bool {
        guard isEditable else { return false }
        guard !slice.isEmpty else { return false }
        let from = range.location
        let to = range.location + range.length
        var transaction = Transaction(steps: [
            .replaceRange(from: from, to: to, slice: slice)
        ])
        transaction.label = "Paste"
        _ = apply(transaction)
        return true
    }

    /// Insert `event.text` as plain text. Code-block destinations keep
    /// every newline; other destinations collapse runs of two-or-more
    /// newlines to a single `\n` so the storage segmenter / repair pass
    /// turns each into a paragraph break.
    @discardableResult
    private func performDefaultPasteInsertion(_ event: PasteEvent) -> Bool {
        guard isEditable, let raw = event.text, !raw.isEmpty else { return false }
        let normalized = normalizeLineEndings(raw)
        let toInsert: String
        if event.inCode {
            toInsert = normalized
        } else {
            toInsert = collapseBlankLineRuns(normalized)
        }
        var result = NSRange(location: event.selection.location, length: 0)
        withCharacterMutation(range: event.selection) {
            result = Operations.insertText(
                in: textStorage,
                replacing: event.selection,
                with: toInsert,
                fallbackAttributes: theme.plainParagraphAttributes()
            )
        }
        setHostSelection(result)
        refreshTypingAttributes(at: result.location)
        return true
    }

    /// Slice the current storage to the given character range and project
    /// it as a `Slice` suitable for the clipboard. Single-paragraph
    /// selections unwrap to inline content with `openStart == openEnd == 1`
    /// so they merge into surrounding context on paste; multi-block
    /// selections stay closed so each top-level block survives.
    public func sliceForRange(_ range: NSRange) -> Slice {
        drainPendingEnvelopes()
        let total = textStorage.length
        guard total > 0 else { return .empty }
        let safe = range.clamped(to: total)
        guard safe.length > 0 else { return .empty }
        let doc = ProseDocument.from(storage: proseStorage.contents, range: safe, schema: compiler.schema)
        guard case .structural(_, let kids) = doc.root else { return .empty }
        let children = kids
        guard !children.isEmpty else { return .empty }
        let onlyInline = children.allSatisfy(isInlineWrapper)
        if onlyInline, children.count == 1, case .structural(_, let inlineKids) = children[0] {
            return Slice(content: Fragment(inlineKids), openStart: 1, openEnd: 1)
        }
        return Slice(content: Fragment(children), openStart: 0, openEnd: 0)
    }

    private func isInlineWrapper(_ node: TreeNode) -> Bool {
        if case .structural(let pn, _) = node, pn.type == "paragraph" {
            return true
        }
        return false
    }

    /// Resolve the storage offset's enclosing block spec and return true
    /// when the cursor sits in a code block. Used by the paste / dictation
    /// dispatchers to flip the inCode branch.
    func isLocationInCodeBlock(_ location: Int) -> Bool {
        let total = textStorage.length
        guard total > 0 else { return false }
        let probe = max(0, min(location, total - 1))
        return textStorage.blockSpec(at: probe)?.isCodeBlock == true
    }

    func normalizeLineEndings(_ s: String) -> String {
        // Scalar-level: `Character` folds CRLF into one grapheme, so a
        // pure-CRLF payload never satisfies `contains("\r")`.
        if !s.unicodeScalars.contains("\r") { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Collapse any run of 2+ newlines to a single `\n`. In storage,
    /// blocks are separated by exactly one newline; the surrounding
    /// validate-and-repair pass derives block specs from the synthesized
    /// node-path after the edit.
    func collapseBlankLineRuns(_ s: String) -> String {
        guard s.contains("\n\n") else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        var newlineRun = 0
        for ch in s {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun == 1 { out.append(ch) }
            } else {
                newlineRun = 0
                out.append(ch)
            }
        }
        return out
    }

    /// Register a plugin. Plugins are consulted in registration order
    /// for filterTransaction / appendTransaction / props hooks.
    public func register(plugin: EditorPlugin) {
        plugins.append(plugin)
    }

    /// Retrieve the typed state slot a plugin previously stored.
    public func pluginState<State>(for key: PluginKey<State>) -> State? {
        pluginStates[key.any] as? State
    }

    /// Store typed state for a plugin under `key`.
    public func setPluginState<State>(_ state: State, for key: PluginKey<State>) {
        pluginStates[key.any] = state
    }

    /// Drop the state slot for `key`. Used by plugins on session close
    /// (e.g. completion menu dismissed) to free observers.
    public func clearPluginState<State>(for key: PluginKey<State>) {
        pluginStates.removeValue(forKey: key.any)
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
        drainPendingEnvelopes()
        lastInputRule = nil
        guard let resultRange = applyCore(transaction) else { return currentSelection }
        runAppendTransactions(after: [transaction])
        return resultRange
    }

    @discardableResult
    private func applyCore(_ transaction: Transaction, ignoringFilterPluginAt ignoredPluginIndex: Int? = nil) -> NSRange? {
        guard !transaction.steps.isEmpty else { return nil }
        for (index, plugin) in plugins.enumerated()
        where ignoredPluginIndex.map({ $0 == index }) != true
            && !plugin.filterTransaction(transaction, controller: self) {
            return nil
        }
        if (transaction.getMeta("closeHistory") as? Bool) == true {
            closeHistoryGroup()
        }
        let recordHistory = (transaction.getMeta("addToHistory") as? Bool) != false
        let env = makeStepEnvironment()
        var lastRange = currentSelection
        let preSelection = currentSelection
        let preMutationRange = mutationRange(for: transaction)
        var appliedTransaction: AppliedTransaction?
        // Normalization that follows the steps belongs to the same undo
        // unit — undoing the command undoes the trailing paragraph it
        // caused, not one keystroke later.
        let outerCollecting = collectingInverses
        collectingInverses = []
        proseStorage.withOrigin(.transaction) {
            let preLength = self.textStorage.length
            let applied = transaction.apply(to: self.textStorage, env: env)
            appliedTransaction = applied
            lastRange = applied.mappedRange
            let delta = self.textStorage.length - preLength
            let unionLength = max(0, preMutationRange.length + max(0, delta))
            let validationRange = NSRange(
                location: min(preMutationRange.location, max(0, self.textStorage.length)),
                length: min(unionLength, self.textStorage.length - min(preMutationRange.location, max(0, self.textStorage.length)))
            )
            self.validate(in: validationRange)
        }
        invalidateForOutOfBandSubtree(appliedTransaction)
        ensureTrailingParagraph()
        scheduleCodeBlockRehighlight()
        intrinsicSizeInvalidator?()
        let normalizationInverses = collectingInverses ?? []
        collectingInverses = outerCollecting

        // tr.selection wins; otherwise collapse to the end of the changed
        // range, backing off from a trailing newline when the render emitted
        // a block terminator.
        let resultRange: NSRange
        if let sel = transaction.selection {
            resultRange = sel.resolvedRange(documentLength: textStorage.length)
        } else {
            let end = lastRange.location + lastRange.length
            let cursor: Int
            if lastRange.length > 0,
               end <= textStorage.length,
               (textStorage.string as NSString).character(at: end - 1) == 0x0A {
                cursor = end - 1
            } else {
                cursor = end
            }
            resultRange = NSRange(location: cursor, length: 0)
        }
        setHostSelection(resultRange)
        refreshTypingAttributes(at: resultRange.location)
        if recordHistory, let applied = appliedTransaction {
            // `meta["coalesce"]` marks a transaction that stands in for a
            // keystroke (a typed character rerouted around an isolating
            // block): it joins the open typing burst and leaves it open, so
            // the rest of the word lands in the same undo unit.
            let coalescing = (transaction.getMeta("coalesce") as? Bool) == true
            // A command always opens its own unit — typing before it must
            // not be swept in.
            if !coalescing { closeTypingRecord() }
            registerOrJoin(
                inverseSteps: normalizationInverses + applied.inverse.steps,
                selectionBefore: preSelection,
                selectionAfter: resultRange,
                touched: applied.mappedRange,
                at: historyClock(),
                coalescing: coalescing,
                label: transaction.label
            )
        }
        if transaction.scrollIntoView {
            scrollSelectionIntoView()
        }
        return resultRange
    }

    private func runAppendTransactions(after rootTransactions: [Transaction]) {
        guard !runningAppendTransactions, !rootTransactions.isEmpty, !plugins.isEmpty else { return }
        runningAppendTransactions = true
        defer { runningAppendTransactions = false }

        var transactions = rootTransactions
        var seen: [Int]?

        while true {
            var haveNew = false
            for index in plugins.indices {
                let start = seen?[index] ?? 0
                guard start < transactions.count else {
                    if seen != nil { seen![index] = transactions.count }
                    continue
                }
                let newTransactions = Array(transactions[start..<transactions.count])
                if var follow = plugins[index].appendTransaction(after: newTransactions, controller: self) {
                    follow.setMeta("appendedTransaction", true)
                    if applyCore(follow, ignoringFilterPluginAt: index) != nil {
                        if seen == nil {
                            seen = plugins.indices.map { $0 < index ? transactions.count : 0 }
                        }
                        transactions.append(follow)
                        haveNew = true
                    }
                }
                if seen != nil {
                    seen![index] = transactions.count
                }
            }
            if !haveNew { return }
        }
    }

    /// Scroll the host text view so the current selection is visible.
    /// Called when a transaction sets `scrollIntoView == true`.
    private func scrollSelectionIntoView() {
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView {
            tv.scrollRangeToVisible(tv.selectedRange())
        }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView {
            tv.scrollRangeToVisible(tv.selectedRange)
        }
        #endif
    }

    /// Check the spec invariants in `range` and forward any diagnostics.
    ///
    /// Validation only — nothing is repaired. Normalization already ran
    /// (`normalizeInsertedAttributes`, `DocumentInvariants`), so a
    /// diagnostic here means one of those has a bug, and silently patching
    /// the buffer would hide it. In DEBUG it trips an assertion.
    ///
    /// Two validators run sequentially:
    /// 1. `SpecValidator` — line-level structural invariants.
    /// 2. `SchemaValidator` — typed-tree-level checks (unknown node /
    ///    mark types, content-rule mismatches, marks on disallowed
    ///    parents), gated on a handler being installed.
    func validate(in range: NSRange) {
        let specDiagnostics = SpecValidator.validate(in: textStorage, range: range)
        for diagnostic in specDiagnostics {
            fanoutDiagnostic(diagnostic)
        }
        #if DEBUG
        // Reaching here means normalization left the buffer inconsistent.
        // Repairing would hide the bug; assert instead so it surfaces in
        // the suite and in the demo app.
        if !specDiagnostics.isEmpty, assertsOnDiagnostics {
            assertionFailure(
                "spec invariants violated after an edit: \(specDiagnostics)"
            )
        }
        #endif
        // Project the live storage to a typed tree and run the schema-level
        // validator. Diagnostics surface through onSchemaDiagnostic so hosts
        // can wire them into the same surface as block-spec diagnostics.
        // Gated on a handler being installed: the projection is O(document)
        // and every transaction would otherwise pay for it unobserved.
        guard let schemaHandler = onSchemaDiagnostic else { return }
        let document = ProseDocument.from(storage: proseStorage.contents, schema: compiler.schema)
        for diagnostic in SchemaValidator.validate(document) {
            schemaHandler(diagnostic)
        }
    }

    private func mutationRange(for transaction: Transaction) -> NSRange {
        var lo = textStorage.length
        var hi = 0
        for step in transaction.steps {
            switch step {
            case .replaceText(let range, _),
                 .setSpec(let range, _),
                 .setSpecPreservingLineTerminator(let range, _),
                 .toggleInlineMark(let range, _),
                 .addMark(let range, _),
                 .removeMark(let range, _),
                 .setMarkAttrs(let range, _, _):
                lo = min(lo, range.location)
                hi = max(hi, range.location + range.length)
            case .replaceAround(let outer, _, _, _):
                lo = min(lo, outer.location)
                hi = max(hi, outer.location + outer.length)
            case .setNodeAttrs, .setNodeAttrsAt, .replaceCellInline, .setTableSubtree,
                 .addNodeMark, .removeNodeMark, .setDocAttr:
                // Identity-addressed; no positional bounds — leave as the
                // current accumulator. The apply path resolves the
                // affected range from the stored NodePath / table id.
                continue
            case .replaceRange(let from, let to, _):
                lo = min(lo, from)
                hi = max(hi, to)
            }
        }
        guard hi > lo else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lo, length: hi - lo)
    }

    public func canPerform(_ action: EditorAction) -> Bool {
        guard isEditable else { return false }
        return commands.canExecute(action, storage: textStorage, selection: currentSelection)
    }

    /// Bounding rect of the caret in the host text view's coordinate
    /// space. Returns nil when no host view is attached or layout isn't
    /// ready. Used by completion popups, ghost-text overlays, and
    /// anything else that needs to track the cursor on screen.
    public func caretRect() -> CGRect? {
        let cursor = currentSelection.location
        let total = textStorage.length
        guard cursor >= 0, cursor <= total else { return nil }
        let docStart = contentStorage.documentRange.location
        guard let location = contentStorage.location(docStart, offsetBy: cursor) else { return nil }
        let textRange = NSTextRange(location: location)
        var rect: CGRect?
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: [.upstreamAffinity, .rangeNotRequired]
        ) { _, frame, _, _ in
            rect = frame
            return false
        }
        guard var caretRect = rect else { return nil }
        // Translate from layout-fragment coords to text-view coords by
        // adding the host's textContainerInset.
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView {
            caretRect.origin.x += tv.textContainerInset.width
            caretRect.origin.y += tv.textContainerInset.height
        }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView {
            caretRect.origin.x += tv.textContainerInset.left
            caretRect.origin.y += tv.textContainerInset.top
        }
        #endif
        return caretRect
    }

    /// True when the action's effect is currently in force at the
    /// selection — bold mark covers the range, heading kind matches the
    /// cursor's block. Drives toolbar "pressed" state.
    public func isActionActive(_ action: EditorAction) -> Bool {
        commands.isActive(action, storage: textStorage, selection: currentSelection, controller: self)
    }

    /// Stable IDs of every registered action whose `isActive` returns
    /// true. Recomputed on demand from the SwiftUI layer; cheap because
    /// each command only inspects the cursor neighbourhood.
    public func activeActionIDs() -> Set<String> {
        var ids: Set<String> = []
        let storage = textStorage
        let selection = currentSelection
        for command in commands.registeredCommands {
            if command.isActive(storage: storage, selection: selection, controller: self) {
                ids.insert(command.id)
            }
        }
        return ids
    }

    @discardableResult
    public func perform(_ action: EditorAction) -> NSRange {
        guard isEditable else { return currentSelection }
        drainPendingEnvelopes()
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

    /// Re-stamp syntax colors on the code blocks the pending edits touched.
    ///
    /// Coalesced onto the next main-runloop tick when a host text view is
    /// attached, so a burst of keystrokes rehighlights once. Headless
    /// callers run synchronously so a read right after an edit sees settled
    /// colors.
    func scheduleCodeBlockRehighlight() {
        guard pendingHighlightRange != nil else { return }
        guard hostTextView != nil else {
            flushCodeBlockRehighlight()
            return
        }
        guard !rehighlightScheduled else { return }
        rehighlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rehighlightScheduled = false
            self.flushCodeBlockRehighlight()
        }
    }

    private func flushCodeBlockRehighlight() {
        guard let pending = pendingHighlightRange else { return }
        pendingHighlightRange = nil
        rehighlightRunCount += 1
        rehighlightCodeBlocks(intersecting: pending)
    }

    /// Test-only counter, bumped at the start of every rehighlight pass so
    /// tests can verify coalescing without stubbing out the work.
    var rehighlightRunCount: Int = 0

    /// Test seam: fires with the range of each code block recolored.
    var rehighlightProbe: ((NSRange) -> Void)?

    var isComposingIME: Bool {
        if let testMarkedText { return testMarkedText }
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView { return tv.hasMarkedText() }
        #elseif canImport(UIKit)
        if let tv = hostTextView as? UITextView { return tv.markedTextRange != nil }
        #endif
        return false
    }

    /// Set by `ProseUITextView` between `insertDictationResultPlaceholder`
    /// and `removeDictationResultPlaceholder`. Interim dictation writes
    /// placeholder text into storage; none of it is real content.
    var dictationPlaceholderActive = false

    @discardableResult
    func evaluateInputRules() -> Bool {
        let cursor = currentSelection.location
        var didFire = false
        _ = inputRules.evaluate(
            storage: textStorage,
            cursor: cursor,
            env: makeStepEnvironment(),
            apply: { [weak self] tx in
                _ = self?.apply(tx)
                didFire = true
            }
        )
        if didFire, let fired = inputRules.lastFiredRule {
            lastInputRule = fired
        } else {
            lastInputRule = nil
            inputRules.clearLastFiredRule()
        }
        if didFire {
            // Inline rules (bold, italic, code-span, etc.) conclude a
            // styling event — the user has just closed `**bold**` or `` `code` ``.
            // Reset typing attributes to plain so the next typed character
            // escapes the inline mark instead of inheriting it from the
            // run that the rule just stamped.
            applyTypingAttributes(theme.plainParagraphAttributes())
            clearStoredInlineMarks()
        }
        return didFire
    }

    /// `.link` without a URL: the selection stays the label, and becomes
    /// the destination too when it already reads as one. Otherwise the
    /// destination is the placeholder `"url"` for the host's link editor
    /// to replace (see `updateLink(in:href:title:)`).
    private func performLink(url: String?, label: String?) -> NSRange {
        let selected = selectedText()
        let href = url ?? (selected.map(Self.looksLikeURL) == true ? selected! : "url")
        return insertLink(label: label ?? "link", url: href)
    }

    /// Insert a link at the host text view's cursor. If the user has a
    /// non-empty selection, that text becomes the link's display label;
    /// otherwise the supplied `label` (e.g. `"bug 12345"`) is used. The URL
    /// rides on the `link` mark and round-trips as `[label](url)`.
    @discardableResult
    public func insertLink(label: String, url: String) -> NSRange {
        drainPendingEnvelopes()
        let selection = currentSelection
        let actualLabel = selectedText() ?? label
        var result = NSRange(location: selection.location, length: 0)
        withCharacterMutation(range: selection) {
            result = Operations.insertLink(
                in: textStorage,
                replacing: selection,
                label: actualLabel,
                url: url,
                theme: theme
            )
            // `Operations.insertLink` lays down rendering attributes; the
            // canonical `proseMarks` come from them.
            let linked = NSRange(location: selection.location, length: (actualLabel as NSString).length)
            NodePathSynthesizer(schema: compiler.schema)
                .stampMarks(in: textStorage, range: linked.clamped(to: textStorage.length))
        }
        setHostSelection(result)
        refreshTypingAttributes(at: result.location)
        return result
    }

    /// The selected text, or nil when the selection is empty.
    private func selectedText() -> String? {
        let selection = currentSelection
        guard selection.length > 0,
              selection.location + selection.length <= textStorage.length else { return nil }
        let text = (textStorage.string as NSString).substring(with: selection)
        return text.isEmpty ? nil : text
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty,
           url.host != nil || scheme == "mailto" {
            return true
        }
        return trimmed.hasPrefix("www.")
    }

    // MARK: - undo

    /// The typing / deletion / correction burst currently accepting more
    /// edits. Closed by the delay, by a non-adjacent edit, by any other
    /// edit class, and by every command entry point.
    private var openTypingRecord: HistoryRecord?

    /// While non-nil, normalization inverses are collected here instead of
    /// being dropped, so the pass that fixes up an edit is undone with it.
    private var collectingInverses: [Step]?

    /// True while `applyHistory` is replaying; suppresses re-registration
    /// from nested paths.
    private(set) var isApplyingHistory = false

    /// Turn a storage record's captures into inverse steps, newest first.
    ///
    /// Each capture's pre-image is replaced back over the range the capture
    /// produced. Reversing the order is what makes it valid: the last
    /// capture's post-range is correct in the final state, and undoing it
    /// restores the state the one before it was measured against.
    func inverseSteps(from record: EditRecord) -> [Step] {
        record.captures.reversed().map { capture in
            let inserted: Int
            switch capture.kind {
            case .characters(let n): inserted = n
            case .attributes: inserted = capture.range.length
            }
            let postRange = NSRange(location: capture.range.location, length: inserted)
            return .replaceText(range: postRange.clamped(to: textStorage.length), with: capture.preImage)
        }
    }

    /// Close the open typing burst so the next edit starts a fresh unit.
    func closeTypingRecord() {
        openTypingRecord = nil
    }

    /// Put `record` on the undo stack as one unit.
    private func register(_ record: HistoryRecord) {
        guard !isApplyingHistory else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { controller in
            controller.performUndo(of: record)
        }
        if let label = record.label {
            undoManager.setActionName(label)
        }
        undoManager.endUndoGrouping()
    }

    /// Register `record`, or fold it into the open burst when it belongs
    /// to the same one. Returns the unit that ended up holding it.
    @discardableResult
    private func registerOrJoin(
        inverseSteps: [Step],
        selectionBefore: NSRange,
        selectionAfter: NSRange,
        touched: NSRange,
        at time: TimeInterval,
        coalescing: Bool,
        label: String? = nil
    ) -> HistoryRecord? {
        guard !inverseSteps.isEmpty else { return nil }
        if coalescing,
           let open = openTypingRecord,
           time - open.lastEditAt <= historyConfig.newGroupDelay,
           open.touches(touched) {
            open.absorb(
                inverseSteps: inverseSteps,
                selectionAfter: selectionAfter,
                touched: touched,
                at: time
            )
            return open
        }
        let record = HistoryRecord(
            inverseSteps: inverseSteps,
            selectionBefore: selectionBefore,
            selectionAfter: selectionAfter,
            touchedRanges: [touched],
            lastEditAt: time,
            label: label
        )
        register(record)
        openTypingRecord = coalescing ? record : nil
        return record
    }

    /// Move the caret, on whichever surface owns it.
    ///
    /// `testSelection` is the headless seam and takes precedence over the
    /// host text view in `currentSelection`; writing it while a host is
    /// attached pins the selection for good, because nothing clears it
    /// again. Every later command then reads a stale range — a toolbar
    /// mark applies where the last undo landed rather than where the user
    /// is.
    private func installSelection(_ range: NSRange) {
        setHostSelection(range)
        if hostTextView == nil { testSelection = range }
    }

    /// Undo (or redo — `UndoManager` routes the re-registration for us)
    /// one unit, then push its counterpart with the selections swapped.
    private func performUndo(of record: HistoryRecord) {
        closeTypingRecord()
        let applied = applyHistory(Transaction(steps: record.inverseSteps, label: record.label))
        installSelection(record.selectionBefore)
        refreshTypingAttributes(at: record.selectionBefore.location)

        let counterpart = HistoryRecord(
            inverseSteps: applied.inverse.steps,
            selectionBefore: record.selectionAfter,
            selectionAfter: record.selectionBefore,
            touchedRanges: [applied.mappedRange],
            lastEditAt: historyClock(),
            label: record.label
        )
        register(counterpart)
    }

    /// Replay `transaction` as history: sequential, no plugin filters, no
    /// registration of its own, no append transactions. Matches what the
    /// old undo closures did.
    @discardableResult
    func applyHistory(_ transaction: Transaction) -> AppliedTransaction {
        var env = makeStepEnvironment()
        env.isHistoryReplay = true
        let wasApplying = isApplyingHistory
        isApplyingHistory = true
        defer { isApplyingHistory = wasApplying }

        var applied: AppliedTransaction!
        proseStorage.withOrigin(.history) {
            applied = transaction.apply(to: textStorage, env: env, sequential: true)
            validate(in: applied.mappedRange.clamped(to: textStorage.length))
        }
        invalidateForOutOfBandSubtree(applied)
        ensureTrailingParagraph()
        accumulateHighlightRange(applied.mappedRange)
        scheduleCodeBlockRehighlight()
        intrinsicSizeInvalidator?()
        return applied
    }

    /// Run `body` as one undoable character mutation.
    ///
    /// The pre-image of `range` *is* the inverse — it carries the original
    /// attributes, `NodePathBox` references included, so undo restores node
    /// identity rather than re-deriving it.
    func withCharacterMutation(
        range: NSRange,
        demoteEmptyLines: Bool = true,
        _ body: () -> Void
    ) {
        drainPendingEnvelopes()
        let preLength = textStorage.length
        let preRange = range.clamped(to: preLength)
        let pre = textStorage.attributedSubstring(from: preRange)
        let preSelection = currentSelection
        let outerCollecting = collectingInverses
        collectingInverses = []
        proseStorage.withOrigin(.transaction) { body() }
        let delta = textStorage.length - preLength
        let postRange = NSRange(location: preRange.location, length: max(0, preRange.length + delta))

        normalizeAfterEdit(in: postRange, scrub: false, demoteEmptyLines: demoteEmptyLines)
        clearStoredInlineMarks()
        let normalizationInverses = collectingInverses ?? []
        collectingInverses = outerCollecting

        // A programmatic mutation always opens its own undo unit.
        closeTypingRecord()
        registerOrJoin(
            inverseSteps: normalizationInverses
                + [.replaceText(range: postRange.clamped(to: textStorage.length), with: pre)],
            selectionBefore: preSelection,
            selectionAfter: currentSelection,
            touched: postRange,
            at: historyClock(),
            coalescing: false
        )
        // Plugins' append transactions (auto-link, completion) run for
        // programmatic insertion; input rules do not. A rule that rewrites
        // what a host just inserted is not what the host asked for.
        let step = Step.replaceText(
            range: preRange,
            with: textStorage.attributedSubstring(from: postRange.clamped(to: textStorage.length))
        )
        runAppendTransactions(after: [Transaction(steps: [step])])
    }

    /// Run `body` as one undoable attribute mutation. Same mechanism as
    /// `withCharacterMutation` — the pre-image restores the attributes.
    func withAttributeMutation(range: NSRange, _ body: () -> Void) {
        let safe = range.clamped(to: textStorage.length)
        let pre = textStorage.attributedSubstring(from: safe)
        let preSelection = currentSelection
        proseStorage.withOrigin(.transaction) { body() }
        closeTypingRecord()
        registerOrJoin(
            inverseSteps: [.replaceText(range: safe.clamped(to: textStorage.length), with: pre)],
            selectionBefore: preSelection,
            selectionAfter: currentSelection,
            touched: safe,
            at: historyClock(),
            coalescing: false
        )
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
            // Inline-code carry-forward is gated on the cursor sitting
            // strictly inside an existing code span — the chars on both
            // sides must already be tagged. Typing at the trailing edge
            // (after `code` but before the next char) doesn't extend the
            // span, matching PM's non-inclusive `code` mark behavior.
            if isInsideCodeSpan(at: location) {
                attrs[.proseInline] = InlineTag.codeSpan
            }
        }
        if let anchor = storedMarksAnchor, anchor == location, !storedInlineMarks.isEmpty {
            attrs = applyingStoredMarks(to: attrs)
        } else if !storedInlineMarks.isEmpty {
            clearStoredInlineMarks()
        }
        applyTypingAttributes(attrs)
    }

    private func isInsideCodeSpan(at location: Int) -> Bool {
        let total = textStorage.length
        guard total > 0, location > 0, location < total else { return false }
        let before = textStorage.safeAttribute(.proseInline, at: location - 1) as? InlineTag
        let after = textStorage.safeAttribute(.proseInline, at: location) as? InlineTag
        return before == .codeSpan && after == .codeSpan
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
        // The canonical store as well as the rendering one. Projecting only
        // fonts left typed characters serializing as bold — `markdown()`
        // re-derives from the font — while `storage.markSet(at:)` saw plain
        // text. `adding(_:in:)` applies the schema's excludes.
        var marks = (base[.proseMarks] as? MarkSetBox)?.marks ?? MarkSet()
        for stored in storedInlineMarks {
            marks = marks.adding(ProseMark(type: stored.markName), in: Schema.defaultMarkdown)
        }
        attrs[.proseMarks] = MarkSetBox(marks)
        return attrs
    }


    @discardableResult
    public func toggleCheckbox(at location: Int) -> Bool {
        guard isEditable || allowsCheckboxToggle else { return false }
        drainPendingEnvelopes()
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

    /// Move the cursor out of the current code block. If the block is empty,
    /// remove it entirely. If non-empty, insert a fresh paragraph after it
    /// and place the cursor there. Returns false when the cursor isn't in
    /// a code block. Wired to `Mod-Enter` (PM convention) by the host.
    @discardableResult
    public func exitCodeBlock() -> Bool {
        drainPendingEnvelopes()
        let total = textStorage.length
        guard total > 0 else { return false }
        let cursor = currentSelection.location
        let probe = max(0, min(cursor, total - 1))
        guard textStorage.blockSpec(at: probe)?.isCodeBlock == true else {
            return false
        }
        var blockStart = probe
        while blockStart > 0,
              textStorage.blockSpec(at: blockStart - 1)?.isCodeBlock == true {
            blockStart -= 1
        }
        var blockEnd = probe
        while blockEnd < total,
              textStorage.blockSpec(at: blockEnd)?.isCodeBlock == true {
            blockEnd += 1
        }
        let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
        let bodyText = (textStorage.string as NSString).substring(with: blockRange)
        let isEmpty = bodyText
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
            .isEmpty

        let plainAttrs = theme.plainParagraphAttributes()
        let blank = NSAttributedString(string: "\n", attributes: plainAttrs)
        let mutationRange: NSRange
        let landing: Int
        if isEmpty {
            mutationRange = blockRange
            landing = blockStart
        } else {
            mutationRange = NSRange(location: blockEnd, length: 0)
            landing = blockEnd
        }
        withCharacterMutation(range: mutationRange) {
            proseStorage.withOrigin(.transaction) {
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: mutationRange, with: blank)
                textStorage.endEditing()
            }
            scheduleCodeBlockRehighlight()
            intrinsicSizeInvalidator?()
        }
        let landingRange = NSRange(location: landing, length: 0)
        installSelection(landingRange)
        applyTypingAttributes(plainAttrs)
        return true
    }

    @discardableResult
    public func handleNewline() -> Bool {
        drainPendingEnvelopes()
        if handleNewlineAtIsolatingBlock() { return true }
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
                    proseStorage.withOrigin(.transaction) {
                        resulting = InsertNewline.handle(
                            in: textStorage,
                            cursor: cursor,
                            compiler: compiler,
                            serializer: serializer,
                            theme: theme
                        )
                    }
                    scheduleCodeBlockRehighlight()
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
            let plainAttrs = theme.plainParagraphAttributes()
            let blank = NSAttributedString(string: "\n", attributes: plainAttrs)
            withCharacterMutation(range: lineRange) {
                proseStorage.withOrigin(.transaction) {
                    textStorage.beginEditing()
                    textStorage.replaceCharacters(in: lineRange, with: blank)
                    textStorage.endEditing()
                }
                scheduleCodeBlockRehighlight()
                intrinsicSizeInvalidator?()
            }
            applyTypingAttributes(plainAttrs)
            return NSRange(location: lineRange.location, length: 0)
        }
        // Continuation: append a fresh empty blockquote line after this one.
        // The demotion pass is skipped for it — the line is empty by
        // construction, and "an empty styled line goes back to plain" would
        // strip the quote depth this just wrote.
        let nextLine = compiler.makeBlockquoteLine(depth: depth, theme: theme)
        let insertLocation = lineRange.location + lineRange.length
        withCharacterMutation(
            range: NSRange(location: insertLocation, length: 0),
            demoteEmptyLines: false
        ) {
            proseStorage.withOrigin(.transaction) {
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: NSRange(location: insertLocation, length: 0), with: nextLine)
                textStorage.endEditing()
            }
            scheduleCodeBlockRehighlight()
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
            proseStorage.withOrigin(.transaction) {
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: lineRange, with: blank)
                textStorage.endEditing()
            }
            scheduleCodeBlockRehighlight()
            intrinsicSizeInvalidator?()
        }
        applyTypingAttributes(plainAttrs)
        return NSRange(location: lineRange.location, length: 0)
    }

    @discardableResult
    public func handleBackspace() -> Bool {
        drainPendingEnvelopes()
        // PM convention: Backspace right after an input rule fired undoes
        // the rule rather than deleting a character.
        if undoInputRule() { return true }
        let selection = currentSelection
        guard selection.length == 0 else { return false }
        let cursor = selection.location
        let total = textStorage.length
        guard total > 0, cursor >= 0, cursor <= total else { return false }
        if deleteEmptyCodeBlockAtCursor(cursor: cursor) { return true }
        // List-item demotion needs the char before the cursor; skip when
        // the cursor is at the start of the document.
        guard cursor > 0 else { return false }
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
            proseStorage.withOrigin(.transaction) {
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: markerRange, with: "")
                let demoteRange = NSRange(location: lineRange.location, length: bodyRange.length)
                if demoteRange.length > 0 {
                    textStorage.setAttributes(plainAttrs, range: demoteRange)
                }
                textStorage.endEditing()
            }
            scheduleCodeBlockRehighlight()
        }
        setHostSelection(NSRange(location: lineRange.location, length: 0))
        applyTypingAttributes(plainAttrs)
        return true
    }

    /// Forward-delete inside an empty code block: drop the whole block in
    /// one keystroke instead of leaving a zero-length code-leaf carcass.
    /// Wired to the host's `deleteForward:` command.
    @discardableResult
    public func handleForwardDelete() -> Bool {
        drainPendingEnvelopes()
        let selection = currentSelection
        guard selection.length == 0 else { return false }
        return deleteEmptyCodeBlockAtCursor(cursor: selection.location)
    }

    /// Backspace or forward-delete inside an empty code block: drop the
    /// whole block. Mirrors ProseMirror's `selectNodeBackward` for atomic
    /// blocks. Returns `true` when handled so the host text view skips its
    /// default delete.
    private func deleteEmptyCodeBlockAtCursor(cursor: Int) -> Bool {
        let total = textStorage.length
        guard cursor < total,
              textStorage.blockSpec(at: cursor)?.isCodeBlock == true else {
            return false
        }
        var blockStart = cursor
        while blockStart > 0,
              textStorage.blockSpec(at: blockStart - 1)?.isCodeBlock == true {
            blockStart -= 1
        }
        var blockEnd = cursor
        while blockEnd < total,
              textStorage.blockSpec(at: blockEnd)?.isCodeBlock == true {
            blockEnd += 1
        }
        guard cursor == blockStart else { return false }
        let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
        let bodyText = (textStorage.string as NSString).substring(with: blockRange)
        let isEmpty = bodyText
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
        guard isEmpty else { return false }
        withCharacterMutation(range: blockRange) {
            proseStorage.withOrigin(.transaction) {
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: blockRange, with: "")
                textStorage.endEditing()
            }
            scheduleCodeBlockRehighlight()
            intrinsicSizeInvalidator?()
        }
        setHostSelection(NSRange(location: blockStart, length: 0))
        applyTypingAttributes(theme.plainParagraphAttributes())
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

    // MARK: - private

    private func compileFor(_ markdown: String) -> NSAttributedString {
        return compiler.compile(markdown, theme: theme)
    }

    /// Invalidate the storage range hosting a specific table
    /// attachment so TextKit 2 re-queries its `attachmentBounds` —
    /// fired by `TableAttachmentViewProvider` whenever the realized
    /// `TableBlockView` reports a new intrinsic size after a cell edit
    /// or structural mutation.
    ///
    /// In `.fitsContent` mode `intrinsicSizeInvalidator` triggers the
    /// host's layout pipeline to re-read `usageBoundsForTextContainer`.
    /// In `.fillContainer` mode no invalidator is wired, so this method
    /// also calls `ensureLayout` on the document range and nudges the
    /// host text view directly — without that, the line fragment
    /// hosting the table keeps its old height and the scroll view's
    /// content size never widens to fit the taller table.
    private func propagateIsEditableToTables() {
        guard textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(
            NSAttributedString.Key("NSAttachment"),
            in: fullRange
        ) { value, _, _ in
            guard let att = value as? ProseNodeAttachment,
                  let view = att.boundView else { return }
            view.isEditable = self.isEditable
        }
    }

    func invalidateTableAttachmentLayout(_ attachment: ProseNodeAttachment) {
        guard textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var hits: [NSRange] = []
        textStorage.enumerateAttribute(
            NSAttributedString.Key("NSAttachment"),
            in: fullRange
        ) { value, range, _ in
            guard let att = value as? ProseNodeAttachment, att === attachment else { return }
            hits.append(range)
        }
        guard !hits.isEmpty else { return }
        let docStart = contentStorage.documentRange.location
        for range in hits {
            guard let start = contentStorage.location(docStart, offsetBy: range.location),
                  let end = contentStorage.location(docStart, offsetBy: range.location + range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            layoutManager.invalidateLayout(for: textRange)
        }
        // Force the layout manager to re-run the invalidated fragment
        // synchronously so `attachmentBounds` is queried with the
        // attachment's new subtree before any caller reads
        // `usageBoundsForTextContainer`.
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        intrinsicSizeInvalidator?()
        // `.fillContainer` mode never wires `intrinsicSizeInvalidator`,
        // and even in `.fitsContent` mode the text view's frame doesn't
        // re-read the new `usageBoundsForTextContainer` until a layout
        // pass kicks off. Mark the host as needing layout / display so
        // the scroll view (or intrinsic-size driven container) reflows
        // around the taller table on the next runloop tick.
        #if canImport(AppKit) && os(macOS)
        if let tv = hostTextView as? NSTextView {
            tv.needsLayout = true
            tv.needsDisplay = true
            // In `.fillContainer` (NSScrollView), NSTextView's auto-
            // resize fires on character edits. Our attribute-only
            // attachment mutation doesn't trigger it, so the text view
            // keeps its old frame and the scroll view never widens to
            // expose the taller table. Push the frame up to the layout
            // manager's reported usage now.
            let used = layoutManager.usageBoundsForTextContainer
            let inset = tv.textContainerInset
            let neededHeight = used.height + inset.height * 2
            if tv.frame.height < neededHeight - 0.5 {
                var newFrame = tv.frame
                newFrame.size.height = neededHeight
                tv.frame = newFrame
            }
        }
        #else
        if let tv = hostTextView as? UITextView {
            tv.setNeedsLayout()
            tv.setNeedsDisplay()
            // UITextView caches contentSize from its layout; nudge it
            // when the layout grew but no character edit fired.
            let used = layoutManager.usageBoundsForTextContainer
            let inset = tv.textContainerInset
            let neededHeight = used.height + inset.top + inset.bottom
            if tv.contentSize.height < neededHeight - 0.5 {
                tv.contentSize = CGSize(
                    width: tv.contentSize.width,
                    height: neededHeight
                )
            }
        }
        #endif
    }

    /// Invalidate layout for every range that hosts a table attachment
    /// so TextKit 2 re-queries `attachmentBounds` against the current
    /// container width. The host text view calls this from
    /// `sizeThatFits` on resize.
    public func scheduleTableHeightStamp(containerWidth: CGFloat) {
        guard textStorage.length > 0 else { return }
        var ranges: [NSTextRange] = []
        textStorage.enumerateNodePaths { runRange, path in
            guard path.leaf?.type == "table" else { return }
            let docStart = contentStorage.documentRange.location
            guard let start = contentStorage.location(docStart, offsetBy: runRange.location),
                  let end = contentStorage.location(docStart, offsetBy: runRange.location + runRange.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            ranges.append(textRange)
        }
        for range in ranges {
            layoutManager.invalidateLayout(for: range)
        }
    }

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
        let priorSelection = currentSelection
        proseStorage.withOrigin(.load) {
            let total = NSRange(location: 0, length: textStorage.length)
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: total, with: attributed)
            textStorage.endEditing()
        }
        ensureTrailingParagraph()
        scheduleCodeBlockRehighlight()
        // Replacing all characters resets the host text view's caret to the
        // document end; restore the prior offset (clamped) so an external
        // setMarkdown / recompile / theme change doesn't move the cursor.
        setHostSelection(priorSelection)
        refreshTypingAttributes(at: priorSelection.clamped(to: textStorage.length).location)
    }

    /// Append an empty paragraph after the last block when that block is
    /// atomic (code, hr, table, html, link reference), giving tap/click and
    /// keyboard navigation a paragraph to land in. Empty paragraphs don't
    /// materialize in markdown serialization, so the invariant has no
    /// round-trip cost.
    private func ensureTrailingParagraph() {
        let total = textStorage.length
        guard total > 0 else { return }
        guard let path = textStorage.nodePath(at: total - 1) else { return }
        let isAtomic: Bool
        if let leaf = path.leaf,
           ["code_block", "horizontal_rule", "html_block", "link_reference"].contains(leaf.type) {
            isAtomic = true
        } else {
            isAtomic = path.nodes.contains { $0.type == "table" }
        }
        guard isAtomic else { return }
        let plainAttrs = theme.plainParagraphAttributes()
        let blank = NSAttributedString(string: "\n", attributes: plainAttrs)
        proseStorage.withOrigin(.normalize, capturing: true) {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: total, length: 0), with: blank)
            textStorage.endEditing()
        }
    }

    /// Union the freshly-edited range into `pendingHighlightRange` so the
    /// next rehighlight pass knows which code blocks to re-color.
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

    /// Re-stamp syntax-highlight colors on every code block overlapping
    /// `range`.
    ///
    /// The fence run comes from storage, not from a cached segment list:
    /// the compiler stamps one `code_block` node across a whole fence, so
    /// walking `proseNodePath` runs by node identity recovers the full
    /// fence-body-fence span the highlighter needs. Recompile-free — the
    /// parser doesn't run, only the colors refresh.
    private func rehighlightCodeBlocks(intersecting range: NSRange) {
        let total = textStorage.length
        guard total > 0 else { return }
        let safe = range.clamped(to: total)
        let ns = textStorage.string as NSString
        let anchor = min(max(0, safe.location), total - 1)
        let scan = ns.paragraphRange(
            for: NSRange(location: anchor, length: min(safe.length, total - anchor))
        )
        var cursor = scan.location
        let end = scan.location + scan.length
        var done: Set<NodeID> = []
        while cursor < end, cursor < textStorage.length {
            guard let path = textStorage.nodePath(at: cursor),
                  let leaf = path.leaf,
                  leaf.type == "code_block" else {
                let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
                cursor = line.length > 0 ? line.location + line.length : cursor + 1
                continue
            }
            guard !done.contains(leaf.id) else {
                cursor += 1
                continue
            }
            done.insert(leaf.id)
            let block = codeBlockRange(ofNode: leaf.id, containing: cursor)
            guard block.length > 0 else { cursor += 1; continue }
            let spec = textStorage.blockSpec(at: block.location)
            let language: String?
            let isFenced: Bool
            if case .fencedCode(let lang) = spec?.kind {
                language = lang
                isFenced = true
            } else {
                language = nil
                isFenced = false
            }
            rehighlightProbe?(block)
            proseStorage.withOrigin(.normalize) {
                compiler.rehighlightCodeBlock(
                    in: textStorage,
                    blockRange: block,
                    language: language,
                    isFenced: isFenced,
                    theme: theme
                )
            }
            cursor = block.location + block.length
        }
    }

    /// Full storage span of the `code_block` node with `id`, found by
    /// walking `proseNodePath` runs out from `location` while the leaf
    /// node id matches.
    private func codeBlockRange(ofNode id: NodeID, containing location: Int) -> NSRange {
        let total = textStorage.length
        var start = location
        var end = location
        var probe = NSRange(location: 0, length: 0)
        _ = textStorage.safeAttribute(
            .proseNodePath,
            at: location,
            longestEffectiveRange: &probe,
            in: NSRange(location: 0, length: total)
        )
        start = probe.location
        end = probe.location + probe.length
        while start > 0, textStorage.nodePath(at: start - 1)?.leaf?.id == id {
            var back = NSRange(location: 0, length: 0)
            _ = textStorage.safeAttribute(
                .proseNodePath,
                at: start - 1,
                longestEffectiveRange: &back,
                in: NSRange(location: 0, length: total)
            )
            start = back.location
        }
        while end < total, textStorage.nodePath(at: end)?.leaf?.id == id {
            var forward = NSRange(location: 0, length: 0)
            _ = textStorage.safeAttribute(
                .proseNodePath,
                at: end,
                longestEffectiveRange: &forward,
                in: NSRange(location: 0, length: total)
            )
            end = forward.location + forward.length
        }
        return NSRange(location: start, length: max(0, end - start))
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
