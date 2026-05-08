import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A trigger that opens a completion session when typed at the cursor.
public struct CompletionTrigger: Equatable, Sendable {
    /// Stable identifier. Embedders look this up in `CompletionContext.triggerID`
    /// to decide what items to fetch.
    public let id: String
    /// The character that opens the session (e.g. "@", "#", "/").
    public let prefix: Character
    /// Honor the trigger inside fenced code blocks / inline-code spans?
    /// Defaults to false — code is rarely a place users want suggestions.
    public let allowedInCode: Bool

    public init(id: String, prefix: Character, allowedInCode: Bool = false) {
        self.id = id
        self.prefix = prefix
        self.allowedInCode = allowedInCode
    }
}

/// Snapshot of an open completion session — what the host renders against.
public struct CompletionContext: Equatable, Sendable {
    /// Matches `CompletionTrigger.id`.
    public let triggerID: String
    /// Text typed after the prefix (without the prefix itself).
    public let query: String
    /// Storage range covering the prefix + query. Use as the replacement
    /// range when committing a selection.
    public let range: NSRange
    /// Caret rect in the host text view's coordinate space at session
    /// open. Re-read via `EditorController.caretRect()` for live updates.
    public let caretRect: CGRect?

    public init(triggerID: String, query: String, range: NSRange, caretRect: CGRect?) {
        self.triggerID = triggerID
        self.query = query
        self.range = range
        self.caretRect = caretRect
    }
}

/// State carried while a completion session is open.
public struct CompletionSession: Equatable, Sendable {
    public var context: CompletionContext
    public var highlightedIndex: Int
    public var itemCount: Int

    public init(context: CompletionContext, highlightedIndex: Int = 0, itemCount: Int = 0) {
        self.context = context
        self.highlightedIndex = highlightedIndex
        self.itemCount = itemCount
    }
}

/// Plugin that watches typing for trigger characters and surfaces a
/// completion session. Hosts read the active session via
/// `session(controller:)` and call `commit(controller:)` / `cancel(controller:)`
/// to drive the lifecycle. After registering, call `attach(to:)` so the
/// plugin can observe document changes (backspace, paste) it can't
/// otherwise see.
public final class CompletionPlugin: EditorPlugin {
    public static let stateKey = PluginKey<CompletionSession>(name: "swiftprose.completion")
    public let key = AnyPluginKey(name: "swiftprose.completion")

    public let triggers: [CompletionTrigger]

    /// Fired whenever the plugin's session opens, mutates, or closes.
    /// Hosts subscribe to drive their UI.
    public var onSessionChanged: ((CompletionSession?) -> Void)?

    /// Called when the plugin decides the user committed a selection
    /// (Enter / Tab). Hosts inspect the session and apply a transaction.
    public var onCommit: ((EditorController, CompletionSession) -> Void)?

    private var documentObserver: EditorController.ObserverToken?
    private weak var attachedController: EditorController?

    public init(triggers: [CompletionTrigger]) {
        self.triggers = triggers
    }

    deinit {
        if let observer = documentObserver {
            attachedController?.removeObserver(observer)
        }
    }

    /// Subscribe the plugin to the controller's document-change events.
    /// Required for the session to close on backspace / paste / external
    /// edits. Idempotent across re-attach.
    public func attach(to controller: EditorController) {
        if let observer = documentObserver, attachedController === controller { return }
        if let observer = documentObserver, let prior = attachedController {
            prior.removeObserver(observer)
        }
        attachedController = controller
        documentObserver = controller.addOnDocumentChange { [weak self, weak controller] _, _ in
            guard let self, let controller else { return }
            self.refresh(controller: controller)
        }
    }

    public var props: PluginProps {
        PluginProps(
            handleKeyDown: { [weak self] controller, key in
                self?.handleKey(controller: controller, key: key) ?? false
            },
            handleTextInput: { [weak self] controller, range, text in
                self?.handleTextInput(controller: controller, range: range, text: text) ?? false
            }
        )
    }

