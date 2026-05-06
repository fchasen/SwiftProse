import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct StepEnvironment {
    public let compiler: MarkdownAttributedCompiler
    public let serializer: AttributedMarkdownSerializer
    public let theme: ProseTheme

    public init(
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) {
        self.compiler = compiler
        self.serializer = serializer
        self.theme = theme
    }
}

public enum InlineMark: Equatable, Sendable {
    case bold
    case italic
    case strikethrough
    case codeSpan
}

public enum Step {
    case replaceText(range: NSRange, with: NSAttributedString)
    case setSpec(lineRange: NSRange, BlockSpec)
    case toggleInlineMark(range: NSRange, InlineMark)
    /// Replace the slice between `outer.start..inner.start` AND
    /// `inner.end..outer.end` with `content` (split into a leading and
    /// trailing piece based on `contentSplit`). Mirrors ProseMirror's
    /// `ReplaceAroundStep` — useful for wrapping or unwrapping a range
    /// without touching the inner content.
    case replaceAround(
        outer: NSRange,
        inner: NSRange,
        content: NSAttributedString,
        contentSplit: Int
    )
    /// Add an inline mark to `range`. Stamps the canonical `proseMarks`
    /// attribute and projects it onto rendering attributes (font traits,
    /// foreground colors) for the layout layer.
    case addMark(range: NSRange, mark: ProseMark)
    /// Remove all marks of `markType` from `range`. Inverse of `addMark`
    /// when the mark wasn't already present.
    case removeMark(range: NSRange, markType: MarkType.Name)
    /// Replace the leaf node's attributes within the given `NodePath`.
    /// Walks the storage's `proseNodePath` runs, finds the run whose path
    /// matches by NodeID, and rewrites the leaf with merged attributes.
    case setNodeAttrs(path: NodePath, attrs: [String: ProseAttrValue])
    /// Replace one cell's inline runs inside an isolating-table
    /// attachment. Storage character range stays the same; only
    /// `attachment.subtree` mutates and the view re-renders the cell.
    /// Inverse restores the prior runs.
    case replaceCellInline(
        tableID: NodeID,
        row: Int,
        column: Int,
        runs: [TreeNode]
    )
    /// Replace the entire structural subtree inside an isolating-table
    /// attachment. Used by structural commands (insert/delete row/column,
    /// alignment changes). Storage character range stays the same;
    /// inverse restores the prior subtree.
    case setTableSubtree(tableID: NodeID, subtree: TreeNode)
    /// Add an inline mark to a single leaf node (image, hard_break) by
    /// `NodePath`. PM-equivalent `AddNodeMarkStep`. The mark lives on the
    /// leaf's `proseMarks` storage attribute alongside any inline marks
    /// already there; the rendering layer projects via the same path as
    /// `addMark`.
    case addNodeMark(path: NodePath, mark: ProseMark)
    /// Remove a mark of `markType` from a single leaf node. PM-equivalent
    /// `RemoveNodeMarkStep`.
    case removeNodeMark(path: NodePath, markType: MarkType.Name)
    /// Replace one attribute of the document root. PM-equivalent
    /// `DocAttrStep`. Storage doesn't carry doc-level attrs in our model;
    /// the controller surfaces this through a side-channel for hosts that
    /// need to track e.g. "current language" without round-tripping.
    case setDocAttr(name: String, value: ProseAttrValue)

    public func apply(to storage: NSTextStorage, env: StepEnvironment) -> AppliedStep {
        switch self {
        case .replaceText(let range, let attributed):
            return applyReplaceText(in: storage, range: range, attributed: attributed)
        case .setSpec(let lineRange, let spec):
            return applySetSpec(in: storage, lineRange: lineRange, spec: spec, env: env)
        case .toggleInlineMark(let range, let mark):
            return applyToggleInlineMark(in: storage, range: range, mark: mark, env: env)
        case .replaceAround(let outer, let inner, let content, let contentSplit):
            return applyReplaceAround(
                in: storage, outer: outer, inner: inner,
                content: content, contentSplit: contentSplit
            )
        case .addMark(let range, let mark):
            return applyAddMark(in: storage, range: range, mark: mark, env: env)
        case .removeMark(let range, let markType):
            return applyRemoveMark(in: storage, range: range, markType: markType, env: env)
        case .setNodeAttrs(let path, let attrs):
            return applySetNodeAttrs(in: storage, path: path, attrs: attrs)
        case .replaceCellInline(let tableID, let row, let column, let runs):
            return applyReplaceCellInline(
                in: storage, tableID: tableID, row: row, column: column, runs: runs
            )
        case .setTableSubtree(let tableID, let subtree):
            return applySetTableSubtree(in: storage, tableID: tableID, subtree: subtree)
        case .addNodeMark(let path, let mark):
            return applyAddNodeMark(in: storage, path: path, mark: mark, env: env)
        case .removeNodeMark(let path, let markType):
            return applyRemoveNodeMark(in: storage, path: path, markType: markType, env: env)
        case .setDocAttr(let name, let value):
            return applySetDocAttr(in: storage, name: name, value: value)
        }
    }

