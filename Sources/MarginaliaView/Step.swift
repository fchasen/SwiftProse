import Foundation
import MarginaliaSyntax
import MarginaliaRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct StepEnvironment {
    public let compiler: MarkdownAttributedCompiler
    public let serializer: AttributedMarkdownSerializer
    public let theme: MarginaliaTheme
    public let dialect: Dialect
    public let mode: Mode

    public init(
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: MarginaliaTheme,
        dialect: Dialect,
        mode: Mode
    ) {
        self.compiler = compiler
        self.serializer = serializer
        self.theme = theme
        self.dialect = dialect
        self.mode = mode
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

    public func apply(to storage: NSTextStorage, env: StepEnvironment) -> AppliedStep {
        switch self {
        case .replaceText(let range, let attributed):
            return applyReplaceText(in: storage, range: range, attributed: attributed)
        case .setSpec(let lineRange, let spec):
            return applySetSpec(in: storage, lineRange: lineRange, spec: spec, env: env)
        case .toggleInlineMark(let range, let mark):
            return applyToggleInlineMark(in: storage, range: range, mark: mark, env: env)
        }
    }

    private func applyToggleInlineMark(
        in storage: NSTextStorage,
        range: NSRange,
        mark: InlineMark,
        env: StepEnvironment
    ) -> AppliedStep {
        let safe = clamp(range, in: storage.length)
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
        let after = storage.attributedSubstring(from: clamp(resulting, in: storage.length))
        let inverse = Step.replaceText(range: clamp(resulting, in: storage.length), with: prior)
        _ = after
        return AppliedStep(inverse: inverse, mappedRange: resulting, affectedLineRange: resulting)
    }

    private func applyReplaceText(
        in storage: NSTextStorage,
        range: NSRange,
        attributed: NSAttributedString
    ) -> AppliedStep {
        let safe = clamp(range, in: storage.length)
        let prior = storage.attributedSubstring(from: safe)
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: attributed)
        storage.endEditing()
        let mappedRange = NSRange(location: safe.location, length: attributed.length)
        let inverse = Step.replaceText(range: mappedRange, with: prior)
        return AppliedStep(inverse: inverse, mappedRange: mappedRange, affectedLineRange: mappedRange)
    }

    private func applySetSpec(
        in storage: NSTextStorage,
        lineRange: NSRange,
        spec: BlockSpec,
        env: StepEnvironment
    ) -> AppliedStep {
        let safe = clamp(lineRange, in: storage.length)
        let prior = storage.attributedSubstring(from: safe)

        let newAttr = render(spec: spec, replacing: prior, env: env)
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: newAttr)
        storage.endEditing()

        let mappedRange = NSRange(location: safe.location, length: newAttr.length)
        let inverse = Step.replaceText(range: mappedRange, with: prior)
        return AppliedStep(inverse: inverse, mappedRange: mappedRange, affectedLineRange: mappedRange)
    }

    private func render(
        spec: BlockSpec,
        replacing prior: NSAttributedString,
        env: StepEnvironment
    ) -> NSAttributedString {
        let priorMarkdown = env.serializer.serialize(prior, dialect: env.dialect)
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
        return env.compiler.compile(normalized, dialect: env.dialect, mode: env.mode, theme: env.theme)
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

    private func stripBlockMarkupFromLine(_ line: String) -> String {
        var s = line
        while let leadMatch = s.range(of: #"^\s*(>\s?|#{1,6}\s+|\d+[.)]\s+|[-*+]\s+(\[[ xX]\]\s+)?)"#,
                                       options: .regularExpression) {
            s = String(s[leadMatch.upperBound...])
        }
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

    private func clamp(_ range: NSRange, in length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        let remaining = max(0, length - location)
        return NSRange(location: location, length: max(0, min(range.length, remaining)))
    }
}

public struct AppliedStep {
    public let inverse: Step
    public let mappedRange: NSRange
    public let affectedLineRange: NSRange
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
        var mappedRange: NSRange = NSRange(location: 0, length: 0)
        for step in steps {
            let applied = step.apply(to: storage, env: env)
            inverses.insert(applied.inverse, at: 0)
            mappedRange = applied.mappedRange
        }
        return AppliedTransaction(inverse: Transaction(steps: inverses, label: label), mappedRange: mappedRange)
    }
}

public struct AppliedTransaction {
    public let inverse: Transaction
    public let mappedRange: NSRange
}
