#if os(macOS)
import AppKit
import Foundation
@_spi(Harness) import SwiftProse

/// Runs `EditOp`s against the app's real `NSTextView`.
///
/// Every op goes through AppKit's own input path — `insertText`,
/// `doCommand(by:)`, a synthesized `keyDown`, the menu `undo:` action —
/// so the delegate stamps an `EditHint`, `ProseTextStorage` captures a
/// pre-image, and `didChangeText()` drains the envelope, exactly as when a
/// person types.
@MainActor
final class EditDriver {

    enum Failure: Error, CustomStringConvertible {
        case unknownKey(String)
        case unknownAction(String)
        case unresolvableAnchor(Anchor, opIndex: Int)
        case expectationFailed(String)
        case oracle(OracleFailure)

        var description: String {
            switch self {
            case .unknownKey(let k): return "unknown key \"\(k)\""
            case .unknownAction(let id): return "unknown action id \"\(id)\""
            case .unresolvableAnchor(let a, let i): return "op \(i): anchor \(a.summary) did not resolve"
            case .expectationFailed(let message): return message
            case .oracle(let f): return f.description
            }
        }
    }

    let controller: EditorController
    let textView: NSTextView
    /// False when the setUp canary found synthesized key events don't reach
    /// the view; arrow keys then fall back to `doCommand(by:)`.
    var synthesizedKeyEventsWork = true
    /// Called after each op with its index — the write-ahead log and the
    /// inspector's progress readout hang off this.
    var onOpCompleted: ((Int, EditOp) -> Void)?

    init(controller: EditorController, textView: NSTextView) {
        self.controller = controller
        self.textView = textView
    }

    // MARK: - Running

    @discardableResult
    func run(_ ops: [EditOp], oracles: Oracles? = nil, stopAt: Int? = nil) throws -> Int {
        for (index, op) in ops.enumerated() {
            if let stopAt, index >= stopAt { return index }
            try perform(op, at: index)
            settle()
            if let oracles { try oracles.checkCadenced(at: index, op: op) }
            onOpCompleted?(index, op)
        }
        return ops.count
    }

    func perform(_ op: EditOp, at index: Int = 0) throws {
        switch op {
        case .type(let text):
            // Per character. A multi-character insert containing whitespace
            // is re-routed to the paste pipeline by the delegate's bulk
            // veto, which is `typeBurst`'s job, not this one's.
            for ch in text {
                textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            }

        case .typeBurst(let text):
            textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))

        case .key(let name):
            try pressKey(name)

        case .undo(let n):
            for _ in 0..<max(1, n) { sendAction("undo:") }

        case .redo(let n):
            for _ in 0..<max(1, n) { sendAction("redo:") }

        case .selectAll:
            textView.selectAll(nil)

        case .copy:
            textView.copy(nil)

        case .cut:
            textView.cut(nil)

        case .paste(let text, let html, let plain):
            paste(text: text, html: html, plain: plain)

        case .caret(let anchor):
            let pos = try resolve(anchor, at: index)
            textView.setSelectedRange(NSRange(location: pos, length: 0))

        case .select(let from, let to):
            let a = try resolve(from, at: index)
            let b = try resolve(to, at: index)
            let lo = min(a, b), hi = max(a, b)
            textView.setSelectedRange(NSRange(location: lo, length: hi - lo))

        case .action(let id, let url, let label, let rows, let columns):
            guard let action = Self.action(id: id, url: url, label: label, rows: rows, columns: columns) else {
                throw Failure.unknownAction(id)
            }
            _ = controller.perform(action)

        case .compose(let interims, let commit):
            compose(interims: interims, commit: commit)

        case .correct(let find, let replace):
            correct(find: find, replace: replace)

        case .toggleCheckbox(let anchor):
            let pos = try resolve(anchor, at: index)
            _ = controller.toggleCheckbox(at: pos)

