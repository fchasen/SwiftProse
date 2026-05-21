import Foundation
import SwiftProseSyntax

/// Bridges raw clipboard payloads (text + html) into a `Slice`.
///
/// Implements PM's `parseFromClipboard` decision tree:
///
/// ```
/// inCode = $context.parent.type.isCode
/// asText = !text.isEmpty && (plainText || inCode || html == nil)
/// if asText:
///   if inCode: return Slice(text-with-LF, 0, 0)
///   else: return clipboardTextParser(text, $context, plainText)
///         ?? markdownCompileSlice(text)
/// html = transformPastedHTML(html)
/// slice = clipboardParser(html, $context) ?? DOMParser.parse(html)
/// ```
public struct ClipboardParser {

    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    /// Resolve the paste event into a `Slice`. Returns nil when no
    /// payload can be parsed (caller may then short-circuit to the plain
    /// insert path, but in practice this only happens for genuinely
    /// empty events).
    public func parseFromClipboard(
        controller: EditorController,
        text: String?,
        html: String?,
        plainText: Bool,
        selection: NSRange
    ) -> Slice? {
        let inCode = controller.isLocationInCodeBlock(selection.location)
        let text = text ?? ""
        let html = html

        // transformPastedHTML — runs in registration order, only when an
        // HTML branch will actually be taken.
        var transformedHTML = html
        if let raw = html, !raw.isEmpty {
            var current = raw
            for plugin in controller.plugins {
                if let f = plugin.props.transformPastedHTML {
                    current = f(controller, current, inCode || plainText)
                }
            }
            transformedHTML = current
        }

        // PM's `asText` branch — plain text is the source of truth when
        // the user asked for it, the destination is a code block, or
        // there's no HTML payload to consume.
        let asText = !text.isEmpty && (plainText || inCode || transformedHTML == nil || transformedHTML?.isEmpty == true)
        if asText {
            if inCode {
                // Preserve text verbatim (after newline normalization);
                // produce a closed inline slice.
                let normalized = normalizeNewlines(text)
                let inline: TreeNode = .inline(text: normalized, marks: MarkSet())
                return Slice(content: Fragment([inline]), openStart: 0, openEnd: 0)
            }
            // Plugin clipboardTextParser → markdown compile fallback.
            for plugin in controller.plugins {
                if let parser = plugin.props.clipboardTextParser,
                   let slice = parser(controller, text, selection, plainText) {
                    return slice
                }
            }
            return controller.compiler.compileSlice(text, theme: controller.theme)
        }

        // HTML branch.
        guard let raw = transformedHTML, !raw.isEmpty else { return nil }
        for plugin in controller.plugins {
            if let parser = plugin.props.clipboardParser,
               let slice = parser(controller, raw, selection, plainText) {
                return slice
            }
        }
        return DOMParser(schema: schema).parse(raw)
    }

    private func normalizeNewlines(_ s: String) -> String {
        if !s.contains("\r") { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
    }
}
