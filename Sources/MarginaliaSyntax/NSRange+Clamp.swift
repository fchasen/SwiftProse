import Foundation

extension NSRange {
    /// Returns this range clamped so its location is in `[0, length]` and
    /// its length doesn't extend past the end. Use this anywhere an
    /// `NSRange` is about to be passed to an `NSString` API that doesn't
    /// tolerate out-of-bounds input — `lineRange(for:)`, `substring(with:)`
    /// — to convert a stale or otherwise invalid range into a safe empty
    /// range at the end of the string instead of an `NSRangeException`.
    public func clamped(to length: Int) -> NSRange {
        let safeLength = max(0, length)
        let loc = max(0, min(location, safeLength))
        let remaining = max(0, safeLength - loc)
        return NSRange(location: loc, length: max(0, min(self.length, remaining)))
    }
}
