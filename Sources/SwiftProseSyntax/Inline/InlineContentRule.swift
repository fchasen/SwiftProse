import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct InlineContentMatch: Sendable {
    public let matched: String
    public let groups: [String?]

    public init(matched: String, groups: [String?]) {
        self.matched = matched
        self.groups = groups
    }

    public func capture(_ index: Int) -> String? {
        guard groups.indices.contains(index) else { return nil }
        return groups[index]
    }
}

public struct InlineContentRule: Sendable {
    public let id: String
    public let pattern: String
    public let content: @Sendable (InlineContentMatch) -> ProseInlineContent?

    package let regex: NSRegularExpression

    public init(
        id: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        content: @escaping @Sendable (InlineContentMatch) -> ProseInlineContent?
    ) {
        self.id = id
        self.pattern = pattern
        do {
            self.regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("InlineContentRule \(id) pattern \(pattern) failed to compile: \(error)")
        }
        self.content = content
    }
}

public typealias ProseInlineContentProvider = (ProseInlineContent) -> NSTextAttachment?
