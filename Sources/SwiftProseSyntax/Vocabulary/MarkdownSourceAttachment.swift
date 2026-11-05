import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public protocol ProseSourceAttachment: NSTextAttachment {
    var markdownSource: String { get set }
    var contentKind: String { get set }
}

public enum AtomKind {
    public static let image = "markdown.image"
    public static let inlineHTML = "markdown.inlineHTML"
    public static let thematicBreak = "markdown.thematicBreak"
    public static let htmlBlock = "markdown.htmlBlock"
    public static let emptyLink = "markdown.emptyLink"
}
