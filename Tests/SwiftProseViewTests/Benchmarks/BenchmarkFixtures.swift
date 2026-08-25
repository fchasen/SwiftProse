import Foundation

/// Deterministic markdown generators for the keystroke benchmarks. No
/// randomness — the same source text every run so numbers are comparable
/// across commits.
enum BenchmarkFixtures {

    /// ~1200 blocks of mixed structure: paragraphs, 3-deep bullet /
    /// ordered / task lists, blockquotes, and 8 fenced code blocks of
    /// 20–40 lines each.
    static func mixedDocument() -> String {
        var out: [String] = []
        var blockCount = 0
        var cycle = 0
        var fenceCount = 0
        // Distribute the 8 fences evenly through the document.
        var nextFenceAt = 140

        func emit(_ s: String) {
            out.append(s)
            blockCount += 1
        }

        while blockCount < 1200 {
            if blockCount >= nextFenceAt, fenceCount < 8 {
                emit(fence(index: fenceCount, lines: 20 + (fenceCount * 7) % 21))
                fenceCount += 1
                nextFenceAt += 140
                cycle += 1
                continue
            }
            switch cycle % 6 {
            case 0:
                emit("## Section \(blockCount)")
                emit(paragraph(seed: blockCount))
                emit(paragraph(seed: blockCount + 1))
            case 1:
                for level in 0..<3 {
                    for item in 0..<3 {
                        let indent = String(repeating: "  ", count: level)
                        emit("\(indent)- bullet \(level).\(item) with **bold** and `code`")
                    }
                }
            case 2:
                for level in 0..<3 {
                    for item in 1...4 {
                        let indent = String(repeating: "   ", count: level)
                        emit("\(indent)\(item). ordered \(level).\(item) item text")
                    }
                }
            case 3:
                for item in 0..<4 {
                    emit("- [\(item % 2 == 0 ? "x" : " ")] task \(item) for block \(blockCount)")
                }
            case 4:
                emit("> quoted line one for block \(blockCount)")
                emit("> quoted line two with [a link](https://example.com)")
                emit(paragraph(seed: blockCount + 7))
            default:
                emit(paragraph(seed: blockCount))
                emit(paragraph(seed: blockCount + 3))
                emit("---")
            }
            cycle += 1
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// One paragraph followed by a single 3000-line fenced code block,
    /// then a trailing paragraph. Isolates the cost of editing inside a
    /// very large fence.
    static func longFenceDocument() -> String {
        var lines: [String] = []
        lines.append("Intro paragraph before the fence.")
        lines.append("")
        lines.append("```swift")
        for i in 0..<3000 {
            lines.append("    let value\(i) = compute(\(i), scale: \(i % 17)) // line \(i)")
        }
        lines.append("```")
        lines.append("")
        lines.append("Trailing paragraph after the fence.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func paragraph(seed: Int) -> String {
        let words = [
            "storage", "attribute", "fragment", "paragraph", "typed",
            "projection", "keystroke", "markdown", "structural", "inline",
            "compile", "segment", "highlight", "transaction", "selection"
        ]
        var parts: [String] = []
        for i in 0..<24 {
            var w = words[(seed &* 31 &+ i &* 7) % words.count]
            if i == 5 { w = "**\(w)**" }
            if i == 11 { w = "*\(w)*" }
            if i == 17 { w = "`\(w)`" }
            parts.append(w)
        }
        return parts.joined(separator: " ") + "."
    }

    private static func fence(index: Int, lines: Int) -> String {
        var body: [String] = ["```swift"]
        for i in 0..<lines {
            body.append("    func step\(index)_\(i)(_ x: Int) -> Int { x &* \(i + 2) }")
        }
        body.append("```")
        return body.joined(separator: "\n")
    }
}
