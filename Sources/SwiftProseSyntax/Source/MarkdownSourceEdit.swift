import Foundation

public struct MarkdownSourceEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    public static func insertion(_ text: String, replacing range: NSRange) -> MarkdownSourceEdit {
        let end = range.location + (text as NSString).length
        return MarkdownSourceEdit(range: range, replacement: text, selection: NSRange(location: end, length: 0))
    }

    public func applied(to text: String) -> String {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return text }
        return ns.replacingCharacters(in: range, with: replacement)
    }

    func minimized(against text: NSString) -> MarkdownSourceEdit {
        let old = text.substring(with: range) as NSString
        let new = replacement as NSString
        var prefix = 0
        let limit = min(old.length, new.length)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix > 0, prefix < limit, UTF16.isTrailSurrogate(old.character(at: prefix)) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        if suffix > 0, suffix < limit - prefix, UTF16.isLeadSurrogate(old.character(at: old.length - suffix - 1)) {
            suffix -= 1
        }
        let trimmedRange = NSRange(location: range.location + prefix, length: old.length - prefix - suffix)
        let trimmedReplacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        return MarkdownSourceEdit(range: trimmedRange, replacement: trimmedReplacement, selection: selection)
    }
}
