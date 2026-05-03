import Foundation

/// How the Marginalia text view sizes itself within its SwiftUI parent.
///
/// - `fitsContent`: the editor's height tracks its content (no internal
///   scrolling). Use this when the editor lives inside a scrollable
///   container — like a SwiftUI `ScrollView` or a SwiftData detail pane —
///   so growing text expands the whole view, the way a Slack composer or
///   Notes draft note does.
/// - `fillContainer`: the editor takes whatever height the parent gives
///   it and scrolls internally when content overflows. Use this for fixed
///   panes where the surrounding layout shouldn't reflow as the user
///   types. The macOS path wraps the text view in an `NSScrollView` in
///   this mode, which also enables the system find bar.
public enum EditorSizing: Sendable {
    case fitsContent
    case fillContainer
}

/// Action appended to the underlying text view's contextual menu so that
/// right-clicking inside the text body still surfaces caller-supplied
/// commands (the SwiftUI `.contextMenu` modifier is shadowed by the
/// native text view's own menu).
public struct MarginaliaContextMenuItem {
    public var title: String
    public var systemImage: String?
    public var isOn: Bool
    public var action: () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.action = action
    }
}
