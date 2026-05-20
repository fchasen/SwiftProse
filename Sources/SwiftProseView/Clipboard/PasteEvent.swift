import Foundation
import SwiftProseSyntax

/// Payload routed through the paste pipeline. Carries the raw pasteboard
/// strings, the destination selection, and whether the destination is a
/// code block (so plain-text branches can preserve newlines verbatim).
///
/// Phase 1 ships text-only fields. Phase 2 will add a lazy `Slice` derived
/// from `html` / `text` so plugins can intercept structured content.
public struct PasteEvent {

    /// Whether this payload arrived via the system pasteboard
    /// (`.paste` — Cmd-V, edit menu) or as a bulk text insertion that
    /// behaves structurally like a paste (`.dictation` — iOS dictation,
    /// macOS multi-character non-IME inserts). Plugins that want to
    /// differentiate (analytics, transcription cleanup) read this field.
    public enum Source: Sendable, Equatable {
        case paste
        case dictation
    }

    /// utf8-plain-text from the pasteboard, or the dictated phrase.
    public var text: String?
    /// public.html from the pasteboard. Phase 4 consumes this; Phase 1
    /// ignores it.
    public var html: String?
    /// Whether the user explicitly requested a plain-text paste
    /// (Cmd-Shift-V / Paste and Match Style). Forces the plain-text
    /// branch even when `html` is present.
    public var plainText: Bool
    public var source: Source
    /// Selection at time of paste; the cursor lands at `selection.location`
    /// and any selection length is replaced by the paste content.
    public var selection: NSRange
    /// True when the destination paragraph is a code block. The plain-text
    /// branch preserves newlines verbatim in this case and skips mark
    /// inheritance.
    public var inCode: Bool

    public init(
        text: String?,
        html: String? = nil,
        plainText: Bool = false,
        source: Source = .paste,
        selection: NSRange,
        inCode: Bool = false
    ) {
        self.text = text
        self.html = html
        self.plainText = plainText
        self.source = source
        self.selection = selection
        self.inCode = inCode
    }
}
