import SwiftProseSyntax
import SwiftProseRendering
import Foundation

public enum EditorSizing: Sendable {
    case fitsContent
    case fillContainer
}

public struct ProseContextMenuItem {
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
