import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Bridged pasteboard reads. Phase 1 surfaces plain text and HTML; later
/// phases route the HTML through ClipboardParser and the text through a
/// markdown-aware fallback.
enum Clipboard {

    struct Contents {
        var text: String?
        var html: String?
    }

    static func read() -> Contents {
        #if canImport(AppKit) && os(macOS)
        return read(from: .general)
        #elseif canImport(UIKit)
        let pb = UIPasteboard.general
        var text: String? = pb.string
        var html: String?
        if let data = pb.data(forPasteboardType: "public.html"),
           let decoded = String(data: data, encoding: .utf8) {
            html = decoded
        }
        return Contents(text: text, html: html)
        #else
        return Contents(text: nil, html: nil)
        #endif
    }

    #if canImport(AppKit) && os(macOS)
    static func read(from pasteboard: NSPasteboard) -> Contents {
        let text = pasteboard.string(forType: .string)
            ?? attributedString(from: pasteboard)?.string
        let html = pasteboard.string(forType: .html)
            ?? pasteboard.data(forType: .html).flatMap(decodeHTML)
        return Contents(text: text, html: html)
    }

    private static func attributedString(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let objects = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil),
           let attributed = objects.first as? NSAttributedString {
            return attributed
        }
        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return attributed
        }
        if let data = pasteboard.data(forType: .rtfd),
           let attributed = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return attributed
        }
        if let data = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: data, documentAttributes: nil) {
            return attributed
        }
        return nil
    }

    private static func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }
    #endif

    /// Replace the system pasteboard with the supplied `text` and (when
    /// present) `html`. macOS clears + writes the general pasteboard; iOS
    /// writes one item carrying both representations so any consumer can
    /// pick its preferred form.
    static func write(text: String, html: String? = nil) {
        #if canImport(AppKit) && os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if let html { pb.setString(html, forType: .html) }
        #elseif canImport(UIKit)
        let pb = UIPasteboard.general
        var item: [String: Any] = ["public.utf8-plain-text": text]
        if let html, let data = html.data(using: .utf8) {
            item["public.html"] = data
        }
        pb.items = [item]
        #endif
    }
}
