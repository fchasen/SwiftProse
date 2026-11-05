import SwiftProseSyntax
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum OrderedMarkerStyle: Hashable, Sendable {
    case decimal
    case lowerAlpha
    case lowerRoman

    public init(depth: Int) {
        switch (max(1, depth) - 1) % 3 {
        case 0: self = .decimal
        case 1: self = .lowerAlpha
        default: self = .lowerRoman
        }
    }

    public func marker(for number: Int) -> String {
        switch self {
        case .decimal: return "\(number)."
        case .lowerAlpha: return Self.alpha(number) + "."
        case .lowerRoman: return Self.roman(number) + "."
        }
    }

    static func alpha(_ number: Int) -> String {
        var n = max(1, number)
        var scalars: [Character] = []
        while n > 0 {
            n -= 1
            scalars.append(Character(Unicode.Scalar(UInt8(97 + n % 26))))
            n /= 26
        }
        return String(scalars.reversed())
    }

    static func roman(_ number: Int) -> String {
        var n = max(1, min(3999, number))
        let pairs: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")
        ]
        var out = ""
        for (value, symbol) in pairs {
            while n >= value {
                out += symbol
                n -= value
            }
        }
        return out
    }
}

public struct ListMarker: Equatable {
    public enum Kind: Equatable {
        case bullet(String)
        case ordinal(Int, OrderedMarkerStyle = .decimal)
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
        case .ordinal(let number, let style): return style.marker(for: number)
        case .task: return nil
        }
    }
}
