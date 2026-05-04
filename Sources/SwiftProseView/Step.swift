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
    /// Add an inline mark to `range`. Stamps both the canonical
    /// `proseMarks` attribute and the legacy rendering attributes (font
    /// traits, foreground colors) so the existing layout fragment code
    /// continues to work during the migration.
    case addMark(range: NSRange, mark: ProseMark)
    /// Remove all marks of `markType` from `range`. Inverse of `addMark`
    /// when the mark wasn't already present.
    case removeMark(range: NSRange, markType: MarkType.Name)
    /// Replace the leaf node's attributes within the given `NodePath`.
    /// Walks the storage's `proseNodePath` runs, finds the run whose path
    /// matches by NodeID, and rewrites the leaf with merged attributes.
    case setNodeAttrs(path: NodePath, attrs: [String: ProseAttrValue])

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
        }
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
        storage.endEditing()
        let mappedRange = NSRange(location: safe.location, length: attributed.length)
        let inverse = Step.replaceText(range: mappedRange, with: prior)
        let stepMap = StepMap(oldRange: safe, newLength: attributed.length)
        return AppliedStep(inverse: inverse, mappedRange: mappedRange, affectedLineRange: mappedRange, stepMap: stepMap)
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
        storage.endEditing()

        let mappedRange = NSRange(location: safe.location, length: newAttr.length)
        let inverse = Step.replaceText(range: mappedRange, with: prior)
        let stepMap = StepMap(oldRange: safe, newLength: newAttr.length)
        return AppliedStep(inverse: inverse, mappedRange: mappedRange, affectedLineRange: mappedRange, stepMap: stepMap)
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
        case .htmlBlock, .linkReferenceDefinition, .pipeTable:
            return body
        }
    }

    private func prefixLines(_ s: String, with prefix: String) -> String {
        guard !prefix.isEmpty else { return s }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + String($0) }
            .joined(separator: "\n")
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
        }
    }

    // MARK: - new step variants (Phase 4)

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
        storage.endEditing()
        let newLength = leading.length + (innerEnd - innerStart) + trailing.length
        let mappedRange = NSRange(location: outerSafe.location, length: newLength)
        let inverse = Step.replaceText(range: mappedRange, with: prior)
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
        let prior = storage.attributedSubstring(from: safe)
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
        // Reflect the mark to legacy rendering attributes so the existing
        // layout fragment paints correctly until Phase 5/10 retire them.
        applyRenderingAttribute(for: mark, in: storage, range: safe, theme: env.theme)
        storage.endEditing()
        let inverse = Step.replaceText(range: safe, with: prior)
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
        let prior = storage.attributedSubstring(from: safe)
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
        let inverse = Step.replaceText(range: safe, with: prior)
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
                inverse: .replaceText(range: NSRange(location: 0, length: 0), with: NSAttributedString()),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        var resolvedRange: NSRange?
        var newPath: NodePath?
        storage.enumerateNodePaths { runRange, runPath in
            guard runPath.leaf?.id == leafID else { return }
            if resolvedRange == nil {
                resolvedRange = runRange
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
        guard let safe = resolvedRange, let updatedPath = newPath else {
            return AppliedStep(
                inverse: .replaceText(range: NSRange(location: 0, length: 0), with: NSAttributedString()),
                mappedRange: NSRange(location: 0, length: 0),
                affectedLineRange: NSRange(location: 0, length: 0),
                stepMap: .empty
            )
        }
        let prior = storage.attributedSubstring(from: safe)
        storage.beginEditing()
        storage.setNodePath(updatedPath, in: safe)
        storage.endEditing()
        let inverse = Step.replaceText(range: safe, with: prior)
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
