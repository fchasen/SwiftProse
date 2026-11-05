import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public protocol EditorPlugin: AnyObject {
    var key: AnyPluginKey { get }
    var props: PluginProps { get }
    func documentDidChange(_ change: DocumentChange, controller: EditorController)
}

public extension EditorPlugin {
    var props: PluginProps { PluginProps() }
    func documentDidChange(_ change: DocumentChange, controller: EditorController) {}
}

public struct PluginProps {
    public var handleClick: ((EditorController, Int) -> Bool)?
    public var handleLongPress: ((EditorController, Int) -> Bool)?
    public var handlePaste: ((EditorController, PasteEvent) -> Bool)?
    public var handleKeyDown: ((EditorController, String) -> Bool)?
    public var handleTextInput: ((EditorController, NSRange, String) -> Bool)?

    public init(
        handleClick: ((EditorController, Int) -> Bool)? = nil,
        handleLongPress: ((EditorController, Int) -> Bool)? = nil,
        handlePaste: ((EditorController, PasteEvent) -> Bool)? = nil,
        handleKeyDown: ((EditorController, String) -> Bool)? = nil,
        handleTextInput: ((EditorController, NSRange, String) -> Bool)? = nil
    ) {
        self.handleClick = handleClick
        self.handleLongPress = handleLongPress
        self.handlePaste = handlePaste
        self.handleKeyDown = handleKeyDown
        self.handleTextInput = handleTextInput
    }
}

public struct AnyPluginKey: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct PluginKey<State> {
    public let any: AnyPluginKey
    public init(name: String) { self.any = AnyPluginKey(name: name) }
}

public enum PluginKeyName {
    public static let escape = "Escape"
    public static let enter = "Enter"
    public static let tab = "Tab"
    public static let arrowUp = "ArrowUp"
    public static let arrowDown = "ArrowDown"
    public static let arrowLeft = "ArrowLeft"
    public static let arrowRight = "ArrowRight"
}
