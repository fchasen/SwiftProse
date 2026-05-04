import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class AttributedMarkdownSerializer {
    /// Schema for the tree-driven emit path. Defaults to the markdown
    /// schema; callers with custom schemas can pass their own.
    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    public func serialize(_ attributed: NSAttributedString) -> String {
        let total = attributed.length
        guard total > 0 else { return "" }
        var out = ""
        var emittedSomething = false
        let fullRange = NSRange(location: 0, length: total)
        attributed.enumerateAttribute(.proseBlockSpec, in: fullRange) { value, range, _ in
            if emittedSomething { out.append("\n") }
            if let spec = (value as? BlockSpecBox)?.spec {
                out.append(emitBlock(spec, attributed: attributed, range: range))
            } else {
                out.append(attributed.attributedSubstring(from: range).string)
            }
            emittedSomething = true
        }
        return ensureTrailingNewline(out)
    }

    /// Tree-driven emit path. Reconstructs a `ProseDocument` from the
    /// storage's `proseNodePath` runs and walks it via
    /// `MarkdownTreeSerializer`. The result is byte-equivalent to
    /// `serialize(_:)` for compiler-produced storage that hasn't been
    /// mutated post-compile; once Step mutations go through Phase 4's
    /// tree-aware path and Phase 8's typing→tree sync lands, callers can
    /// flip to this path uniformly. Phase 3 ships it as opt-in.
    public func serializeFromTree(_ attributed: NSAttributedString) -> String {
        let tree = ProseDocument.from(storage: attributed, schema: schema)
        return MarkdownTreeSerializer(schema: schema).serialize(tree)
    }

    private func emitBlock(
        _ spec: BlockSpec,
        attributed: NSAttributedString,
        range: NSRange
    ) -> String {
        let inner = inlineMarkdown(of: attributed, range: range, in: spec)
        let trimmed = stripOneTrailingNewline(inner)
        let blockquotePrefix = String(repeating: "> ", count: max(0, spec.blockquoteDepth))
        let listIndent = String(repeating: "  ", count: max(0, spec.listLevel))

        switch spec.kind {
        case .heading(let level):
            let lvl = max(1, min(6, level))
            let prefix = String(repeating: "#", count: lvl) + " "
            return blockquotePrefix + prefix + trimmed
        case .paragraph:
            return prefixLines(trimmed, with: blockquotePrefix)
        case .unorderedListItem:
            return blockquotePrefix + listIndent + "- " + trimmed
        case .orderedListItem(let index):
            return blockquotePrefix + listIndent + "\(index). " + trimmed
        case .taskListItem(let checked):
            return blockquotePrefix + listIndent + "- [\(checked ? "x" : " ")] " + trimmed
        case .fencedCode(let language):
            let lang = language ?? ""
            let body = stripOneTrailingNewline(attributed.attributedSubstring(from: range).string)
            if body.hasPrefix("```") || body.hasPrefix("~~~") {
                return body
            }
            return "```\(lang)\n" + body + "\n```"
        case .indentedCode:
            let body = stripOneTrailingNewline(attributed.attributedSubstring(from: range).string)
            return body
        case .horizontalRule:
            return "---"
        case .htmlBlock, .linkReferenceDefinition, .pipeTable:
            return stripOneTrailingNewline(attributed.attributedSubstring(from: range).string)
        }
    }

    private func inlineMarkdown(
        of attributed: NSAttributedString,
        range: NSRange,
        in spec: BlockSpec
    ) -> String {
        var out = ""
        var cursor = range.location
        let end = range.location + range.length
        while cursor < end {
            var runRange = NSRange(location: cursor, length: 0)
            let attrs = attributed.safeAttributes(
                at: cursor,
                longestEffectiveRange: &runRange,
                in: NSRange(location: cursor, length: end - cursor)
            )
            let runLen = runRange.length > 0 ? runRange.length : 1
            let actualRange = NSRange(location: cursor, length: min(runLen, end - cursor))
            let runText = (attributed.string as NSString).substring(with: actualRange)
            out.append(emitInlineRun(text: runText, attrs: attrs, in: spec))
            cursor += actualRange.length
        }
        return out
    }

    private func paragraphImpliedBold(for spec: BlockSpec) -> Bool {
        if case .heading = spec.kind { return true }
        return false
    }

    private func emitInlineRun(
        text: String,
        attrs: [NSAttributedString.Key: Any],
        in spec: BlockSpec
    ) -> String {
        if text == "\n" { return "\n" }

        if attrs[.attachment] != nil {
            return ""
        }
        if let flag = attrs[.proseListMarker] as? Bool, flag {
            return ""
        }

        var content = text
        var prefix = ""
        var suffix = ""

        if let url = (attrs[.proseLink] as? String) ?? linkURLString(from: attrs[.link]) {
            let label = stripTrailingNewline(content)
            return "[\(label)](\(url))"
        }

        if let inline = attrs[.proseInline] as? InlineTag, inline == .codeSpan {
            let label = stripTrailingNewline(content)
            return "`\(label)`"
        }
        if let font = attrs[.font] as? PlatformFont, font.isMonospace {
            let label = stripTrailingNewline(content)
            return "`\(label)`"
        }

        if let font = attrs[.font] as? PlatformFont {
            let traits = font.proseTraits
            let bold = traits.contains(.bold) && !paragraphImpliedBold(for: spec)
            let italic = traits.contains(.italic)
            if bold && italic {
                prefix = "***"; suffix = "***"
            } else if bold {
                prefix = "**"; suffix = "**"
            } else if italic {
                prefix = "*"; suffix = "*"
            }
        }

        if let style = attrs[.strikethroughStyle] as? Int, style != 0 {
            prefix = "~~" + prefix
            suffix = suffix + "~~"
        }

        let (body, tail) = splitTrailingNewline(content)
        content = body
        return prefix + content + suffix + tail
    }

    // MARK: - helpers

    private func stripOneTrailingNewline(_ s: String) -> String {
        if s.hasSuffix("\n") { return String(s.dropLast()) }
        return s
    }

    private func stripTrailingNewline(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    private func splitTrailingNewline(_ s: String) -> (String, String) {
        if s.hasSuffix("\n") { return (String(s.dropLast()), "\n") }
        return (s, "")
    }

    private func ensureTrailingNewline(_ s: String) -> String {
        if s.isEmpty { return "" }
        if s.hasSuffix("\n") { return s }
        return s + "\n"
    }

    private func prefixLines(_ s: String, with prefix: String) -> String {
        guard !prefix.isEmpty else { return s }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + String($0) }
            .joined(separator: "\n")
    }

    private func linkURLString(from any: Any?) -> String? {
        if let url = any as? URL { return url.absoluteString }
        if let s = any as? String { return s }
        return nil
    }

}
