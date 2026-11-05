import SwiftProseSyntax
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct ListMarker: Equatable {
    public enum Kind: Equatable {
        case bullet(String)
        case ordinal(Int)
        case task(TaskState)
    }

    public var kind: Kind
    public var font: PlatformFont
    public var color: PlatformColor

    package init(kind: Kind, font: PlatformFont, color: PlatformColor) {
        self.kind = kind
        self.font = font
        self.color = color
    }

    public var text: String? {
        switch kind {
        case .bullet(let glyph): return glyph
        case .ordinal(let number): return "\(number)."
        case .task: return nil
        }
    }
}
