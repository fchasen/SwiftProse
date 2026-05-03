import Foundation

public struct StepMap: Sendable, Equatable {
    public static let empty = StepMap(ranges: [])

    public struct Range: Sendable, Equatable {
        public let position: Int
        public let oldSize: Int
        public let newSize: Int

        public init(position: Int, oldSize: Int, newSize: Int) {
            self.position = position
            self.oldSize = oldSize
            self.newSize = newSize
        }
    }

    public let ranges: [Range]

    public init(ranges: [Range]) {
        self.ranges = ranges
    }

    public init(oldRange: NSRange, newLength: Int) {
        self.ranges = [Range(position: oldRange.location, oldSize: oldRange.length, newSize: newLength)]
    }

    public enum Bias: Sendable {
        case before, after
    }

    public func map(_ pos: Int, bias: Bias = .after) -> Int {
        var result = pos
        for r in ranges {
            if result <= r.position { break }
            let delta = r.newSize - r.oldSize
            let changeEnd = r.position + r.oldSize
            if result >= changeEnd {
                result += delta
            } else {
                result = bias == .before ? r.position : r.position + r.newSize
            }
        }
        return result
    }

    public func mapRange(_ range: NSRange) -> NSRange {
        let start = map(range.location, bias: .before)
        let end = map(range.location + range.length, bias: .after)
        return NSRange(location: start, length: max(0, end - start))
    }

    public var inverted: StepMap {
        StepMap(ranges: ranges.map { Range(position: $0.position, oldSize: $0.newSize, newSize: $0.oldSize) })
    }
}

public struct Mapping: Sendable {
    public private(set) var maps: [StepMap]
    public static let empty = Mapping(maps: [])

    public init(maps: [StepMap] = []) {
        self.maps = maps
    }

    public mutating func append(_ map: StepMap) {
        maps.append(map)
    }

    public func map(_ pos: Int, bias: StepMap.Bias = .after) -> Int {
        maps.reduce(pos) { acc, m in m.map(acc, bias: bias) }
    }

    public func mapRange(_ range: NSRange) -> NSRange {
        maps.reduce(range) { acc, m in m.mapRange(acc) }
    }

    public func slice(from: Int, to: Int? = nil) -> Mapping {
        Mapping(maps: Array(maps[from..<(to ?? maps.count)]))
    }
}
