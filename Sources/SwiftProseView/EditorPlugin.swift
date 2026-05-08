import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Lifecycle hooks an `EditorPlugin` may implement. Mirrors PM's plugin
/// spec — `filterTransaction` vetoes a transaction, `appendTransaction`
/// adds steps after others have applied, and the `Props` bag carries
/// input-event hooks (click, paste, drop, keyDown, textInput).
public protocol EditorPlugin: AnyObject {
    var key: AnyPluginKey { get }

    /// Return false to drop `transaction` before it's applied.
    func filterTransaction(
        _ transaction: Transaction,
        controller: EditorController
    ) -> Bool

    /// Optional follow-up transaction to apply atomically after the
    /// triggering one. Return nil for no-op.
    func appendTransaction(
        after transaction: Transaction,
        controller: EditorController
    ) -> Transaction?

    func appendTransaction(
        after transactions: [Transaction],
        controller: EditorController
    ) -> Transaction?

    /// Input-event hooks. Default implementations return false (don't
    /// consume the event).
    var props: PluginProps { get }
}

public extension EditorPlugin {
    func filterTransaction(_ transaction: Transaction, controller: EditorController) -> Bool { true }
    func appendTransaction(after transaction: Transaction, controller: EditorController) -> Transaction? { nil }
    func appendTransaction(after transactions: [Transaction], controller: EditorController) -> Transaction? {
        guard let transaction = transactions.last else { return nil }
        return appendTransaction(after: transaction, controller: controller)
    }
    var props: PluginProps { PluginProps() }
}

/// Bag of optional input-event hooks. A plugin returns true from a hook
/// to indicate it consumed the event.
public struct PluginProps {
    public var handleClick: ((EditorController, Int) -> Bool)?
    public var handleLongPress: ((EditorController, Int) -> Bool)?
    public var handlePaste: ((EditorController, String) -> Bool)?
    public var handleDrop: ((EditorController, Any) -> Bool)?
    public var handleKeyDown: ((EditorController, String) -> Bool)?
    public var handleTextInput: ((EditorController, NSRange, String) -> Bool)?

    public init(
        handleClick: ((EditorController, Int) -> Bool)? = nil,
        handleLongPress: ((EditorController, Int) -> Bool)? = nil,
        handlePaste: ((EditorController, String) -> Bool)? = nil,
        handleDrop: ((EditorController, Any) -> Bool)? = nil,
        handleKeyDown: ((EditorController, String) -> Bool)? = nil,
        handleTextInput: ((EditorController, NSRange, String) -> Bool)? = nil
    ) {
        self.handleClick = handleClick
        self.handleLongPress = handleLongPress
        self.handlePaste = handlePaste
        self.handleDrop = handleDrop
        self.handleKeyDown = handleKeyDown
        self.handleTextInput = handleTextInput
    }
}

/// Type-erased plugin key. Construct via `PluginKey<T>(name:)`; use to
/// look up the plugin's state slot on the controller.
public struct AnyPluginKey: Hashable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// Typed plugin key. The phantom type carries the state shape so
/// `controller.pluginState(for:)` can return it without a cast.
public struct PluginKey<State> {
    public let any: AnyPluginKey
    public init(name: String) { self.any = AnyPluginKey(name: name) }
}
