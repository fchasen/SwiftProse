import Foundation
import SwiftProseSyntax

/// Bundles a `Slice` into the three forms a pasteboard write needs:
///   - `text`: faithful markdown — what external apps (TextEdit, Notes)
///     see when no HTML reader is available.
///   - `html`: structural HTML carrying a `data-pm-slice` attribute on the
///     outermost wrapper. Round-trips between SwiftProse instances and
///     web ProseMirror without losing block context or open depths.
///   - `slice`: the slice itself, returned so callers (today, copy
///     overrides on the platform text views) can route it through any
///     `clipboardSerializer` plugin hook before writing.
public struct ClipboardSerializer {

    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    /// Build the trio for `slice`. The HTML is wrapped in a `<div>` carrying
    /// `data-pm-slice="<openStart> <openEnd>[ JSON]"` exactly as PM does
    /// so the round-trip recovers the open depths.
    public func serializeForClipboard(
        controller: EditorController,
        slice: Slice
    ) -> (text: String, html: String?, slice: Slice) {
        let serializer = MarkdownTreeSerializer(schema: schema)
        let text = serializer.serializeSlice(slice)
        let html = renderHTML(slice)
        return (text: text, html: html, slice: slice)
    }

    /// HTML rendering for `slice` — body produced by `DOMSerializer`,
    /// wrapped in a slice-marker `<div>` that carries the open depths.
    public func renderHTML(_ slice: Slice) -> String {
        let dom = DOMSerializer(schema: schema)
        let body = dom.serialize(slice.content)
        let marker = sliceMarker(openStart: slice.openStart, openEnd: slice.openEnd)
        return "<div data-pm-slice=\"\(escapeAttr(marker))\">\(body)</div>"
    }

    /// PM's `data-pm-slice` payload encodes `"<openStart> <openEnd> JSON"`
    /// where JSON is the context node-name array. We don't yet carry a
    /// context JSON; emit just the depths so a parser that reads them can
    /// recover open boundaries.
    private func sliceMarker(openStart: Int, openEnd: Int) -> String {
        "\(openStart) \(openEnd) []"
    }

    private func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