        case .load(let markdown, let keepHistory):
            controller.setMarkdown(markdown, async: false)
            // `replaceStorage` clears neither the undo stack nor the open
            // typing burst. A scenario's `load` means "start here", so both
            // go — unless the scenario is deliberately probing what happens
            // when they don't.
            if !keepHistory {
                controller.undoManager.removeAllActions()
                controller.closeHistoryGroup()
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))

        case .closeHistoryGroup:
            controller.closeHistoryGroup()

        case .wait(let ms):
            guard ms > 0 else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(Double(ms) / 1000))

        case .expect(let expectation):
            try check(expectation)

        case .check:
            // Handled by the caller, which owns the Oracles instance.
            break
        }
    }

    /// Leave the text view's input state as a fresh editor's. A run that
    /// ends mid-composition would otherwise make every later edit classify
    /// as `.compositionInterim`: no normalization, no publish, no input
    /// rules, no undo entry. `unmarkText()` alone *accepts* the marked
    /// text; cancelling is an empty marked range first.
    func clearInputState() {
        guard textView.hasMarkedText() else { return }
        textView.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: textView.markedRange()
        )
        textView.unmarkText()
        settle()
    }

    // MARK: - Settling
    //
    // Hosted drains are synchronous: `didChangeText()` closes the envelope
    // before returning. What is deferred is `main.async` work — typing
    // attributes, the code-block rehighlight, the background layer, the
    // binding push. Two main-queue fences put all of it behind us; the
    // explicit drain then covers the paths that queue an envelope without
    // going through `didChangeText`.

    func settle() {
        fence()
        fence()
        controller.drainPendingEnvelopesForHarness()
    }

    private final class Flag { var value = false }

    /// Reported once per process. A fence that times out means the caller
    /// is running inside a main-queue block — libdispatch will not drain
    /// the main queue re-entrantly, so nothing the editor deferred can
    /// ever run, and every settle silently burns its deadline.
    nonisolated(unsafe) private static var warnedAboutFenceTimeout = false

    private func fence() {
        let flag = Flag()
        DispatchQueue.main.async { flag.value = true }
        let deadline = Date().addingTimeInterval(1)
        while !flag.value, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        if !flag.value, !Self.warnedAboutFenceTimeout {
            Self.warnedAboutFenceTimeout = true
            let message = "harness: settle() could not drain the main queue — the driver "
                + "is running inside a main-queue block. Schedule it from a run-loop "
                + "timer instead.\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    // MARK: - Keys

    /// Editing and movement selectors reach the controller through the
    /// same delegate route as `interpretKeyEvents`. Shortcuts that
    /// `ProseNSTextView.keyDown` handles before `super` have to arrive as
    /// real events instead.
    private func pressKey(_ name: String) throws {
        if let selector = KeyTable.selectors[name] {
            textView.doCommand(by: selector)
            return
        }
        guard let spec = KeyTable.events[name] else { throw Failure.unknownKey(name) }
        guard synthesizedKeyEventsWork || spec.requiresEvent else {
            // The canary found key events don't land. Movement keys have a
            // selector fallback; command shortcuts don't.
            if let fallback = spec.fallbackSelector {
                textView.doCommand(by: fallback)
                return
            }
            throw Failure.unknownKey("\(name) (key events unavailable, no selector fallback)")
        }
        textView.keyDown(with: spec.makeEvent())
    }

    struct KeySpec {
        var keyCode: UInt16
        var characters: String
        var modifiers: NSEvent.ModifierFlags = []
        /// True when only a real event reaches the behavior under test —
        /// `ProseNSTextView.keyDown` intercepts it before `super`.
        var requiresEvent: Bool = false
        var fallbackSelector: Selector?

        func makeEvent() -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )!
        }
    }

    enum KeyTable {
        /// Keys whose behavior is entirely in the `doCommandBy` route.
        /// macOS Home / End scroll rather than moving the caret, so line
        /// moves are spelled `Mod-ArrowLeft` / `Mod-ArrowRight`.
        static let selectors: [String: Selector] = [
            "Enter": #selector(NSResponder.insertNewline(_:)),
            "Backspace": #selector(NSResponder.deleteBackward(_:)),
            "Delete": #selector(NSResponder.deleteForward(_:)),
            "Tab": #selector(NSResponder.insertTab(_:)),
            "Shift-Tab": #selector(NSResponder.insertBacktab(_:)),
            "Escape": #selector(NSResponder.cancelOperation(_:)),
            "ArrowLeft": #selector(NSResponder.moveLeft(_:)),
            "ArrowRight": #selector(NSResponder.moveRight(_:)),
            "ArrowUp": #selector(NSResponder.moveUp(_:)),
            "ArrowDown": #selector(NSResponder.moveDown(_:)),
            "Shift-ArrowLeft": #selector(NSResponder.moveLeftAndModifySelection(_:)),
            "Shift-ArrowRight": #selector(NSResponder.moveRightAndModifySelection(_:)),
            "Shift-ArrowUp": #selector(NSResponder.moveUpAndModifySelection(_:)),
            "Shift-ArrowDown": #selector(NSResponder.moveDownAndModifySelection(_:)),
            "Alt-ArrowLeft": #selector(NSResponder.moveWordLeft(_:)),
            "Alt-ArrowRight": #selector(NSResponder.moveWordRight(_:)),
            "Alt-Shift-ArrowLeft": #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
            "Alt-Shift-ArrowRight": #selector(NSResponder.moveWordRightAndModifySelection(_:)),
            "Mod-ArrowLeft": #selector(NSResponder.moveToBeginningOfLine(_:)),
            "Mod-ArrowRight": #selector(NSResponder.moveToEndOfLine(_:)),
            "Mod-Shift-ArrowLeft": #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
            "Mod-Shift-ArrowRight": #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
            "Mod-ArrowUp": #selector(NSResponder.moveToBeginningOfDocument(_:)),
            "Mod-ArrowDown": #selector(NSResponder.moveToEndOfDocument(_:)),
            "Alt-Backspace": #selector(NSResponder.deleteWordBackward(_:)),
            "Alt-Delete": #selector(NSResponder.deleteWordForward(_:)),
            "Mod-Backspace": #selector(NSResponder.deleteToBeginningOfLine(_:))
        ]

        /// Keys that must arrive as events: the Cmd shortcuts
        /// `ProseNSTextView.keyDown` consumes before `super`, and
        /// Shift-Enter, which may bypass `handleNewline`.
        static let events: [String: KeySpec] = [
            "Mod-b": KeySpec(keyCode: 11, characters: "b", modifiers: .command, requiresEvent: true),
            "Mod-i": KeySpec(keyCode: 34, characters: "i", modifiers: .command, requiresEvent: true),
            "Mod-e": KeySpec(keyCode: 14, characters: "e", modifiers: .command, requiresEvent: true),
            "Mod-k": KeySpec(keyCode: 40, characters: "k", modifiers: .command, requiresEvent: true),
            "Mod-[": KeySpec(keyCode: 33, characters: "[", modifiers: .command, requiresEvent: true),
            "Mod-]": KeySpec(keyCode: 30, characters: "]", modifiers: .command, requiresEvent: true),
            "Mod-Shift-x": KeySpec(keyCode: 7, characters: "x", modifiers: [.command, .shift], requiresEvent: true),
            "Mod-Enter": KeySpec(keyCode: 36, characters: "\r", modifiers: .command, requiresEvent: true),
            "Shift-Enter": KeySpec(
                keyCode: 36, characters: "\r", modifiers: .shift,
                fallbackSelector: #selector(NSResponder.insertNewline(_:))
            ),
            "KeypadEnter": KeySpec(
                keyCode: 76, characters: "\u{3}",
                fallbackSelector: #selector(NSResponder.insertNewline(_:))
            )
        ]

        static var all: [String] { Array(selectors.keys) + Array(events.keys) }
    }

    /// The menu route. Cmd-Z never reaches `keyDown` in a real app — the
    /// main menu takes the key equivalent and sends `undo:` up the
    /// responder chain, which is what `ProseNSTextView` overrides.
    private func sendAction(_ name: String) {
        let selector = NSSelectorFromString(name)
        if textView.responds(to: selector) {
            _ = textView.perform(selector, with: nil)
        } else {
            // No override on this class — fall back to the controller so a
            // scenario still exercises history rather than silently doing
            // nothing. The canary reports the discrepancy.
            name == "undo:" ? controller.undoManager.undo() : controller.undoManager.redo()
        }
    }

    // MARK: - Clipboard

    /// Pasteboard name for the private board rich pastes are staged on, so
    /// a run never touches the user's clipboard.
    private static let privateBoardName = NSPasteboard.Name("dev.swiftprose.harness")

    private func paste(text: String, html: String?, plain: Bool) {
        if plain {
            // `pasteAsPlainText` reads the general board and is the only
            // way to reach `plainText: true` from outside the module.
            // Saved and restored around the call.
            let saved = Self.snapshotGeneralPasteboard()
            defer { Self.restoreGeneralPasteboard(saved) }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            textView.pasteAsPlainText(nil)
            return
        }
        let pb = NSPasteboard(name: Self.privateBoardName)
        pb.clearContents()
        pb.setString(text, forType: .string)
        if let html { pb.setString(html, forType: .html) }
        _ = textView.readSelection(from: pb)
    }

    struct PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]]
    }

    static func snapshotGeneralPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var reps: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { reps[type] = data }
            }
            items.append(reps)
        }
        return PasteboardSnapshot(items: items)
    }

    static func restoreGeneralPasteboard(_ snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { reps -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in reps { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    // MARK: - Composition and correction

    /// IME: each interim replaces the marked range; the commit lands as
    /// real text. `commit == nil` unmarks — the user pressed Escape.
    /// An empty first interim is a cancel before anything was marked.
    private func compose(interims: [String], commit: String?) {
        for interim in interims {
            let replacement = textView.hasMarkedText()
                ? textView.markedRange()
                : NSRange(location: NSNotFound, length: 0)
            textView.setMarkedText(
                interim,
                selectedRange: NSRange(location: (interim as NSString).length, length: 0),
                replacementRange: replacement
            )
            settle()
        }
        if let commit {
            textView.insertText(commit, replacementRange: textView.hasMarkedText()
                ? textView.markedRange()
                : NSRange(location: NSNotFound, length: 0))
        } else if textView.hasMarkedText() {
            // `unmarkText()` alone *accepts* the marked text. Cancelling —
            // what Escape does — is an empty marked range first.
            textView.setMarkedText(
                "",
                selectedRange: NSRange(location: 0, length: 0),
                replacementRange: textView.markedRange()
            )
            textView.unmarkText()
        }
    }

    /// Autocorrect's shape: rewrite a range the selection is not on. The
    /// delegate's hint ladder reads that as `.correction`.
    private func correct(find: String, replace: String) {
        let string = textView.string as NSString
        let range = string.range(of: find)
        guard range.location != NSNotFound else { return }
        // Park the caret away from the rewritten range so the hint is
        // `.correction` and not `.typing` / `.bulk`.
        let parked = range.location + range.length
        textView.setSelectedRange(NSRange(location: min(parked, string.length), length: 0))
        textView.insertText(replace, replacementRange: range)
    }

    // MARK: - Anchors

    func resolve(_ anchor: Anchor, at index: Int) throws -> Int {
        guard let pos = anchor.resolve(in: textView.string as NSString) else {
            throw Failure.unresolvableAnchor(anchor, opIndex: index)
        }
        return max(0, min(pos, (textView.string as NSString).length))
    }

    // MARK: - Expectations

    func check(_ expectation: Expectation) throws {
        var problems: [String] = []
        if let doc = expectation.doc {
            let marked = try MarkedText.parse(doc, markers: Scenario.defaultMarkers)
            let actual = controller.markdown()
            let expected = Self.trimOneTrailingNewline(marked.clean)
            if actual != expected {
                problems.append("""
                markdown mismatch
                \(StorageDump.diff(expected, actual, context: 4))
                """)
            }
        }
        if let selection = expectation.selection, selection.count == 2 {
            let want = NSRange(location: selection[0], length: selection[1])
            if textView.selectedRange() != want {
                problems.append("selection expected \(want) got \(textView.selectedRange())")
            }
        }
        if let kind = expectation.blockKind {
            let probe = min(controller.currentSelection.location, max(0, controller.textStorage.length - 1))
            let spec = probe >= 0 ? controller.textStorage.blockSpec(at: probe) : nil
            let actual = spec.map { "\($0.kind)" } ?? "‹none›"
            if actual != kind {
                problems.append("blockKind expected \(kind) got \(actual)")
            }
        }
        if let canUndo = expectation.canUndo, controller.undoManager.canUndo != canUndo {
            problems.append("canUndo expected \(canUndo) got \(controller.undoManager.canUndo)")
        }
        if let canRedo = expectation.canRedo, controller.undoManager.canRedo != canRedo {
            problems.append("canRedo expected \(canRedo) got \(controller.undoManager.canRedo)")
        }
        if let depth = expectation.undoDepth, controller.undoDepth != depth {
            problems.append("undoDepth expected \(depth) got \(controller.undoDepth)")
        }
        if let marks = expectation.marks {
            let actual = Self.marksAtCaret(controller).sorted()
            if actual != marks.sorted() {
                problems.append("marks expected \(marks.sorted()) got \(actual)")
            }
        }
        guard problems.isEmpty else {
            throw Failure.expectationFailed(problems.joined(separator: "\n"))
        }
    }

    static func marksAtCaret(_ controller: EditorController) -> [String] {
        let storage = controller.textStorage
        let selection = controller.currentSelection
        // A collapsed caret inherits the character before it, which is what
        // typing there would carry.
        let probe = selection.length > 0
            ? selection.location
            : max(0, selection.location - 1)
        guard probe < storage.length, storage.length > 0 else { return [] }
        guard let box = storage.attribute(.proseMarks, at: probe, effectiveRange: nil) as? MarkSetBox
        else { return [] }
        return box.marks.marks.map(\.type)
    }

    static func trimOneTrailingNewline(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    // MARK: - Actions

    static func action(id: String,
                       url: String? = nil,
                       label: String? = nil,
                       rows: Int? = nil,
                       columns: Int? = nil) -> EditorAction? {
        if id.hasPrefix("heading:"), let level = Int(id.dropFirst("heading:".count)) {
            return .heading(level: level)
        }
        switch id {
        case "bold": return .bold
        case "italic": return .italic
        case "strikethrough": return .strikethrough
        case "unorderedList": return .unorderedList
        case "orderedList": return .orderedList
        case "taskList": return .taskList
        case "blockquote": return .blockquote
        case "codeSpan": return .codeSpan
        case "codeBlock": return .codeBlock
        case "link": return .link(url: url, label: label)
        case "horizontalRule": return .horizontalRule
        case "indent": return .indent
        case "outdent": return .outdent
        case "insertTable": return .insertTable(rows: rows ?? 2, columns: columns ?? 3)
        case "insertTableRowAbove": return .insertTableRowAbove
        case "insertTableRowBelow": return .insertTableRowBelow
        case "insertTableColumnBefore": return .insertTableColumnBefore
        case "insertTableColumnAfter": return .insertTableColumnAfter
        case "deleteTableRow": return .deleteTableRow
        case "deleteTableColumn": return .deleteTableColumn
        default: return nil
        }
    }

    /// Every id `action(id:)` accepts, for the fuzzer's action pool.
    static let actionIDs: [String] = [
        "bold", "italic", "strikethrough", "heading:1", "heading:2", "heading:3",
        "heading:0", "unorderedList", "orderedList", "taskList", "blockquote",
        "codeSpan", "codeBlock", "horizontalRule", "indent", "outdent"
    ]
}
#endif
