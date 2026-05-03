import Foundation
import MarginaliaSyntax
import MarginaliaRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class AttributedMarkdownSerializer {

    public typealias Dialect = MarginaliaView.Dialect

    public init() {}

    public func serialize(_ attributed: NSAttributedString, dialect: Dialect) -> String {
        let total = attributed.length
        guard total > 0 else { return "" }
        var out = ""
        var emittedSomething = false
        var cursor = 0

        while cursor < total {
            let spec = attributed.blockSpec(at: cursor)
            var blockEnd = total
            attributed.enumerateAttribute(.marginaliaBlockSpec, in: NSRange(location: cursor, length: total - cursor)) { _, range, stop in
                if range.location > cursor {
                    blockEnd = range.location
                    stop.pointee = true
                }
            }

            let blockRange = NSRange(location: cursor, length: blockEnd - cursor)
            if let spec {
                if emittedSomething { out.append("\n") }
                out.append(emitBlock(spec, attributed: attributed, range: blockRange, dialect: dialect))
            } else {
                if emittedSomething { out.append("\n") }
                let plain = attributed.attributedSubstring(from: blockRange).string
                out.append(plain)
            }
            emittedSomething = true
            cursor = blockEnd
        }
        return ensureTrailingNewline(out)
    }

    // MARK: - block emission

    private func emitBlock(
        _ spec: BlockSpec,
        attributed: NSAttributedString,
        range: NSRange,
        dialect: Dialect
    ) -> String {
        let inner = inlineMarkdown(of: attributed, range: range, dialect: dialect, in: spec)
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

    // MARK: - inline run emission

    private func inlineMarkdown(
        of attributed: NSAttributedString,
        range: NSRange,
        dialect: Dialect,
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
            out.append(emitInlineRun(text: runText, attrs: attrs, dialect: dialect, in: spec))
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
        dialect: Dialect,
        in spec: BlockSpec
    ) -> String {
        if text == "\n" { return "\n" }

        if attrs[.attachment] != nil {
            return ""
        }
        if let flag = attrs[.marginaliaListMarker] as? Bool, flag {
            return ""
        }

        var content = text
        var prefix = ""
        var suffix = ""

        if let url = (attrs[.marginaliaLink] as? String) ?? linkURLString(from: attrs[.link]) {
            let label = stripTrailingNewline(content)
            return "[\(label)](\(url))"
        }

        if let inline = attrs[.marginaliaInline] as? InlineTag, inline == .codeSpan {
            let label = stripTrailingNewline(content)
            return "`\(label)`"
        }
        if let font = attrs[.font] as? PlatformFont, isMonospace(font) {
            let label = stripTrailingNewline(content)
            return "`\(label)`"
        }

        if let font = attrs[.font] as? PlatformFont {
            let traits = symbolicTraits(of: font)
            let bold = isBold(traits) && !paragraphImpliedBold(for: spec)
            let italic = isItalic(traits)
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

    private func isMonospace(_ font: PlatformFont) -> Bool {
        #if canImport(AppKit) && os(macOS)
        return font.fontDescriptor.symbolicTraits.contains(NSFontDescriptor.SymbolicTraits.monoSpace)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #endif
    }

    #if canImport(AppKit) && os(macOS)
    private func symbolicTraits(of font: PlatformFont) -> NSFontDescriptor.SymbolicTraits {
        font.fontDescriptor.symbolicTraits
    }
    private func isBold(_ traits: NSFontDescriptor.SymbolicTraits) -> Bool {
        traits.contains(.bold)
    }
    private func isItalic(_ traits: NSFontDescriptor.SymbolicTraits) -> Bool {
        traits.contains(.italic)
    }
    #else
    private func symbolicTraits(of font: PlatformFont) -> UIFontDescriptor.SymbolicTraits {
        font.fontDescriptor.symbolicTraits
    }
    private func isBold(_ traits: UIFontDescriptor.SymbolicTraits) -> Bool {
        traits.contains(.traitBold)
    }
    private func isItalic(_ traits: UIFontDescriptor.SymbolicTraits) -> Bool {
        traits.contains(.traitItalic)
    }
    #endif
}
