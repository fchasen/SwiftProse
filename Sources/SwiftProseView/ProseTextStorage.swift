import Foundation
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Who is mutating the storage.
///
/// Every write to the buffer belongs to exactly one of these. `.platform`
/// is the default — anything the text view (or a host writing storage
/// directly) does on the user's behalf. The rest are scopes the controller
/// opens around its own writes so the drain can tell a keystroke from a
/// transaction from a normalization pass.
enum EditOrigin: Sendable, Equatable {
    /// The text view, the input system, or a host writing storage directly.
    case platform
    /// Inside `Transaction.apply` or `EditorController.applyCore`.
    case transaction
    /// Undo / redo replay.
    case history
    /// Post-edit repair the controller runs on its own edits — attribute
    /// scrubbing, the trailing paragraph, code-block rehighlighting.
    case normalize
    /// Whole-document load: initial compile, `setMarkdown`, `replaceStorage`.
    case load
}

/// How the platform described the edit it is about to make. Stamped by the
/// text-view delegates before they return `true`, read once when the first
/// capture of a group lands.
enum EditHint: Sendable, Equatable {
    case typing
    case deletion
    case correction
    case bulk
    case composition
    case attributeOnly
}

/// State captured at the first mutation of a platform edit group, before
/// the text view has moved the caret or updated its typing attributes.
struct CaptureContext: Sendable {
    var selectionBefore: NSRange
    var markedTextActive: Bool
    var hint: EditHint?
    var timestamp: TimeInterval

    init(
        selectionBefore: NSRange,
        markedTextActive: Bool,
        hint: EditHint?,
        timestamp: TimeInterval
    ) {
        self.selectionBefore = selectionBefore
        self.markedTextActive = markedTextActive
        self.hint = hint
        self.timestamp = timestamp
    }
}

/// One primitive mutation, with the content it displaced. A single platform
/// edit group can produce several — a drag-move is a delete plus an insert
/// inside one `beginEditing`/`endEditing` bracket.
struct EditCapture {
    enum Kind: Equatable {
        case characters(insertedLength: Int)
        case attributes
    }

    let kind: Kind
    /// Range in the **pre-edit** buffer that this mutation replaced.
    let range: NSRange
    /// Exactly what was there before, attributes included. This is the
    /// inverse; nothing else needs reconstructing.
    let preImage: NSAttributedString

    init(kind: Kind, range: NSRange, preImage: NSAttributedString) {
        self.kind = kind
        self.range = range
        self.preImage = preImage
    }
}

/// Everything one `processEditing` pass knows about the edit that produced
/// it. Handed to `editObserver` after `super.processEditing()` has run.
struct EditRecord {
    let origin: EditOrigin
    let editedMask: PlatformTextStorageEditActions
    /// Post-edit union of everything the group touched, snapshotted before
    /// `super.processEditing()` clears it.
    let editedRange: NSRange
    let changeInLength: Int
    let captures: [EditCapture]
    let context: CaptureContext?

    var isCharacterEdit: Bool { editedMask.contains(.editedCharacters) }
}

/// `NSTextStorage` subclass that records what every mutation displaced.
///
/// Two things it adds over the concrete class:
///
/// - **Capture.** Before forwarding a platform mutation to the backing
///   store it snapshots the range's pre-image. That snapshot *is* the
///   inverse of the edit, so typing becomes undoable through the same
///   typed-`Step` path as a command instead of a separate text-snapshot
///   mechanism.
/// - **Origin.** `withOrigin(_:)` brackets the controller's own writes so
///   the drain can tell a keystroke from a transaction, an undo replay, or
///   a normalization pass. Replaces the single boolean flag the
///   controller used to carry for this.
///
/// Attribute fixing runs inside `super.processEditing()` and calls the
/// `setAttributes` primitive; captures are suppressed for the duration.
final class ProseTextStorage: NSTextStorage {

