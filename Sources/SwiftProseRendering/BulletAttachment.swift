import Foundation

public enum BulletAttachment {

    public static func glyph(forLevel level: Int) -> String {
        switch ((level % 4) + 4) % 4 {
        case 0: return "•"
        case 1: return "◦"
        case 2: return "▪"
        case 3: return "▫"
        default: return "•"
        }
    }

    public static func level(forLeading leading: String) -> Int {
        var spaces = 0
        for ch in leading {
            if ch == "\t" { spaces += 2 }
            else if ch == " " { spaces += 1 }
            else { break }
        }
        return spaces / 2
    }
}