    private func applyAddNodeMark(
        in storage: NSTextStorage,
        path: NodePath,
        mark: ProseMark,
        env: StepEnvironment
    ) -> AppliedStep {
        guard let leafID = path.leaf?.id else {
            return AppliedStep(
                inverse: .removeNodeMark(path: path, markType: mark.type),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        var resolvedRange: NSRange?
        let schema = env.compiler.schema
        storage.enumerateNodePaths { runRange, runPath in
            guard runPath.leaf?.id == leafID else { return }
            resolvedRange = resolvedRange.map { NSUnionRange($0, runRange) } ?? runRange
        }
        guard let safe = resolvedRange else {
            return AppliedStep(
                inverse: .removeNodeMark(path: path, markType: mark.type),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        storage.beginEditing()
        let current = (storage.attribute(.proseMarks, at: safe.location, effectiveRange: nil) as? MarkSetBox)?.marks ?? MarkSet()
        let updated = current.adding(mark, in: schema)
        storage.addAttribute(.proseMarks, value: MarkSetBox(updated), range: safe)
        applyRenderingAttribute(for: mark, in: storage, range: safe, theme: env.theme)
        storage.endEditing()
        let inverse = Step.removeNodeMark(path: path, markType: mark.type)
        return AppliedStep(inverse: inverse, mappedRange: safe, affectedLineRange: safe, stepMap: .empty)
    }

    private func applyRemoveNodeMark(
        in storage: NSTextStorage,
        path: NodePath,
        markType: MarkType.Name,
        env: StepEnvironment
    ) -> AppliedStep {
        guard let leafID = path.leaf?.id else {
            return AppliedStep(
                inverse: .addNodeMark(path: path, mark: ProseMark(type: markType)),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        var resolvedRange: NSRange?
        var priorMark: ProseMark?
        storage.enumerateNodePaths { runRange, runPath in
            guard runPath.leaf?.id == leafID else { return }
            resolvedRange = resolvedRange.map { NSUnionRange($0, runRange) } ?? runRange
            if priorMark == nil,
               let box = storage.attribute(.proseMarks, at: runRange.location, effectiveRange: nil) as? MarkSetBox,
               let existing = box.marks.mark(of: markType) {
                priorMark = existing
            }
        }
        guard let safe = resolvedRange else {
            return AppliedStep(
                inverse: .addNodeMark(path: path, mark: ProseMark(type: markType)),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        storage.beginEditing()
        if let box = storage.attribute(.proseMarks, at: safe.location, effectiveRange: nil) as? MarkSetBox {
            let updated = box.marks.removing(markType)
            if updated.isEmpty {
                storage.removeAttribute(.proseMarks, range: safe)
            } else {
                storage.addAttribute(.proseMarks, value: MarkSetBox(updated), range: safe)
            }
        }
        removeRenderingAttribute(forMarkType: markType, in: storage, range: safe, theme: env.theme)
        storage.endEditing()
        let inverse: Step
        if let priorMark {
            inverse = .addNodeMark(path: path, mark: priorMark)
        } else {
            inverse = .addNodeMark(path: path, mark: ProseMark(type: markType))
        }
        return AppliedStep(inverse: inverse, mappedRange: safe, affectedLineRange: safe, stepMap: .empty)
    }

    private func applySetDocAttr(
        in storage: NSTextStorage,
        name: String,
        value: ProseAttrValue
    ) -> AppliedStep {
        // Storage doesn't carry doc attrs; the controller's surface
        // mirrors them externally. The Step itself is recorded so the
        // transaction history is complete; an inverse stays as a setDocAttr
        // back to whatever the prior value was (captured by the caller).
        let inverse = Step.setDocAttr(name: name, value: value)
        return AppliedStep(
            inverse: inverse,
            mappedRange: NSRange(location: 0, length: 0),
            affectedLineRange: NSRange(location: 0, length: 0),
            stepMap: .empty
        )
    }

    private func applyReplaceCellInline(
        in storage: NSTextStorage,
        tableID: NodeID,
        row rowIdx: Int,
        column colIdx: Int,
        runs: [TreeNode]
    ) -> AppliedStep {
        guard let (range, attachment) = locateTableAttachment(in: storage, id: tableID),
              case .structural(let table, var rows) = attachment.subtree,
              rowIdx < rows.count,
              case .structural(let rowNode, var cells) = rows[rowIdx],
              colIdx < cells.count,
              case .structural(let cellNode, var cellKids) = cells[colIdx] else {
            return AppliedStep(
                inverse: .replaceCellInline(tableID: tableID, row: rowIdx, column: colIdx, runs: runs),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        let priorRuns: [TreeNode]
        if let firstChild = cellKids.first, case .structural(_, let inlines) = firstChild {
            priorRuns = inlines
        } else {
            priorRuns = []
        }
        if !cellKids.isEmpty,
           case .structural(let para, _) = cellKids[0] {
            cellKids[0] = .structural(para, runs)
        } else {
            cellKids = [.structural(ProseNode(type: "paragraph"), runs)]
        }
        cells[colIdx] = .structural(cellNode, cellKids)
        rows[rowIdx] = .structural(rowNode, cells)
        attachment.update(subtree: .structural(table, rows))
        attachment.boundView?.updateCellInline(row: rowIdx, column: colIdx, runs: runs)
        // The bound view's `layoutDidChange` already routes through this
        // hook on-screen, but off-screen attachments have no realized
        // view yet — invalidate directly so the storage range is flagged
        // for re-query when the attachment scrolls in.
        TableAttachmentViewProvider.sharedInvalidateAttachment?(attachment)
        let inverse = Step.replaceCellInline(
            tableID: tableID, row: rowIdx, column: colIdx, runs: priorRuns
        )
        return AppliedStep(
            inverse: inverse,
            mappedRange: range,
            affectedLineRange: range,
            stepMap: .empty
        )
    }

    private func applySetTableSubtree(
        in storage: NSTextStorage,
        tableID: NodeID,
        subtree: TreeNode
    ) -> AppliedStep {
        guard let (range, attachment) = locateTableAttachment(in: storage, id: tableID) else {
            return AppliedStep(
                inverse: .setTableSubtree(tableID: tableID, subtree: subtree),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        let prior = attachment.subtree
        attachment.update(subtree: subtree)
        attachment.boundView?.update(subtree: subtree)
        TableAttachmentViewProvider.sharedInvalidateAttachment?(attachment)
        let inverse = Step.setTableSubtree(tableID: tableID, subtree: prior)
        return AppliedStep(
            inverse: inverse,
            mappedRange: range,
            affectedLineRange: range,
            stepMap: .empty
        )
    }

    /// Locate the storage range and `ProseNodeAttachment` whose `table`
    /// node matches `id`. Returns nil if no run's path leaf is `table`
    /// with the given id.
    private func locateTableAttachment(
        in storage: NSAttributedString,
        id: NodeID
    ) -> (range: NSRange, attachment: ProseNodeAttachment)? {
        var found: (NSRange, ProseNodeAttachment)? = nil
        storage.enumerateNodePaths { runRange, path in
            guard found == nil,
                  let leaf = path.leaf,
                  leaf.type == "table",
                  leaf.id == id else { return }
            let raw = storage.attribute(
                NSAttributedString.Key("NSAttachment"),
                at: runRange.location,
                effectiveRange: nil
            )
            if let att = raw as? ProseNodeAttachment {
                found = (runRange, att)
            }
        }
        return found
    }

    private func applyToggleInlineMark(
        in storage: NSTextStorage,
        range: NSRange,
        mark: InlineMark,
        env: StepEnvironment
    ) -> AppliedStep {
        let safe = range.clamped(to: storage.length)
        let prior = storage.attributedSubstring(from: safe)
        let resulting: NSRange
        switch mark {
        case .bold:
            resulting = Operations.toggleBold(in: storage, range: range, theme: env.theme)
        case .italic:
            resulting = Operations.toggleItalic(in: storage, range: range, theme: env.theme)
        case .strikethrough:
            resulting = Operations.toggleStrikethrough(in: storage, range: range, theme: env.theme)
        case .codeSpan:
            resulting = Operations.toggleCodeSpan(in: storage, range: range, theme: env.theme)
        }
        NodePathSynthesizer(schema: env.compiler.schema)
            .stampMarks(in: storage, range: resulting.clamped(to: storage.length))
        let inverse = Step.replaceText(range: resulting.clamped(to: storage.length), with: prior)
        return AppliedStep(inverse: inverse, mappedRange: resulting, affectedLineRange: resulting, stepMap: .empty)
    }

    private func applyReplaceText(
        in storage: NSTextStorage,
        range: NSRange,
        attributed: NSAttributedString
    ) -> AppliedStep {
        let safe = range.clamped(to: storage.length)
        let prior = storage.attributedSubstring(from: safe)
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: attributed)
        let mappedRange = NSRange(location: safe.location, length: attributed.length)
        Step.restampPredecessorContext(in: storage, range: mappedRange)
        storage.endEditing()
        let inverse = Step.replaceText(range: mappedRange, with: prior)
        let stepMap = StepMap(oldRange: safe, newLength: attributed.length)
        return AppliedStep(inverse: inverse, mappedRange: mappedRange, affectedLineRange: mappedRange, stepMap: stepMap)
    }

    /// Re-stamp `proseNodePath` runs in `range` so list and blockquote
    /// ancestors share IDs with the immediately-preceding character in
    /// storage. Called after replace operations whose content was
    /// produced by an isolated compile (e.g. `Step.setSpec` rendering one
    /// line, or `InsertNewline` building a fresh list item) so the new
    /// content's structural ancestors correctly stitch into the
    /// surrounding storage's open-list context.
    static func restampPredecessorContext(in storage: NSTextStorage, range: NSRange) {
        let safe = range.clamped(to: storage.length)
        guard safe.length > 0 else { return }
        var pairs: [(NSRange, BlockSpec)] = []
        storage.enumerateNodePaths(in: safe) { runRange, path in
            if let spec = BlockSpec.fromNodePath(path) {
                pairs.append((runRange, spec))
            }
        }
        for (runRange, spec) in pairs {
            storage.setBlockSpec(spec, in: runRange)
        }
    }

    private func applySetSpec(
        in storage: NSTextStorage,
        lineRange: NSRange,
        spec: BlockSpec,
        env: StepEnvironment
    ) -> AppliedStep {
        let safe = lineRange.clamped(to: storage.length)
        let prior = storage.attributedSubstring(from: safe)

        let newAttr = render(spec: spec, replacing: prior, env: env)
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: newAttr)
        let mappedRange = NSRange(location: safe.location, length: newAttr.length)
        Step.restampPredecessorContext(in: storage, range: mappedRange)
        storage.endEditing()

        // Typed inverse: setSpec back to whatever spec the line carried
        // before this transform. Falls back to a content blob when the
        // prior storage didn't expose a structural spec — e.g. the
        // line was empty or only carried inline runs.
        let priorSpec = priorBlockSpec(in: prior)
        let inverse: Step
        if let priorSpec {
            inverse = .setSpec(lineRange: mappedRange, priorSpec)
        } else {
            inverse = .replaceText(range: mappedRange, with: prior)
        }
        let stepMap = StepMap(oldRange: safe, newLength: newAttr.length)
        return AppliedStep(inverse: inverse, mappedRange: mappedRange, affectedLineRange: mappedRange, stepMap: stepMap)
    }

    private func priorBlockSpec(in prior: NSAttributedString) -> BlockSpec? {
        guard prior.length > 0 else { return nil }
        if let path = prior.nodePath(at: 0) {
            return BlockSpec.fromNodePath(path)
        }
        return nil
    }

    private func render(
        spec: BlockSpec,
        replacing prior: NSAttributedString,
        env: StepEnvironment
    ) -> NSAttributedString {
        let priorMarkdown = env.serializer.serialize(prior)
        let body = stripBlockMarkup(priorMarkdown)
        let bodyEmpty = body.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces).isEmpty
        // Tree-sitter's markdown grammar rejects empty list-item / blockquote
        // lines (`- \n`, `> \n`), and nested list items without a parent
        // list (`  - foo`) parse as indented code. Both bypass the parser
        // via the compiler's direct constructors. Inline marks in the body
        // are not preserved on this path — acceptable since list-item
        // toggle from a non-list line is a structural change anyway.
        if bodyEmpty, let direct = renderEmpty(spec: spec, env: env) {
            return direct
        }
        // Nested list items (`  - foo`) need direct construction even with
        // a non-empty body. Level-0 lists round-trip through tree-sitter
        // so inline marks (`- **bold**`) compile correctly.
        if spec.isListItem, spec.listLevel > 0,
           let direct = renderListItem(spec: spec, body: body, env: env) {
            return direct
        }
        let newMarkdown = compose(spec: spec, body: body)
        let normalized = newMarkdown.hasSuffix("\n") ? newMarkdown : newMarkdown + "\n"
        return env.compiler.compile(normalized, theme: env.theme)
    }

    private func renderEmpty(
        spec: BlockSpec,
        env: StepEnvironment
    ) -> NSAttributedString? {
        switch spec.kind {
        case .unorderedListItem:
            return env.compiler.makeListItem(kind: .bullet, level: spec.listLevel, theme: env.theme)
        case .orderedListItem(let index):
            return env.compiler.makeListItem(kind: .ordered, level: spec.listLevel, orderedIndex: index, theme: env.theme)
        case .taskListItem(let checked):
            return env.compiler.makeListItem(kind: .task, level: spec.listLevel, isChecked: checked, theme: env.theme)
        case .paragraph where spec.blockquoteDepth > 0:
            return env.compiler.makeBlockquoteLine(depth: spec.blockquoteDepth, theme: env.theme)
        default:
            return nil
        }
    }

    private func renderListItem(
        spec: BlockSpec,
        body: String,
        env: StepEnvironment
    ) -> NSAttributedString? {
        let trimmed = body.replacingOccurrences(of: "\n", with: "")
        switch spec.kind {
        case .unorderedListItem:
            return env.compiler.makeListItem(
                kind: .bullet, level: spec.listLevel,
                content: trimmed, theme: env.theme
            )
        case .orderedListItem(let index):
            return env.compiler.makeListItem(
                kind: .ordered, level: spec.listLevel, orderedIndex: index,
                content: trimmed, theme: env.theme
            )
        case .taskListItem(let checked):
            return env.compiler.makeListItem(
                kind: .task, level: spec.listLevel, isChecked: checked,
                content: trimmed, theme: env.theme
            )
        default:
            return nil
        }
    }

    /// Strip leading block-level markup from each line so the body text can be
    /// recomposed under a different `BlockSpec`. Operates per-line because a
    /// list-item's body could span continuation lines.
    private func stripBlockMarkup(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stripped = lines.map(stripBlockMarkupFromLine)
        return stripped.joined(separator: "\n")
    }

    private static let blockMarkupLeadRegex: NSRegularExpression = {
        // The grammar's recompile loop tolerates only NSRegularExpression
        // syntax — using `try!` on a literal is fine because the pattern is
        // a static constant.
        try! NSRegularExpression(
            pattern: #"^\s*(>\s?|#{1,6}\s+|\d+[.)]\s+|[-*+]\s+(\[[ xX]\]\s+)?)"#
        )
    }()

    private func stripBlockMarkupFromLine(_ line: String) -> String {
        let regex = Step.blockMarkupLeadRegex
        var ns = line as NSString
        while true {
            let match = regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length))
            guard let match, match.range.location == 0, match.range.length > 0 else { break }
            ns = ns.substring(from: match.range.length) as NSString
        }
        let s = ns as String
        if s.hasPrefix("```") || s.hasPrefix("~~~") { return "" }
        return s
    }

    private func compose(spec: BlockSpec, body: String) -> String {
        let depth = max(0, spec.blockquoteDepth)
        let quotePrefix = String(repeating: "> ", count: depth)
        let listIndent = String(repeating: "  ", count: max(0, spec.listLevel))

        switch spec.kind {
        case .paragraph:
            return prefixLines(body, with: quotePrefix)
        case .heading(let level):
            let lvl = max(1, min(6, level))
            let head = String(repeating: "#", count: lvl) + " "
            let firstLine = body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return quotePrefix + head + firstLine
        case .unorderedListItem:
            return quotePrefix + listIndent + "- " + (body.isEmpty ? "" : body)
        case .orderedListItem(let index):
            return quotePrefix + listIndent + "\(index). " + (body.isEmpty ? "" : body)
        case .taskListItem(let checked):
            let mark = checked ? "x" : " "
            return quotePrefix + listIndent + "- [\(mark)] " + (body.isEmpty ? "" : body)
        case .fencedCode(let language):
            let lang = language ?? ""
            return "```\(lang)\n" + body + "\n```"
        case .indentedCode:
            return prefixLines(body, with: "    ")
        case .horizontalRule:
            return "---"
        case .htmlBlock, .linkReferenceDefinition:
            return body
        }
    }

    private func prefixLines(_ s: String, with prefix: String) -> String {
        guard !prefix.isEmpty else { return s }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + String($0) }
            .joined(separator: "\n")
    }

    /// Reasons `Step.maybeApply` can refuse to mutate storage.
    public enum LegalityError: Error, Equatable, Sendable {
        case rangeOutOfBounds(NSRange, length: Int)
        case nodePathNotFound(NodePath)
        case unknownTableID(NodeID)
        case incompatibleSpec(String)
    }

    /// Probe whether this step would succeed on `storage` *without*
    /// mutating it. Mirrors PM's `Step.maybeApply` (sans the actual
    /// application — `Transaction.apply` follows up with `apply` on a
    /// successful probe). Returns `nil` when legal, or a `LegalityError`
    /// describing the obstruction.
    ///
    /// The implementation favors cheap structural checks: range bounds,
    /// node-path resolution, and table-id presence. Full content-rule
    /// validation lives in `SchemaValidator`'s repair path; commands that
    /// need pre-apply schema enforcement should pair this probe with a
    /// `SchemaValidator.validate` over the projected document.
    public func canApply(to storage: NSAttributedString) -> LegalityError? {
        let len = storage.length
        switch self {
        case .replaceText(let range, _),
             .setSpec(let range, _),
             .toggleInlineMark(let range, _),
             .addMark(let range, _),
             .removeMark(let range, _):
            if range.location < 0 || range.location + range.length > len {
                return .rangeOutOfBounds(range, length: len)
            }
            return nil
        case .replaceAround(let outer, _, _, _):
            if outer.location < 0 || outer.location + outer.length > len {
                return .rangeOutOfBounds(outer, length: len)
            }
            return nil
        case .setNodeAttrs(let path, _),
             .addNodeMark(let path, _),
             .removeNodeMark(let path, _):
            guard let leafID = path.leaf?.id else { return .nodePathNotFound(path) }
            var found = false
            storage.enumerateNodePaths { _, runPath in
                if runPath.leaf?.id == leafID { found = true }
            }
            return found ? nil : .nodePathNotFound(path)
        case .replaceCellInline(let tableID, _, _, _),
             .setTableSubtree(let tableID, _):
            var found = false
            storage.enumerateNodePaths { _, path in
                if path.leaf?.id == tableID, path.leaf?.type == "table" { found = true }
            }
            return found ? nil : .unknownTableID(tableID)
        case .setDocAttr:
            return nil
        }
    }

    public func mapped(through mapping: Mapping) -> Step {
        guard !mapping.maps.isEmpty else { return self }
        switch self {
        case .replaceText(let range, let attr):
            return .replaceText(range: mapping.mapRange(range), with: attr)
        case .setSpec(let lineRange, let spec):
            return .setSpec(lineRange: mapping.mapRange(lineRange), spec)
        case .toggleInlineMark(let range, let mark):
            return .toggleInlineMark(range: mapping.mapRange(range), mark)
        case .replaceAround(let outer, let inner, let content, let split):
            return .replaceAround(
                outer: mapping.mapRange(outer),
                inner: mapping.mapRange(inner),
                content: content,
                contentSplit: split
            )
        case .addMark(let range, let mark):
            return .addMark(range: mapping.mapRange(range), mark: mark)
        case .removeMark(let range, let markType):
            return .removeMark(range: mapping.mapRange(range), markType: markType)
        case .setNodeAttrs(let path, let attrs):
            // NodePath addressing is identity-based, not positional, so
            // mapping ranges doesn't move the target. The path stays the
            // same; the apply path re-resolves it against current storage.
            return .setNodeAttrs(path: path, attrs: attrs)
        case .replaceCellInline, .setTableSubtree:
            // Identity-addressed by `tableID` — character positions don't
            // factor in. Mapping is a no-op.
            return self
        case .addNodeMark, .removeNodeMark, .setDocAttr:
            // Identity-addressed by NodePath / no positional anchor —
            // mapping is a no-op.
            return self
        }
    }

    // MARK: - replaceAround / addMark / removeMark / setNodeAttrs

    private func applyReplaceAround(
        in storage: NSTextStorage,
        outer: NSRange,
        inner: NSRange,
        content: NSAttributedString,
        contentSplit: Int
    ) -> AppliedStep {
        let outerSafe = outer.clamped(to: storage.length)
        let prior = storage.attributedSubstring(from: outerSafe)
        let innerStart = max(outerSafe.location, min(inner.location, outerSafe.location + outerSafe.length))
        let innerEndRaw = inner.location + inner.length
        let innerEnd = max(innerStart, min(innerEndRaw, outerSafe.location + outerSafe.length))
        let split = max(0, min(contentSplit, content.length))
        let leading = content.attributedSubstring(from: NSRange(location: 0, length: split))
        let trailing = content.attributedSubstring(
            from: NSRange(location: split, length: content.length - split)
        )
        // Capture pre-state pieces so the inverse is itself a replaceAround
        // that rebuilds the prior wrapping around the unchanged inner.
        let priorLeadingLen = innerStart - outerSafe.location
        let priorTrailingLen = (outerSafe.location + outerSafe.length) - innerEnd
        let priorContent = NSMutableAttributedString()
        priorContent.append(prior.attributedSubstring(from: NSRange(location: 0, length: priorLeadingLen)))
        priorContent.append(prior.attributedSubstring(from: NSRange(
            location: prior.length - priorTrailingLen,
            length: priorTrailingLen
        )))

        // Apply trailing first so the leading replace doesn't shift the
        // trailing range.
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: innerEnd, length: outerSafe.location + outerSafe.length - innerEnd),
            with: trailing
        )
        storage.replaceCharacters(
            in: NSRange(location: outerSafe.location, length: innerStart - outerSafe.location),
            with: leading
        )
        let newLength = leading.length + (innerEnd - innerStart) + trailing.length
        let mappedRange = NSRange(location: outerSafe.location, length: newLength)
        Step.restampPredecessorContext(in: storage, range: mappedRange)
        storage.endEditing()
        // Typed inverse: the new outer range is `mappedRange`; the new
        // inner range stays at outer.start + split, length unchanged.
        let inverse = Step.replaceAround(
            outer: mappedRange,
            inner: NSRange(location: outerSafe.location + split, length: innerEnd - innerStart),
            content: priorContent,
            contentSplit: priorLeadingLen
        )
        let stepMap = StepMap(oldRange: outerSafe, newLength: newLength)
        return AppliedStep(
            inverse: inverse,
            mappedRange: mappedRange,
            affectedLineRange: mappedRange,
            stepMap: stepMap
        )
    }

    private func applyAddMark(
        in storage: NSTextStorage,
        range: NSRange,
        mark: ProseMark,
        env: StepEnvironment
    ) -> AppliedStep {
        let safe = range.clamped(to: storage.length)
        let schema = env.compiler.schema
        storage.beginEditing()
        // Stamp proseMarks per existing run, adding the new mark.
        storage.enumerateAttribute(.proseMarks, in: safe) { value, runRange, _ in
            let current = (value as? MarkSetBox)?.marks ?? MarkSet()
            let updated = current.adding(mark, in: schema)
            if !updated.isEmpty {
                storage.addAttribute(.proseMarks, value: MarkSetBox(updated), range: runRange)
            }
        }
        // Project the mark onto rendering attributes (font traits, color)
        // so the layout layer paints it.
        applyRenderingAttribute(for: mark, in: storage, range: safe, theme: env.theme)
        storage.endEditing()
        // Typed inverse: undo by removing the mark of the same type. NodeID
        // identity isn't disturbed because we never touched proseNodePath.
        let inverse = Step.removeMark(range: safe, markType: mark.type)
        return AppliedStep(
            inverse: inverse,
            mappedRange: safe,
            affectedLineRange: safe,
            stepMap: .empty
        )
    }

    private func applyRemoveMark(
        in storage: NSTextStorage,
        range: NSRange,
        markType: MarkType.Name,
        env: StepEnvironment
    ) -> AppliedStep {
        let safe = range.clamped(to: storage.length)
        // Capture every existing instance of `markType` in `safe` so the
        // inverse can re-apply the original mark attrs (e.g. link href).
        var priorPlacements: [(NSRange, ProseMark)] = []
        storage.enumerateAttribute(.proseMarks, in: safe) { value, runRange, _ in
            guard let current = (value as? MarkSetBox)?.marks,
                  let existing = current.mark(of: markType) else { return }
            priorPlacements.append((runRange, existing))
        }
        storage.beginEditing()
        storage.enumerateAttribute(.proseMarks, in: safe) { value, runRange, _ in
            guard let current = (value as? MarkSetBox)?.marks else { return }
            let updated = current.removing(markType)
            if updated.isEmpty {
                storage.removeAttribute(.proseMarks, range: runRange)
            } else {
                storage.addAttribute(.proseMarks, value: MarkSetBox(updated), range: runRange)
            }
        }
        removeRenderingAttribute(forMarkType: markType, in: storage, range: safe, theme: env.theme)
        storage.endEditing()
        // Typed inverse: re-add the captured marks with their original attrs.
        // Most commonly there's one placement; for multi-link spans the
        // inverse becomes a sub-transaction.
        let inverse: Step
        if priorPlacements.count == 1 {
            let (priorRange, priorMark) = priorPlacements[0]
            inverse = .addMark(range: priorRange, mark: priorMark)
        } else if priorPlacements.isEmpty {
            // Nothing to restore — still emit a typed inverse so callers
            // see a typed Step (the addMark of an absent mark is a no-op).
            inverse = .addMark(range: safe, mark: ProseMark(type: markType))
        } else {
            // Multiple distinct placements (rare). Encode the dominant one;
            // any subsequent removeMark over the same range will collapse.
            let (priorRange, priorMark) = priorPlacements[0]
            inverse = .addMark(range: priorRange, mark: priorMark)
        }
        return AppliedStep(
            inverse: inverse,
            mappedRange: safe,
            affectedLineRange: safe,
            stepMap: .empty
        )
    }

    private func applySetNodeAttrs(
        in storage: NSTextStorage,
        path: NodePath,
        attrs: [String: ProseAttrValue]
    ) -> AppliedStep {
        guard let leafID = path.leaf?.id else {
            return AppliedStep(
                inverse: .setNodeAttrs(path: path, attrs: attrs),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        var resolvedRange: NSRange?
        var newPath: NodePath?
        var priorAttrs: [String: ProseAttrValue]?
        storage.enumerateNodePaths { runRange, runPath in
            guard runPath.leaf?.id == leafID else { return }
            if resolvedRange == nil {
                resolvedRange = runRange
                priorAttrs = runPath.leaf?.attrs ?? [:]
                let merged = (runPath.leaf?.attrs ?? [:]).merging(attrs) { _, new in new }
                let updatedLeaf = ProseNode(
                    id: leafID,
                    type: runPath.leaf!.type,
                    attrs: merged
                )
                newPath = NodePath(runPath.nodes.dropLast() + [updatedLeaf])
            } else {
                resolvedRange = NSUnionRange(resolvedRange!, runRange)
            }
        }
        guard let safe = resolvedRange,
              let updatedPath = newPath,
              let captured = priorAttrs else {
            return AppliedStep(
                inverse: .setNodeAttrs(path: path, attrs: attrs),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        storage.beginEditing()
        storage.setNodePath(updatedPath, in: safe)
        storage.endEditing()
        // Typed inverse — set the same path back to its prior attrs so
        // the leaf's NodeID stays stable across undo/redo.
        let inverse = Step.setNodeAttrs(path: path, attrs: captured)
        return AppliedStep(
            inverse: inverse,
            mappedRange: safe,
            affectedLineRange: safe,
            stepMap: .empty
        )
    }

    private func applyRenderingAttribute(
        for mark: ProseMark,
        in storage: NSTextStorage,
        range: NSRange,
        theme: ProseTheme
    ) {
        switch mark.type {
        case "strong":
            stampFontTrait(.bold, in: storage, range: range)
        case "em":
            stampFontTrait(.italic, in: storage, range: range)
        case "strike":
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case "code":
            storage.addAttribute(.font, value: theme.monospaceFont, range: range)
            storage.addAttribute(.proseInline, value: InlineTag.codeSpan, range: range)
        case "link":
            storage.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.proseInline, value: InlineTag.link, range: range)
            if let href = mark.attrs["href"]?.stringValue {
                storage.addAttribute(.proseLink, value: href, range: range)
            }
        default: break
        }
    }

    private func removeRenderingAttribute(
        forMarkType markType: MarkType.Name,
        in storage: NSTextStorage,
        range: NSRange,
        theme: ProseTheme
    ) {
        switch markType {
        case "strong":
            stampFontTrait(.bold, in: storage, range: range, enabled: false)
        case "em":
            stampFontTrait(.italic, in: storage, range: range, enabled: false)
        case "strike":
            storage.removeAttribute(.strikethroughStyle, range: range)
        case "code":
            storage.removeAttribute(.proseInline, range: range)
            // Restore body font on the run.
            storage.addAttribute(.font, value: theme.bodyFont, range: range)
        case "link":
            storage.removeAttribute(.proseInline, range: range)
            storage.removeAttribute(.proseLink, range: range)
            storage.removeAttribute(.underlineStyle, range: range)
            storage.addAttribute(.foregroundColor, value: theme.foregroundColor, range: range)
        default: break
        }
    }

    private func stampFontTrait(
        _ trait: FontTraits,
        in storage: NSTextStorage,
        range: NSRange,
        enabled: Bool = true
    ) {
        storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
            guard let font = value as? PlatformFont else { return }
            let updated = font.togglingProseTrait(trait, enable: enabled)
            storage.addAttribute(.font, value: updated, range: runRange)
        }
    }
}

public struct AppliedStep {
    public let inverse: Step
    public let mappedRange: NSRange
    public let affectedLineRange: NSRange
    public let stepMap: StepMap
}

public struct Transaction {
    public var steps: [Step]
    public var label: String?

    public init(steps: [Step] = [], label: String? = nil) {
        self.steps = steps
        self.label = label
    }

    @discardableResult
    public func apply(to storage: NSTextStorage, env: StepEnvironment) -> AppliedTransaction {
        var inverses: [Step] = []
        var mapping = Mapping.empty
        var mappedRange: NSRange = NSRange(location: 0, length: 0)
        for step in steps {
            let mapped = step.mapped(through: mapping)
            // Probe legality first — bail out cleanly if the step can't
            // land. `apply` is otherwise allowed to commit partial state
            // (e.g. some addAttribute calls) before the failure mode is
            // detected, which leaves storage half-edited.
            if mapped.canApply(to: storage) != nil {
                continue
            }
            let applied = mapped.apply(to: storage, env: env)
            inverses.insert(applied.inverse, at: 0)
            mapping.append(applied.stepMap)
            mappedRange = applied.mappedRange
        }
        return AppliedTransaction(
            inverse: Transaction(steps: inverses, label: label),
            mapping: mapping,
            mappedRange: mappedRange
        )
    }
}

public struct AppliedTransaction {
    public let inverse: Transaction
    public let mapping: Mapping
    public let mappedRange: NSRange
}