    // MARK: - Public surface

    public func session(controller: EditorController) -> CompletionSession? {
        currentSession(controller)
    }

    public func updateHighlight(_ index: Int, controller: EditorController) {
        guard var session = currentSession(controller) else { return }
        let clamped = max(0, min(index, max(0, session.itemCount - 1)))
        guard clamped != session.highlightedIndex else { return }
        session.highlightedIndex = clamped
        store(session, controller: controller)
    }

    public func updateItemCount(_ count: Int, controller: EditorController) {
        guard var session = currentSession(controller) else { return }
        session.itemCount = max(0, count)
        if session.highlightedIndex >= session.itemCount {
            session.highlightedIndex = max(0, session.itemCount - 1)
        }
        store(session, controller: controller)
    }

    public func commit(controller: EditorController) {
        guard let session = currentSession(controller) else { return }
        onCommit?(controller, session)
        clear(controller: controller)
    }

    public func cancel(controller: EditorController) {
        guard currentSession(controller) != nil else { return }
        clear(controller: controller)
    }

    /// Re-derive the session from current storage. Closes when the
    /// anchor character is gone or whitespace appears in the query span.
    public func refresh(controller: EditorController) {
        guard let session = currentSession(controller) else { return }
        deriveSession(from: session, controller: controller)
    }

    // MARK: - Internals

    private func handleKey(controller: EditorController, key: String) -> Bool {
        guard let session = currentSession(controller) else { return false }
        switch key {
        case "Escape":
            cancel(controller: controller)
            return true
        case "ArrowDown":
            updateHighlight(session.highlightedIndex + 1, controller: controller)
            return true
        case "ArrowUp":
            updateHighlight(session.highlightedIndex - 1, controller: controller)
            return true
        case "Enter", "Tab":
            guard session.itemCount > 0 else {
                cancel(controller: controller)
                return false
            }
            commit(controller: controller)
            return true
        default:
            return false
        }
    }

    private func handleTextInput(
        controller: EditorController,
        range: NSRange,
        text: String
    ) -> Bool {
        // Existing session: predict the next state given the upcoming
        // text. The character hasn't been inserted yet (we return false),
        // but we know the cursor will land at range.location + text.count.
        if let existing = currentSession(controller) {
            extendOrCloseSession(existing, range: range, text: text, controller: controller)
            return false
        }
        // No open session — see if this opens one.
        if text.count == 1,
           let ch = text.first,
           let trigger = triggers.first(where: { $0.prefix == ch }),
           shouldOpen(at: range.location, in: controller, trigger: trigger) {
            let context = CompletionContext(
                triggerID: trigger.id,
                query: "",
                range: NSRange(location: range.location, length: 1),
                caretRect: controller.caretRect()
            )
            store(CompletionSession(context: context), controller: controller)
        }
        return false
    }

    private func extendOrCloseSession(
        _ session: CompletionSession,
        range: NSRange,
        text: String,
        controller: EditorController
    ) {
        // Insertion outside the session's expected end closes it.
        let expectedEnd = session.context.range.location + session.context.range.length
        guard range.location == expectedEnd, range.length == 0 else {
            clear(controller: controller)
            return
        }
        // Whitespace, newline, or another trigger char closes the session.
        if text.contains(where: { $0.isWhitespace || $0.isNewline }) {
            clear(controller: controller)
            return
        }
        if let ch = text.first, triggers.contains(where: { $0.prefix == ch }) {
            // Switching triggers mid-query: drop the old, open a fresh
            // session at the new prefix.
            clear(controller: controller)
            return
        }
        var updated = session
        updated.context = CompletionContext(
            triggerID: session.context.triggerID,
            query: session.context.query + text,
            range: NSRange(
                location: session.context.range.location,
                length: session.context.range.length + text.count
            ),
            caretRect: controller.caretRect()
        )
        store(updated, controller: controller)
    }