    /// The concrete `NSTextStorage`, used purely as a store.
    ///
    /// Not `NSMutableAttributedString`: that class's `replaceCharacters` is
    /// linear in the number of attribute runs, which on a syntax-highlighted
    /// 3000-line code fence costs ~250 us per keystroke and gets worse as
    /// the document grows. `NSTextStorage`'s run storage is the one Apple
    /// tuned for exactly this. Its `string` is also the live buffer rather
    /// than an O(n) copy.
    private let backing = NSTextStorage()

    /// Cached bridge of the backing store's characters. Invalidated on
    /// every character edit.
    private var cachedString: String?

    private var originStack: [(origin: EditOrigin, capturing: Bool)] = []
    private var pendingCaptures: [EditCapture] = []
    private var pendingContext: CaptureContext?
    private var inProcessEditing = 0

    /// Nesting depth of `beginEditing` / `endEditing`.
    private var editingDepth = 0
    /// Records built by `processEditing` and waiting to be handed to
    /// `editObserver` once it is safe to mutate again.
    private var queuedRecords: [EditRecord] = []
    private var isFlushing = false

    /// Asked for the platform state at the first capture of a group:
    /// the pre-edit selection, whether the input system has marked text,
    /// and the delegate's hint. Consumed here rather than at drain because
    /// a drag-move produces two captures before anything drains.
    var captureContextProvider: (() -> CaptureContext)?

    /// Called once per edit group, after the outermost mutation has fully
    /// unwound. Deliberately *not* called from inside `processEditing`:
    /// `NSTextStorage` folds mutations made during that pass into it
    /// instead of starting a new one, so an observer that edits from there
    /// would get no record of its own and would leak its captures into the
    /// next unrelated edit.
    var editObserver: ((EditRecord) -> Void)?

    /// The record for the pass currently running, readable from inside the
    /// `didProcessEditingNotification` that `super.processEditing()` posts.
    private(set) var currentRecord: EditRecord?

    /// Innermost open origin scope.
    var currentOrigin: EditOrigin { originStack.last?.origin ?? .platform }

    /// Outermost open origin scope — who owns the edit group as a whole.
    var recordOrigin: EditOrigin { originStack.first?.origin ?? .platform }

    /// Run `body` with storage writes attributed to `origin`.
    ///
    /// `capturing: true` keeps the capture hook live inside the scope, so a
    /// normalization pass that runs during an envelope's close appends its
    /// own inverse to the same envelope — undoing the keystroke also undoes
    /// the normalization it triggered.
    @discardableResult
    func withOrigin<T>(
        _ origin: EditOrigin,
        capturing: Bool = false,
        _ body: () throws -> T
    ) rethrows -> T {
        originStack.append((origin, capturing))
        defer { originStack.removeLast() }
        return try body()
    }

    // MARK: - NSTextStorage primitives

    /// The live characters, matching `NSTextStorage`'s own contract:
    /// callers must not hold the result across an edit.
    override var string: String {
        if let cachedString { return cachedString }
        let s = backing.string
        cachedString = s
        return s
    }

    override var length: Int { backing.length }

    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    /// Read-only view of the buffer for whole-document walks.
    ///
    /// Identical content to `self` — it *is* the store. Enumerating through
    /// the overrides above costs an ObjC hop per call, which is invisible
    /// per keystroke but not on paths that touch every character
    /// (`ProseDocument.from` does two attribute lookups per character, so
    /// 76 KB of text is 150k forwarded calls). Read-only: never mutate
    /// through this.
    var contents: NSAttributedString { backing }

    // MARK: - read paths
    //
    // `NSAttributedString` implements these on top of the
    // `attributes(at:effectiveRange:)` primitive. Going through the
    // primitive costs a bridged Swift dictionary per run, which shows up
    // as a 6-10x regression on `enumerateNodePaths` / `ProseDocument.from`
    // / `enumerateBlockSpecs`. Forwarding straight to the backing store
    // keeps `NSMutableAttributedString`'s native run-walking.

