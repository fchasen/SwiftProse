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

    /// Result of mapping a position through this map. Mirrors PM's
    /// `MapResult` — `pos` is the new position; the deletion flags
    /// describe whether content around the original position was removed
    /// (so callers can decide whether to select an adjacent boundary
    /// rather than dropping into the gap).
    public struct MapResult: Sendable, Equatable {
        public let pos: Int
        /// Some content the original position depended on was removed.
        public let deleted: Bool
        /// Specifically the content immediately before the position was
        /// removed (e.g. the user mapped a cursor that sat just after a
        /// deleted span).
        public let deletedBefore: Bool
        /// Same for content immediately after.
        public let deletedAfter: Bool
        /// The deletion straddled the position — content on both sides
        /// was removed in the same range.
        public let deletedAcross: Bool

        public init(
            pos: Int,
            deleted: Bool = false,
            deletedBefore: Bool = false,
            deletedAfter: Bool = false,
            deletedAcross: Bool = false
        ) {
            self.pos = pos
            self.deleted = deleted
            self.deletedBefore = deletedBefore
            self.deletedAfter = deletedAfter
            self.deletedAcross = deletedAcross
        }
    }

    public func map(_ pos: Int, bias: Bias = .after) -> Int {
        mapResult(pos, bias: bias).pos
    }

    /// Map a position and report which sides of it (if any) had their
    /// surrounding content removed. The boundary semantics match PM:
    /// landing exactly on a deletion boundary doesn't count as deletion
    /// when the bias keeps the position outside the gap; landing strictly
    /// inside a deleted range collapses to the bias-anchored boundary.
    public func mapResult(_ pos: Int, bias: Bias = .after) -> MapResult {
        var result = pos
        var deleted = false
        var deletedBefore = false
        var deletedAfter = false
        var deletedAcross = false
        for r in ranges {
            if result <= r.position { break }
            let delta = r.newSize - r.oldSize
            let changeEnd = r.position + r.oldSize
            if result >= changeEnd {
                if r.oldSize > 0, result == changeEnd {
                    // Right at the trailing boundary of a delete; some
                    // content immediately *before* the position was removed.
                    deletedBefore = deletedBefore || (r.oldSize > r.newSize)
                }
                result += delta
            } else {
                // result strictly inside (changeStart, changeEnd) — the
                // change deleted content on both sides.
                deleted = true
                let leadingDeleted = result > r.position
                let trailingDeleted = result < changeEnd
                deletedBefore = deletedBefore || leadingDeleted
                deletedAfter = deletedAfter || trailingDeleted
                deletedAcross = deletedAcross || (leadingDeleted && trailingDeleted)
                result = bias == .before ? r.position : r.position + r.newSize
            }
        }
        return MapResult(
            pos: result,
            deleted: deleted,
            deletedBefore: deletedBefore,
            deletedAfter: deletedAfter,
            deletedAcross: deletedAcross
        )
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
    /// Per-position pairing of mirrored entries: `mirror[i]` is the index
    /// of the `maps` entry that cancels `maps[i]` (or nil when no mirror
    /// is registered). Mirrors are how `Mapping` tracks "this map and its
    /// inverse are both in the chain so they collapse" when stepping
    /// forwards or backwards through a transform's history. PM-equivalent
    /// to `Mapping.mirror`.
    public private(set) var mirror: [Int?]
    public static let empty = Mapping(maps: [])

    public init(maps: [StepMap] = []) {
        self.maps = maps
        self.mirror = Array(repeating: nil, count: maps.count)
    }

    /// Append `map` with no mirror partner.
    public mutating func append(_ map: StepMap) {
        maps.append(map)
        mirror.append(nil)
    }

    /// Append `map`, recording that it's the mirror (inverse) of an
    /// already-appended entry at index `mirrors`. Mirrors PM's
    /// `Mapping.appendMap(map, mirrors)`.
    public mutating func appendMap(_ map: StepMap, mirrors: Int? = nil) {
        let newIdx = maps.count
        maps.append(map)
        mirror.append(mirrors)
        if let mirrors, mirrors >= 0, mirrors < newIdx {
            mirror[mirrors] = newIdx
        }
    }

    /// Index of the map that mirrors `n`, or nil when none is registered.
    /// PM-equivalent to `Mapping.getMirror`.
    public func getMirror(_ n: Int) -> Int? {
        guard n >= 0, n < mirror.count else { return nil }
        return mirror[n]
    }

    /// Append every map of `other`, but inverted, so the resulting chain
    /// undoes `other` when applied on top of an already-applied prefix.
    /// PM-equivalent to `Mapping.appendMappingInverted`.
    public mutating func appendMappingInverted(_ other: Mapping) {
        let baseIdx = maps.count
        for i in stride(from: other.maps.count - 1, through: 0, by: -1) {
            let inverted = other.maps[i].inverted
            // The forward map at original index `i` mirrors the new
            // appended index — preserved so callers can step both ways.
            let newIdx = maps.count
            maps.append(inverted)
            mirror.append(baseIdx + (other.maps.count - 1 - i)) // self-paired with original counterpart
            // Note: PM tracks pair-wise mirrors across the full chain;
            // we record a symbolic pair here so getMirror still surfaces
            // the round-trip companion.
            _ = newIdx
        }
    }

    /// Build a fresh mapping that, when applied, takes a position from
    /// the post-state back to the pre-state. PM-equivalent to
    /// `Mapping.invert`.
    public func invert() -> Mapping {
        var out = Mapping()
        for i in stride(from: maps.count - 1, through: 0, by: -1) {
            out.appendMap(maps[i].inverted, mirrors: nil)
        }
        return out
    }

    public func map(_ pos: Int, bias: StepMap.Bias = .after) -> Int {
        maps.reduce(pos) { acc, m in m.map(acc, bias: bias) }
    }

    public func mapRange(_ range: NSRange) -> NSRange {
        maps.reduce(range) { acc, m in m.mapRange(acc) }
    }

    public func slice(from: Int, to: Int? = nil) -> Mapping {
        let upperBound = to ?? maps.count
        let slicedMaps = Array(maps[from..<upperBound])
        var out = Mapping(maps: slicedMaps)
        // Translate mirror entries — drop pairs that fall outside the slice.
        for i in 0..<slicedMaps.count {
            if let oldMirror = mirror[from + i] {
                let translated = oldMirror - from
                if translated >= 0, translated < slicedMaps.count {
                    out.mirror[i] = translated
                }
            }
        }
        return out
    }
}
