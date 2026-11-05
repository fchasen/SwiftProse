import Foundation

/// Picks the language whose highlight spans cover a body most convincingly.
///
/// A winner covers at least 30 % of the body's UTF-16 units and at least
/// 1.5× the runner-up. Bodies under 16 units are never classified.
enum LanguageDetection {
    static let minimumLength = 16
    static let minimumCoverage = 0.30
    static let minimumEdge = 1.5

    static func detect(
        in source: String,
        candidates: [String],
        spans: (String) -> [NSRange]
    ) -> String? {
        let total = (source as NSString).length
        guard total >= minimumLength else { return nil }
        var best: (name: String, coverage: Int) = ("", 0)
        var second = 0
        for name in candidates.sorted() {
            let coverage = unionLength(of: spans(name))
            if coverage > best.coverage {
                second = best.coverage
                best = (name, coverage)
            } else if coverage > second {
                second = coverage
            }
        }
        guard best.coverage > 0 else { return nil }
        let ratio = Double(best.coverage) / Double(total)
        let edge = second == 0 ? .infinity : Double(best.coverage) / Double(second)
        guard ratio >= minimumCoverage, edge >= minimumEdge else { return nil }
        return best.name
    }

    static func unionLength(of ranges: [NSRange]) -> Int {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard let first = sorted.first else { return 0 }
        var total = 0
        var start = first.location
        var end = NSMaxRange(first)
        for range in sorted.dropFirst() {
            if range.location > end {
                total += end - start
                start = range.location
                end = NSMaxRange(range)
            } else {
                end = max(end, NSMaxRange(range))
            }
        }
        return total + end - start
    }
}