    override func attribute(
        _ attrName: NSAttributedString.Key,
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> Any? {
        backing.attribute(attrName, at: location, effectiveRange: range)
    }

    /// Pull an out-of-process `(index, rangeLimit)` pair into the live
    /// buffer. AppKit reads here from inside its own editing transaction,
    /// with a selection it has not collapsed yet, so the pair can overhang
    /// an edit that already shrank storage. Clamp the limit first, then pull
    /// the index into it: the head of AppKit's range is still valid, so the
    /// answer stays truthful instead of blank, and the effective range
    /// written back is a real run — a fabricated one that doesn't contain
    /// the index corrupts the caller's scan cursor.
    private func clampedProbe(_ location: Int, _ rangeLimit: NSRange) -> (Int, NSRange)? {
        let total = backing.length
        guard total > 0 else { return nil }
        var limit = rangeLimit.clamped(to: total)
        if limit.length == 0 { limit = NSRange(location: total - 1, length: 1) }
        let loc = min(max(location, limit.location), limit.location + limit.length - 1)
        return (loc, limit)
    }

    override func attribute(
        _ attrName: NSAttributedString.Key,
        at location: Int,
        longestEffectiveRange range: NSRangePointer?,
        in rangeLimit: NSRange
    ) -> Any? {
        guard let (loc, limit) = clampedProbe(location, rangeLimit) else {
            range?.pointee = NSRange(location: 0, length: 0)
            return nil
        }
        return backing.attribute(attrName, at: loc, longestEffectiveRange: range, in: limit)
    }

    override func attributes(
        at location: Int,
        longestEffectiveRange range: NSRangePointer?,
        in rangeLimit: NSRange
    ) -> [NSAttributedString.Key: Any] {
        guard let (loc, limit) = clampedProbe(location, rangeLimit) else {
            range?.pointee = NSRange(location: 0, length: 0)
            return [:]
        }
        return backing.attributes(at: loc, longestEffectiveRange: range, in: limit)
    }

    override func enumerateAttribute(
        _ attrName: NSAttributedString.Key,
        in enumerationRange: NSRange,
        options opts: NSAttributedString.EnumerationOptions = [],
        using block: (Any?, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        // AppKit's `fallbackFontInfoForSelectedRange:` reaches here with the
        // same uncollapsed selection `clampedProbe` guards against.
        let range = enumerationRange.clamped(to: backing.length)
        backing.enumerateAttribute(attrName, in: range, options: opts, using: block)
    }

    override func enumerateAttributes(
        in enumerationRange: NSRange,
        options opts: NSAttributedString.EnumerationOptions = [],
        using block: ([NSAttributedString.Key: Any], NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        backing.enumerateAttributes(in: enumerationRange, options: opts, using: block)
    }

    override func attributedSubstring(from range: NSRange) -> NSAttributedString {
        backing.attributedSubstring(from: range)
    }

    override func isEqual(to other: NSAttributedString) -> Bool {
        backing.isEqual(to: other)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        capture(.characters(insertedLength: (str as NSString).length), replacing: range)
        cachedString = nil
        backing.replaceCharacters(in: range, with: str)
        edited(
            .editedCharacters,
            range: range,
            changeInLength: (str as NSString).length - range.length
        )
        flushRecordsIfSettled()
    }

    /// One capture and one `edited(_:)` for an attributed replacement. The
    /// inherited implementation would decompose into a string replacement
    /// plus a `setAttributes` per run, each of which the capture hook would
    /// record separately.
    override func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        capture(.characters(insertedLength: attrString.length), replacing: range)
        cachedString = nil
        backing.replaceCharacters(in: range, with: attrString)
        edited(
            [.editedCharacters, .editedAttributes],
            range: range,
            changeInLength: attrString.length - range.length
        )
        flushRecordsIfSettled()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        capture(.attributes, replacing: range)
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        flushRecordsIfSettled()
    }

    override func addAttribute(_ name: NSAttributedString.Key, value: Any, range: NSRange) {
        capture(.attributes, replacing: range)
        backing.addAttribute(name, value: value, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        flushRecordsIfSettled()
    }

    override func addAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange) {
        capture(.attributes, replacing: range)
        backing.addAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        flushRecordsIfSettled()
    }

    override func removeAttribute(_ name: NSAttributedString.Key, range: NSRange) {
        capture(.attributes, replacing: range)
        backing.removeAttribute(name, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        flushRecordsIfSettled()
    }

    /// Fix attributes on demand rather than inside every `processEditing`.
    ///
    /// The concrete `NSTextStorage` is lazy here and a subclass is not by
    /// default. Eager fixing costs an O(document) string materialization on
    /// every keystroke (measured 150x on a 169 KB fixture) because
    /// `fixParagraphStyleAttribute` reads `string` to find paragraph
    /// bounds. TextKit calls `ensureAttributesAreFixed(in:)` before it
    /// lays anything out, which is early enough.
    override var fixesAttributesLazily: Bool { false }

    /// Union of every range edited since the last fix. Kept as one range
    /// rather than a list so a headless controller — which never gets an
    /// `ensureAttributesAreFixed` call from a layout manager — doesn't
    /// accumulate one entry per keystroke.
    private var unfixedRange: NSRange?

    override func ensureAttributesAreFixed(in range: NSRange) {
        guard let pending = unfixedRange else { return }
        unfixedRange = nil
        let safe = pending.clamped(to: backing.length)
        guard safe.length > 0 else { return }
        inProcessEditing += 1
        fixAttributes(in: safe)
        inProcessEditing -= 1
    }

    private func markUnfixed(_ range: NSRange) {
        guard range.length > 0 else { return }
        guard let existing = unfixedRange else {
            unfixedRange = range
            return
        }
        let lo = min(existing.location, range.location)
        let hi = max(existing.location + existing.length, range.location + range.length)
        unfixedRange = NSRange(location: lo, length: hi - lo)
    }

    override func processEditing() {
        let record = EditRecord(
            origin: recordOrigin,
            editedMask: editedMask,
            editedRange: editedRange,
            changeInLength: changeInLength,
            captures: pendingCaptures,
            context: pendingContext
        )
        pendingCaptures.removeAll(keepingCapacity: true)
        pendingContext = nil

        #if DEBUG
        if record.origin == .platform,
           record.isCharacterEdit,
           record.captures.isEmpty,
           record.editedRange.length > 0 || record.changeInLength != 0 {
            assertionFailure(
                "platform character edit reached processEditing with no capture — "
                + "a mutation bypassed the ProseTextStorage primitives"
            )
        }
        #endif

        markUnfixed(record.editedRange)
        currentRecord = record
        inProcessEditing += 1
        super.processEditing()
        inProcessEditing -= 1
        currentRecord = nil

        queuedRecords.append(record)
    }

    override func beginEditing() {
        editingDepth += 1
        super.beginEditing()
    }

    override func endEditing() {
        super.endEditing()
        editingDepth = max(0, editingDepth - 1)
        flushRecordsIfSettled()
    }

    /// Hand queued records to the observer once no mutation is in flight.
    /// Re-entrant by design: the observer normalizes, which produces more
    /// records, which the same loop picks up.
    private func flushRecordsIfSettled() {
        guard editingDepth == 0, inProcessEditing == 0 else { return }
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while !queuedRecords.isEmpty {
            let record = queuedRecords.removeFirst()
            editObserver?(record)
        }
    }

    // MARK: - capture

    /// True when a mutation should be recorded: platform writes always, and
    /// controller writes only inside a `capturing: true` scope. Attribute
    /// fixing inside `super.processEditing()` never captures.
    private var shouldCapture: Bool {
        guard inProcessEditing == 0 else { return false }
        guard let top = originStack.last else { return true }
        return top.origin == .platform || top.capturing
    }

    private func capture(_ kind: EditCapture.Kind, replacing range: NSRange) {
        guard shouldCapture else { return }
        let safe = range.clamped(to: backing.length)
        if pendingCaptures.isEmpty, pendingContext == nil {
            pendingContext = captureContextProvider?()
        }
        pendingCaptures.append(EditCapture(
            kind: kind,
            range: safe,
            preImage: backing.attributedSubstring(from: safe)
        ))
    }
}
