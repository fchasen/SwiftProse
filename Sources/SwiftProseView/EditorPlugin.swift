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
    /// Called for paste and dictation. Return true to consume the event —
    /// the default insertion is skipped. Distinguish via `event.source`.
    public var handlePaste: ((EditorController, PasteEvent) -> Bool)?
    public var handleDrop: ((EditorController, Any) -> Bool)?
    public var handleKeyDown: ((EditorController, String) -> Bool)?
    public var handleTextInput: ((EditorController, NSRange, String) -> Bool)?

    /// Transform the raw plain text before paragraph-splitting. Receives
    /// the controller, the current text, and `plain` — true when the text
    /// is destined for a code block or the user asked for a plain-text
    /// paste. Plugins run in registration order; each sees the previous
    /// plugin's output.
    public var transformPastedText: ((EditorController, String, Bool) -> String)?

    /// Final transform of the paste payload before insertion. Phase 1 ships
    /// the text-shaped event; later phases will extend the event to carry a
    /// typed `Slice`. Plugins run in registration order, threading the
    /// event through each.
    public var transformPasted: ((EditorController, PasteEvent) -> PasteEvent)?

    /// Transform raw HTML before it's parsed into a Slice. The `plain`
    /// flag is true when the destination is a code block (plugins
    /// typically strip styling for code).
    public var transformPastedHTML: ((EditorController, String, Bool) -> String)?

    /// Replace the default HTML-to-Slice parser. Receives the HTML, the
    /// caret-context selection, and whether the user requested plain text.
    /// Return nil to fall through to the built-in `DOMParser`.
    public var clipboardParser: ((EditorController, String, NSRange, Bool) -> Slice?)?

    /// Replace the default plain-text-to-Slice parser. Receives the text,
    /// the caret-context selection, and whether the user requested plain
    /// text. Return nil to fall through to the markdown-aware
    /// `compileSlice` default.
    public var clipboardTextParser: ((EditorController, String, NSRange, Bool) -> Slice?)?

    /// Replace the default Slice-to-HTML serializer. Return nil to fall
    /// through to `ClipboardSerializer.renderHTML`.
    public var clipboardSerializer: ((EditorController, Slice) -> String?)?

    /// Replace the default Slice-to-plain-text serializer. Return nil to
    /// fall through to `MarkdownTreeSerializer.serializeSlice`.
    public var clipboardTextSerializer: ((EditorController, Slice) -> String?)?

    /// Called instead of `handlePaste` for dictation events. Defaults to
    /// nil → falls through to `handlePaste` so plugins that already filter
    /// paste pick dictation up for free. Plugins that want to differentiate
    /// (analytics, transcription cleanup) implement only this hook.
    public var handleDictation: ((EditorController, PasteEvent) -> Bool)?

    public init(
        handleClick: ((EditorController, Int) -> Bool)? = nil,
        handleLongPress: ((EditorController, Int) -> Bool)? = nil,
        handlePaste: ((EditorController, PasteEvent) -> Bool)? = nil,
        handleDrop: ((EditorController, Any) -> Bool)? = nil,
        handleKeyDown: ((EditorController, String) -> Bool)? = nil,
        handleTextInput: ((EditorController, NSRange, String) -> Bool)? = nil,
        transformPastedText: ((EditorController, String, Bool) -> String)? = nil,
        transformPasted: ((EditorController, PasteEvent) -> PasteEvent)? = nil,
        transformPastedHTML: ((EditorController, String, Bool) -> String)? = nil,
        clipboardParser: ((EditorController, String, NSRange, Bool) -> Slice?)? = nil,
        clipboardTextParser: ((EditorController, String, NSRange, Bool) -> Slice?)? = nil,
        clipboardSerializer: ((EditorController, Slice) -> String?)? = nil,
        clipboardTextSerializer: ((EditorController, Slice) -> String?)? = nil,
        handleDictation: ((EditorController, PasteEvent) -> Bool)? = nil
    ) {
        self.handleClick = handleClick
        self.handleLongPress = handleLongPress
        self.handlePaste = handlePaste
        self.handleDrop = handleDrop
        self.handleKeyDown = handleKeyDown
        self.handleTextInput = handleTextInput
        self.transformPastedText = transformPastedText
        self.transformPasted = transformPasted
        self.transformPastedHTML = transformPastedHTML
        self.clipboardParser = clipboardParser
        self.clipboardTextParser = clipboardTextParser
        self.clipboardSerializer = clipboardSerializer
        self.clipboardTextSerializer = clipboardTextSerializer
        self.handleDictation = handleDictation
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
