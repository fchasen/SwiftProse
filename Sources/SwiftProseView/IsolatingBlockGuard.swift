import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A block the source represents as a single object-replacement character
/// — an `isolating` node whose content lives off-buffer (today: `table`),
/// or a block-level leaf that has no text at all (`horizontal_rule`) —
/// occupies exactly `\u{FFFC}\n` in storage, both characters stamped with
/// one `proseNodePath` ending at the node. `ProseDocument.from(storage:)`
/// lifts the subtree by looking for the attachment *at the run start*, so
/// a character inserted anywhere on that line moves the attachment off the
/// start and the whole block — cell text included — projects as an empty
/// isolating node and serializes to nothing.
///
/// The run is therefore atomic to every platform edit: the text view hands
/// insertions and partial deletions over here before mutating storage.
extension EditorController {

    /// The run of an attachment-backed isolating block that a platform edit
    /// over `range` would land on. Only the offset past the run's newline
    /// is off its line, so a caret there is outside and yields nil.
    func isolatingBlockRun(intersecting range: NSRange) -> NSRange? {
        let storage = textStorage
        guard storage.length > 0, range.location <= storage.length else { return nil }
        // A zero-length range at `length` is the empty last line, not the
        // block above it.
        let probe = range.location < storage.length
            ? range.location
            : (range.length > 0 ? storage.length - 1 : -1)
        guard probe >= 0 else { return nil }
        guard let run = isolatingRun(at: probe, in: storage) else {
            // A deletion can reach the run without starting inside it.
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
            for offset in range.location..<NSMaxRange(range) {
                if let run = isolatingRun(at: offset, in: storage) { return run }
            }
            return nil
        }
        return run
    }

    private func isolatingRun(at location: Int, in storage: NSTextStorage) -> NSRange? {
        guard location >= 0, location < storage.length else { return nil }
        guard let leaf = storage.nodePath(at: location)?.leaf,
              let type = compiler.schema.nodeType(leaf.type),
              type.isolating || (type.isBlock && type.isLeaf) else { return nil }
        // `effectiveRange` would stop at the `NSAttachment` run boundary,
        // handing back the `\u{FFFC}` without its newline.
        let line = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: location, length: 0))
        var run = NSRange(location: 0, length: 0)
        _ = storage.attribute(.proseNodePath, at: location, longestEffectiveRange: &run, in: line)
        return run.length > 0 ? run : nil
    }

    /// Take a platform edit that would land on an isolating block's line.
    /// Insertions open a paragraph of their own on the near side of the
    /// block; a deletion that only clips the run widens to cover it, which
    /// is what deleting an atom means.
    ///
    /// - Returns: true when the edit was taken here and the platform must
    ///   not apply its own.
    func interceptEditAtIsolatingBlock(range: NSRange, replacement: String) -> Bool {
        guard let run = isolatingBlockRun(intersecting: range) else { return false }
        if replacement.isEmpty {
            // Already covers the run: let it through unchanged.
            if range.location <= run.location, NSMaxRange(range) >= NSMaxRange(run) {
                return false
            }
            return deleteIsolatingBlock(run: run)
        }
        return insertBesideIsolatingBlock(replacement, run: run, editing: range)
    }

    /// Open a paragraph beside `run` holding `text`, leaving the block
    /// intact. The side is the one the caret sits on: at the run start the
    /// paragraph goes above, anywhere else within the line it goes below.
    @discardableResult
    func insertBesideIsolatingBlock(
        _ text: String,
        run: NSRange,
        editing range: NSRange
    ) -> Bool {
        let before = range.location <= run.location
        let at = before ? run.location : NSMaxRange(run)
        let env = makeStepEnvironment()
        // Trailing newlines in the text are already the paragraph break the
        // separator supplies: a typed newline opens an empty paragraph
        // rather than three blank lines.
        let body = text.trimmingCharacters(in: .newlines)
        // A blank line after the paragraph keeps the pipe-table grammar's
        // requirement that the table open a fresh block.
        let compiled = env.compiler.compile(body + "\n\n", theme: env.theme)
        let caret = at + (body as NSString).length
        var transaction = Transaction(
            steps: [.replaceText(range: NSRange(location: at, length: 0), with: compiled)],
            selection: .cursor(at: caret)
        )
        // A rerouted keystroke is still a keystroke: it belongs in the same
        // undo unit as the characters typed around it.
        if !text.isEmpty { transaction.setMeta("coalesce", true) }
        apply(transaction)
        return true
    }

    /// Replace the whole block with an empty paragraph — the same shape
    /// `DeleteTableCommand` leaves behind, so the line layout stays sane.
    private func deleteIsolatingBlock(run: NSRange) -> Bool {
        let env = makeStepEnvironment()
        let replacement = NSMutableAttributedString(
            string: "\n",
            attributes: [
                .font: env.theme.bodyFont,
                .foregroundColor: env.theme.foregroundColor
            ]
        )
        replacement.setBlockSpec(
            .paragraph,
            in: NSRange(location: 0, length: replacement.length)
        )
        apply(Transaction(
            steps: [.replaceText(range: run, with: replacement)],
            selection: .cursor(at: run.location)
        ))
        return true
    }

    /// Tab with the caret on an attachment-backed isolating block moves the
    /// focus within the block's own view. Falling through would write a tab
    /// onto the block's line and destroy it.
    public func handleTabAtIsolatingBlock(forward: Bool) -> Bool {
        let selection = currentSelection
        guard let run = isolatingBlockRun(intersecting: selection) else { return false }
        guard let attachment = textStorage.attribute(
            NSAttributedString.Key("NSAttachment"),
            at: run.location,
            effectiveRange: nil
        ) as? ProseNodeAttachment else { return true }
        _ = attachment.boundView?.advanceCellFocus(forward: forward)
        return true
    }

    /// Enter with the caret on an isolating block opens an empty paragraph
    /// beside it rather than splitting the block's line.
    func handleNewlineAtIsolatingBlock() -> Bool {
        let selection = currentSelection
        guard let run = isolatingBlockRun(intersecting: selection) else { return false }
        return insertBesideIsolatingBlock("", run: run, editing: selection)
    }
}
