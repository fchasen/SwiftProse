import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct CompletionTrigger: Equatable, Sendable {
    public let id: String
    public let prefix: Character
    public let allowedInCode: Bool

    public init(id: String, prefix: Character, allowedInCode: Bool = false) {
        self.id = id
        self.prefix = prefix
        self.allowedInCode = allowedInCode
    }
}

public struct CompletionContext: Equatable, Sendable {
    public let triggerID: String
    public let query: String
    public let range: NSRange
    public let caretRect: CGRect?

    public init(triggerID: String, query: String, range: NSRange, caretRect: CGRect?) {
        self.triggerID = triggerID
        self.query = query
        self.range = range
        self.caretRect = caretRect
    }
}

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

public final class CompletionPlugin: EditorPlugin {
    public static let keyName = "swiftprose.completion"
    public static let stateKey = PluginKey<CompletionSession>(name: keyName)
    public let key = AnyPluginKey(name: keyName)

    public let triggers: [CompletionTrigger]
    public var onSessionChanged: ((CompletionSession?) -> Void)?
    public var onCommit: ((any ProseEditing, CompletionSession) -> Void)?
    private var isCommitting = false
    private let attachedSources = NSHashTable<SourceEditorController>.weakObjects()

    public init(triggers: [CompletionTrigger]) {
        self.triggers = triggers
    }

    public func attach(to controller: EditorController) {
        guard !controller.plugins.contains(where: { $0 === self }) else { return }
        controller.register(plugin: self)
        controller.addOnSelectionChanged { [weak self, weak controller] selection in
            guard let self, let controller else { return }
            self.selectionDidChange(selection, host: controller)
        }
    }

    public func attach(to controller: SourceEditorController) {
        guard !attachedSources.contains(controller) else { return }
        attachedSources.add(controller)
        controller.addKeyHandler { [weak self, weak controller] key in
            guard let self, let controller else { return false }
            return self.handleKey(host: controller, key: key)
        }
        controller.addTextInputHandler { [weak self, weak controller] range, text in
            guard let self, let controller else { return false }
            return self.handleTextInput(host: controller, range: range, text: text)
        }
        controller.addOnTextChange { [weak self, weak controller] change in
            guard let self, let controller else { return }
            self.handleDocumentChange(change, host: controller)
        }
        controller.addOnSelectionChanged { [weak self, weak controller] selection in
            guard let self, let controller else { return }
            self.selectionDidChange(selection, host: controller)
        }
    }

    public var props: PluginProps {
        PluginProps(
            handleKeyDown: { [weak self] controller, key in
                self?.handleKey(host: controller, key: key) ?? false
            },
            handleTextInput: { [weak self] controller, range, text in
                self?.handleTextInput(host: controller, range: range, text: text) ?? false
            }
        )
    }

    public func documentDidChange(_ change: DocumentChange, controller: EditorController) {
        handleDocumentChange(change, host: controller)
    }

    public func session(controller: any ProseEditing) -> CompletionSession? {
        currentSession(controller)
    }

    public func updateHighlight(_ index: Int, controller: any ProseEditing) {
        guard var session = currentSession(controller) else { return }
        let clamped = max(0, min(index, max(0, session.itemCount - 1)))
        guard clamped != session.highlightedIndex else { return }
        session.highlightedIndex = clamped
        store(session, controller: controller)
    }

    public func updateItemCount(_ count: Int, controller: any ProseEditing) {
        guard var session = currentSession(controller) else { return }
        session.itemCount = max(0, count)
        if session.highlightedIndex >= session.itemCount {
            session.highlightedIndex = max(0, session.itemCount - 1)
        }
        store(session, controller: controller)
    }

    public func commit(controller: any ProseEditing) {
        guard let session = currentSession(controller) else { return }
        isCommitting = true
        onCommit?(Self.resolve(controller), session)
        isCommitting = false
        clear(controller: controller)
    }

    public func cancel(controller: any ProseEditing) {
        guard currentSession(controller) != nil else { return }
        clear(controller: controller)
    }

    public func refresh(controller: any ProseEditing) {
        guard !isCommitting, let session = currentSession(controller), let host = Self.support(controller) else { return }
        deriveSession(from: session, host: host)
    }

    private static func resolve(_ editor: any ProseEditing) -> any ProseEditing {
        (editor as? EditorHandle)?.activeEditor ?? editor
    }

    private static func support(_ editor: any ProseEditing) -> (any CompletionSupporting)? {
        resolve(editor) as? any CompletionSupporting
    }

    private func handleDocumentChange(_ change: DocumentChange, host: any CompletionSupporting) {
        if change.origin == .load {
            cancel(controller: host)
            return
        }
        refresh(controller: host)
    }

    private func selectionDidChange(_ selection: NSRange, host: any CompletionSupporting) {
        guard !isCommitting, !host.isComposingText, !host.hasPendingDocumentChange,
              let session = currentSession(host) else { return }
        let range = session.context.range
        if selection.location < range.location + 1 || NSMaxRange(selection) > NSMaxRange(range) {
            cancel(controller: host)
        }
    }

    private func handleKey(host: any CompletionSupporting, key: String) -> Bool {
        guard let session = currentSession(host), !host.isComposingText else { return false }
        switch key {
        case PluginKeyName.escape:
            cancel(controller: host)
            return true
        case PluginKeyName.arrowDown:
            guard session.itemCount > 0 else { return false }
            updateHighlight(session.highlightedIndex + 1, controller: host)
            return true
        case PluginKeyName.arrowUp:
            guard session.itemCount > 0 else { return false }
            updateHighlight(session.highlightedIndex - 1, controller: host)
            return true
        case PluginKeyName.enter, PluginKeyName.tab:
            guard session.itemCount > 0 else {
                cancel(controller: host)
                return false
            }
            commit(controller: host)
            return true
        default:
            return false
        }
    }

