import Foundation

public enum OrderedMarkerStyle: Sendable, Hashable {
    case decimal
    case lowerAlpha
    case lowerRoman
}

public enum OrderedMarkerFormatter {

    public static func style(forLevel level: Int) -> OrderedMarkerStyle {
        switch ((level % 3) + 3) % 3 {
        case 0: return .decimal
        case 1: return .lowerAlpha
        default: return .lowerRoman
        }
    }

    public static func format(index: Int, style: OrderedMarkerStyle) -> String {
        let n = max(1, index)
        switch style {
        case .decimal: return "\(n)."
        case .lowerAlpha: return alpha(n) + "."
        case .lowerRoman: return roman(n) + "."
        }
    }

    static func alpha(_ index: Int) -> String {
        var n = max(1, index)
        var out = ""
        while n > 0 {
            n -= 1
            let digit = n % 26
            out = String(UnicodeScalar(UInt8(97 + digit))) + out
            n /= 26
        }
        return out
    }

    static func roman(_ index: Int) -> String {
        var n = max(1, min(3999, index))
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
