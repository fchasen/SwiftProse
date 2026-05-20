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
        let pb = NSPasteboard.general
        let text = pb.string(forType: .string)
        let html = pb.string(forType: .html)
        return Contents(text: text, html: html)
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
}
