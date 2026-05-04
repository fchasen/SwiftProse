import Foundation

/// Per-column horizontal alignment encoded by the alignment row of a GFM
/// pipe table:
///
/// - `:---` → `.left`
/// - `---:` → `.right`
/// - `:---:` → `.center`
/// - `---` → `.none` (renderer's default; usually left)
///
/// Retained as a public type so callers (including stubbed
/// `EditorAction.setTableColumnAlignment`) can still reference it; the
/// rest of the pipe-table model retired alongside the rendered chrome.
public enum PipeTableAlignment: Equatable, Sendable, Hashable {
    case none
    case left
    case right
    case center

    public var alignmentRowToken: String {
        switch self {
        case .none: return "---"
        case .left: return ":---"
        case .right: return "---:"
        case .center: return ":---:"
        }
    }

    public init?(alignmentRowCell: String) {
        let trimmed = alignmentRowCell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let leading = trimmed.first == ":"
        let trailing = trimmed.last == ":"
        let body: Substring = {
            var s = trimmed[...]
            if leading { s = s.dropFirst() }
            if trailing { s = s.dropLast() }
            return s
        }()
        guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        switch (leading, trailing) {
        case (true, true): self = .center
        case (true, false): self = .left
        case (false, true): self = .right
        case (false, false): self = .none
        }
    }
}
