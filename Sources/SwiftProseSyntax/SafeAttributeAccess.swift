import Foundation

extension NSAttributedString {
    /// `attribute(_:at:longestEffectiveRange:in:)` raises an `NSRangeException` if
    /// the index or search range is out of bounds. The string state can become
    /// stale during edits (e.g. layout queries firing while characters are
    /// being deleted), so wrap the call with explicit bounds checks and return
    /// `nil` instead of throwing.
    public func safeAttribute(
        _ key: NSAttributedString.Key,
        at index: Int,
        longestEffectiveRange range: inout NSRange,
        in searchRange: NSRange
    ) -> Any? {
        let total = length
        guard total > 0,
              index >= 0,
              index < total,
              searchRange.location >= 0,
              searchRange.length > 0,
              searchRange.location < total,
              searchRange.location + searchRange.length <= total,
              index >= searchRange.location,
              index < searchRange.location + searchRange.length else {
            range = NSRange(location: index, length: 0)
            return nil
        }
        return attribute(key, at: index, longestEffectiveRange: &range, in: searchRange)
    }

    public func safeAttribute(
        _ key: NSAttributedString.Key,
        at index: Int
    ) -> Any? {
        guard index >= 0, index < length else { return nil }
        return attribute(key, at: index, effectiveRange: nil)
    }

    public func safeAttributes(at index: Int) -> [NSAttributedString.Key: Any] {
        guard index >= 0, index < length else { return [:] }
        return attributes(at: index, effectiveRange: nil)
    }

    public func safeAttributes(
        at index: Int,
        longestEffectiveRange range: inout NSRange,
        in searchRange: NSRange
    ) -> [NSAttributedString.Key: Any] {
        let total = length
        guard total > 0,
              index >= 0,
              index < total,
              searchRange.location >= 0,
              searchRange.length > 0,
              searchRange.location < total,
              searchRange.location + searchRange.length <= total,
              index >= searchRange.location,
              index < searchRange.location + searchRange.length else {
            range = NSRange(location: index, length: 0)
            return [:]
        }
        return attributes(at: index, longestEffectiveRange: &range, in: searchRange)
    }
}