    private func deriveSession(from session: CompletionSession, controller: EditorController) {
        let storage = controller.textStorage
        let anchor = session.context.range.location
        // Anchor must still hold the trigger character we opened on.
        guard anchor < storage.length,
              let triggerChar = (storage.string as NSString).substring(
                with: NSRange(location: anchor, length: 1)
              ).first,
              triggers.contains(where: { $0.prefix == triggerChar && $0.id == session.context.triggerID })
        else {
            clear(controller: controller)
            return
        }
        // The session's expected end is anchor + length. If storage no
        // longer extends that far (backspace below the prefix), clear.
        let expectedEnd = anchor + session.context.range.length
        guard expectedEnd <= storage.length else {
            // The user backspaced into the session — recompute the query
            // by walking from anchor+1 to storage end or first whitespace.
            let trimmed = trimSession(session, in: storage, controller: controller)
            if let trimmed { store(trimmed, controller: controller) } else { clear(controller: controller) }
            return
        }
        // Verify the predicted query still matches storage. Diverges when
        // the user pasted content into the middle, undid an edit, or
        // backspaced characters out of the query.
        let actualSlice = (storage.string as NSString).substring(
            with: NSRange(location: anchor, length: session.context.range.length)
        )
        let predicted = String(triggerChar) + session.context.query
        if actualSlice != predicted {
            let trimmed = trimSession(session, in: storage, controller: controller)
            if let trimmed { store(trimmed, controller: controller) } else { clear(controller: controller) }
            return
        }
        // Match — leave session unchanged.
    }

    /// Re-derive the query length from storage when it diverges from the
    /// predicted state. Returns the new session, or nil if the session
    /// should close (whitespace in query, anchor lost, etc.).
    private func trimSession(
        _ session: CompletionSession,
        in storage: NSAttributedString,
        controller: EditorController
    ) -> CompletionSession? {
        let anchor = session.context.range.location
        guard anchor < storage.length else { return nil }
        var end = anchor + 1
        let ns = storage.string as NSString
        while end < storage.length {
            let ch = ns.character(at: end)
            let scalar = Unicode.Scalar(ch)
            if let scalar, CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            end += 1
        }
        let queryRange = NSRange(location: anchor + 1, length: end - (anchor + 1))
        let query = ns.substring(with: queryRange)
        var updated = session
        updated.context = CompletionContext(
            triggerID: session.context.triggerID,
            query: query,
            range: NSRange(location: anchor, length: end - anchor),
            caretRect: controller.caretRect()
        )
        return updated
    }

    private func shouldOpen(
        at location: Int,
        in controller: EditorController,
        trigger: CompletionTrigger
    ) -> Bool {
        let storage = controller.textStorage
        // Trigger must be at start of doc, after whitespace, or after a
        // newline — typing "@" inside "x@y" shouldn't open a mention.
        if location > 0, location <= storage.length {
            let prev = (storage.string as NSString).substring(
                with: NSRange(location: location - 1, length: 1)
            )
            if let ch = prev.first, !ch.isWhitespace, !ch.isNewline { return false }
        }
        if !trigger.allowedInCode {
            if location > 0, location <= storage.length {
                let probe = max(0, min(location, storage.length - 1))
                if storage.blockSpec(at: probe)?.isCodeBlock == true { return false }
                if let marks = storage.markSet(at: probe), marks.contains(name: "code") {
                    return false
                }
            }
        }
        return true
    }

    private func currentSession(_ controller: EditorController) -> CompletionSession? {
        controller.pluginState(for: Self.stateKey)
    }

    private func store(_ session: CompletionSession, controller: EditorController) {
        controller.setPluginState(session, for: Self.stateKey)
        onSessionChanged?(session)
    }

    private func clear(controller: EditorController) {
        controller.clearPluginState(for: Self.stateKey)
        onSessionChanged?(nil)
    }
}
