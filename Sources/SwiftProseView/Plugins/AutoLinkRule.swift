import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct AutoLinkMatch {
    public let storage: NSTextStorage
    public let matchedRange: NSRange
    public let linkRange: NSRange
    public let captureRanges: [NSRange]

    public var text: String { substring(in: matchedRange) ?? "" }
    public var linkText: String { substring(in: linkRange) ?? "" }

    public func capture(_ i: Int) -> String? {
        guard captureRanges.indices.contains(i) else { return nil }
        let range = captureRanges[i]
        guard range.location != NSNotFound else { return nil }
        return substring(in: range)
    }

    private func substring(in range: NSRange) -> String? {
        let ns = storage.string as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= ns.length else {
            return nil
        }
        return ns.substring(with: range)
    }
}

public struct AutoLinkRule {
    public let id: String
    public let pattern: NSRegularExpression
    public let linkCapture: Int
    public let href: (AutoLinkMatch) -> String?
    public let title: (AutoLinkMatch) -> String?

    public init(
        id: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        linkCapture: Int = 1,
        href: @escaping (AutoLinkMatch) -> String?,
        title: @escaping (AutoLinkMatch) -> String? = { _ in nil }
    ) {
        self.id = id
        do {
            self.pattern = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("AutoLinkRule \(id) pattern \(pattern) failed to compile: \(error)")
        }
        self.linkCapture = linkCapture
        self.href = href
        self.title = title
    }

    public static let url = AutoLinkRule(
        id: "swiftprose.url",
        pattern: #"(https?://(?:\([^\s<>"'\[\]()]*\)|[^\s<>"'\[\]()]|\((?![^\s<>"'\[\]()]*\)))*(?:\([^\s<>"'\[\]()]*\)|[^\s<>"'\[\]()\.,!?;:*]))(?=[\s\.,!?;:\)\]"'*]|$)"#,
        linkCapture: 1,
        href: { $0.linkText }
    )

    public static let email = AutoLinkRule(
        id: "swiftprose.email",
        pattern: #"(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})(?=[\s\.,!?;:\)\]]|$)"#,
        linkCapture: 1,
        href: { match in "mailto:\(match.linkText)" }
    )
}
