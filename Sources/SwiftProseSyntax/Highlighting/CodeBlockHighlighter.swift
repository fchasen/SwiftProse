import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct CodeHighlightRun: Hashable, @unchecked Sendable {
    public var range: NSRange
    public var color: PlatformColor

    public init(range: NSRange, color: PlatformColor) {
        self.range = range
        self.color = color
    }
}

public struct CodeHighlightEdit: Hashable, @unchecked Sendable {
    public var invalidatedRange: NSRange
    public var runs: [CodeHighlightRun]

    public init(invalidatedRange: NSRange, runs: [CodeHighlightRun]) {
        self.invalidatedRange = invalidatedRange
        self.runs = runs
    }
}

public protocol CodeHighlightSession: AnyObject {
    func reset(body: String) -> [CodeHighlightRun]
    func didEdit(replacedRange: NSRange, replacement: String, body: String) -> CodeHighlightEdit
}

public protocol CodeBlockHighlighter: AnyObject {
    func makeSession(language: String?, body: String) -> CodeHighlightSession?
}