    private func handleTextInput(
        host: any CompletionSupporting,
        range: NSRange,
        text: String
    ) -> Bool {
        if host.isApplyingCommand || host.isComposingText { return false }
        if let existing = currentSession(host) {
            if Self.isCommitInput(text) {
                guard existing.itemCount > 0 else {
                    clear(controller: host)
                    return false
                }
                host.deferEdit { [weak self, weak host] in
                    guard let self, let host, self.currentSession(host)?.context.range.location == existing.context.range.location else { return }
                    self.commit(controller: host)
                }
                return true
            }
            if text.isEmpty {
                shrinkOrCloseSession(existing, deleting: range, host: host)
            } else {
                extendOrCloseSession(existing, range: range, text: text, host: host)
            }
            return false
        }
        if text.count == 1,
           let ch = text.first,
           let trigger = triggers.first(where: { $0.prefix == ch }),
           shouldOpen(at: range.location, replacing: range, in: host, trigger: trigger) {
            let context = CompletionContext(
                triggerID: trigger.id,
                query: "",
                range: NSRange(location: range.location, length: (text as NSString).length),
                caretRect: host.caretRect()
            )
            store(CompletionSession(context: context), controller: host)
        }
        return false
    }

    private static func isCommitInput(_ text: String) -> Bool {
        text == "\n" || text == "\r" || text == "\r\n" || text == "\t"
    }

    private func extendOrCloseSession(
        _ session: CompletionSession,
        range: NSRange,
        text: String,
        host: any CompletionSupporting
    ) {
        let expectedEnd = NSMaxRange(session.context.range)
        guard range.location == expectedEnd, range.length == 0 else {
            clear(controller: host)
            return
        }
        if text.contains(where: { $0.isWhitespace || $0.isNewline }) {
            clear(controller: host)
            return
        }
        if text.contains(where: { ch in triggers.contains(where: { $0.prefix == ch }) }) {
            clear(controller: host)
            return
        }
        var updated = session
        updated.context = CompletionContext(
            triggerID: session.context.triggerID,
            query: session.context.query + text,
            range: NSRange(
                location: session.context.range.location,
                length: session.context.range.length + (text as NSString).length
            ),
            caretRect: host.caretRect()
        )
        store(updated, controller: host)
    }

    private func shrinkOrCloseSession(
        _ session: CompletionSession,
        deleting range: NSRange,
        host: any CompletionSupporting
    ) {
        let anchor = session.context.range.location
        let queryStart = anchor + 1
        guard range.location >= queryStart, NSMaxRange(range) <= NSMaxRange(session.context.range) else {
            clear(controller: host)
            return
        }
        let query = session.context.query as NSString
        let local = NSRange(location: range.location - queryStart, length: range.length)
        guard NSMaxRange(local) <= query.length else {
            clear(controller: host)
            return
        }
        var updated = session
        updated.context = CompletionContext(
            triggerID: session.context.triggerID,
            query: query.replacingCharacters(in: local, with: ""),
            range: NSRange(location: anchor, length: session.context.range.length - range.length),
            caretRect: host.caretRect()
        )
        store(updated, controller: host)
    }

    private func deriveSession(from session: CompletionSession, host: any CompletionSupporting) {
        let ns = host.textStorage.string as NSString
        let anchor = session.context.range.location
        guard anchor < ns.length,
              let triggerChar = ns.substring(with: NSRange(location: anchor, length: 1)).first,
              triggers.contains(where: { $0.prefix == triggerChar && $0.id == session.context.triggerID })
        else {
            clear(controller: host)
            return
        }
        let expectedEnd = NSMaxRange(session.context.range)
        if expectedEnd <= ns.length,
           ns.substring(with: session.context.range) == String(triggerChar) + session.context.query {
            return
        }
        if let trimmed = trimSession(session, in: ns) {
            if trimmed != session { store(trimmed, controller: host) }
        } else {
            clear(controller: host)
        }
    }

    private func trimSession(_ session: CompletionSession, in ns: NSString) -> CompletionSession? {
        let anchor = session.context.range.location
        guard anchor < ns.length else { return nil }
        var end = anchor + 1
        while end < ns.length {
            let unit = ns.character(at: end)
            if unit == MarkdownParagraph.objectReplacement { break }
            if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            end += 1
        }
        var updated = session
        updated.context = CompletionContext(
            triggerID: session.context.triggerID,
            query: ns.substring(with: NSRange(location: anchor + 1, length: end - anchor - 1)),
            range: NSRange(location: anchor, length: end - anchor),
            caretRect: session.context.caretRect
        )
        return updated
    }

    private func shouldOpen(
        at location: Int,
        replacing range: NSRange,
        in host: any CompletionSupporting,
        trigger: CompletionTrigger
    ) -> Bool {
        let ns = host.textStorage.string as NSString
        if location > 0, location <= ns.length {
            let previous = ns.substring(with: NSRange(location: location - 1, length: 1))
            if let ch = previous.first, !ch.isWhitespace, !ch.isNewline { return false }
        }
        return host.allowsCompletionTrigger(at: location, replacing: range, allowedInCode: trigger.allowedInCode)
    }

    private func currentSession(_ controller: any ProseEditing) -> CompletionSession? {
        Self.resolve(controller).pluginState(for: Self.stateKey)
    }

    private func store(_ session: CompletionSession, controller: any ProseEditing) {
        Self.resolve(controller).setPluginState(session, for: Self.stateKey)
        onSessionChanged?(session)
    }

    private func clear(controller: any ProseEditing) {
        Self.resolve(controller).clearPluginState(for: Self.stateKey)
        onSessionChanged?(nil)
    }
}
