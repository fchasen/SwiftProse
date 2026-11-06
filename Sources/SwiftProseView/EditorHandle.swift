import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum EditorMode: String, CaseIterable, Sendable {
    case rich
    case source

    public var toggled: EditorMode {
        self == .rich ? .source : .rich
    }
}

public final class EditorHandle: ProseEditing {
    public let richController: EditorController
    public let sourceController: SourceEditorController
    public package(set) var mode: EditorMode
    private var linkedEpochs: (rich: Int, source: Int)?

    public init(
        richController: EditorController,
        sourceController: SourceEditorController,
        mode: EditorMode = .rich
    ) {
        self.richController = richController
        self.sourceController = sourceController
        self.mode = mode
        if mode == .source {
            linkedEpochs = (richController.historyEpoch, sourceController.historyEpoch)
        }
    }

    public var activeEditor: any ProseEditing {
        switch mode {
        case .rich: richController
        case .source: sourceController
        }
    }

    public var textStorage: NSTextStorage { activeEditor.textStorage }
    public var currentSelection: NSRange { activeEditor.currentSelection }
    public var hostTextView: PlatformTextView? { activeEditor.hostTextView }
    public var isEditable: Bool { activeEditor.isEditable }

    public var selection: NSRange {
        get { currentSelection }
        set { setSelection(newValue) }
    }

    public func setSelection(_ range: NSRange) {
        activeEditor.setSelection(range)
    }

    public func markdown() -> String {
        activeEditor.markdown()
    }

    public func caretRect() -> CGRect? {
        activeEditor.caretRect()
    }

    public func rect(forCharacterAt index: Int) -> CGRect? {
        activeEditor.rect(forCharacterAt: index)
    }

    public func perform(_ action: EditorAction) {
        switch mode {
        case .rich: richController.perform(action)
        case .source: sourceController.perform(action)
        }
    }

    public func canPerform(_ action: EditorAction) -> Bool {
        switch mode {
        case .rich: richController.canPerform(action)
        case .source: sourceController.canPerform(action)
        }
    }

    public func isActive(_ action: EditorAction) -> Bool {
        switch mode {
        case .rich: richController.isActive(action)
        case .source: sourceController.isActive(action)
        }
    }

    @discardableResult
    public func insertMarkdown(_ markdown: String, replacing range: NSRange, label: String = "Insert") -> Bool {
        activeEditor.insertMarkdown(markdown, replacing: range, label: label)
    }

    @discardableResult
    public func insertMarkdown(_ markdown: String, label: String = "Insert") -> Bool {
        insertMarkdown(markdown, replacing: currentSelection, label: label)
    }

    @discardableResult
    public func replaceText(in range: NSRange, with text: String, label: String = "Replace") -> Bool {
        activeEditor.replaceText(in: range, with: text, label: label)
    }

    @discardableResult
    public func insertLink(label: String, url: String) -> Bool {
        activeEditor.insertLink(label: label, url: url)
    }

    @discardableResult
    public func insertInlineContent(
        _ content: ProseInlineContent,
        markdownSource: String,
        replacing range: NSRange,
        trailingText: String = " ",
        label: String = "Insert"
    ) -> Bool {
        activeEditor.insertInlineContent(content, markdownSource: markdownSource, replacing: range, trailingText: trailingText, label: label)
    }

    @discardableResult
    public func insertMarkdownAtLineStart(_ markdown: String, replacingLeading rule: InlineContentRule? = nil, label: String = "Insert") -> Bool {
        activeEditor.insertMarkdownAtLineStart(markdown, replacingLeading: rule, label: label)
    }

    public func pluginState<State>(for key: PluginKey<State>) -> State? {
        activeEditor.pluginState(for: key)
    }

    public func setPluginState<State>(_ state: State, for key: PluginKey<State>) {
        activeEditor.setPluginState(state, for: key)
    }

    public func clearPluginState<State>(for key: PluginKey<State>) {
        activeEditor.clearPluginState(for: key)
    }

    public var isFocused: Bool {
        guard let view = hostTextView else { return false }
        #if canImport(AppKit) && os(macOS)
        return view.window?.firstResponder === view
        #elseif canImport(UIKit)
        return view.isFirstResponder
        #else
        return false
        #endif
    }

    @discardableResult
    public func focus() -> Bool {
        guard isEditable, let view = hostTextView else { return false }
        #if canImport(AppKit) && os(macOS)
        guard let window = view.window else { return false }
        return window.firstResponder === view || window.makeFirstResponder(view)
        #elseif canImport(UIKit)
        guard view.window != nil else { return false }
        return view.isFirstResponder || view.becomeFirstResponder()
        #else
        return false
        #endif
    }

    static let richEditsActionName = "Rich Text Edits"
    static let sourceEditsActionName = "Markdown Source Edits"

    package func synchronize(for target: EditorMode) {
        let linked = linkedEpochs.map {
            $0.rich == richController.historyEpoch && $0.source == sourceController.historyEpoch
        } ?? false
        switch target {
        case .source:
            richController.flushPendingBinding()
            let markdown = richController.markdown()
            let selection = SourceSelectionMapping.sourceRange(
                forRich: richController.currentSelection,
                rich: richController.textStorage.string as NSString,
                source: markdown as NSString
            )
            if linked {
                sourceController.loadRecordingUndo(markdown, selection: selection, actionName: Self.richEditsActionName)
            } else {
                sourceController.loadIfChanged(markdown)
                sourceController.setSelection(selection)
            }
        case .rich:
            let text = sourceController.text
            let selection = sourceController.currentSelection
            if linked {
                richController.loadRecordingUndo(text, actionName: Self.sourceEditsActionName)
            } else {
                richController.applyExternalText(text)
            }
            richController.setSelection(SourceSelectionMapping.richRange(
                forSource: selection,
                rich: richController.textStorage.string as NSString,
                source: text as NSString
            ))
        }
        linkedEpochs = (richController.historyEpoch, sourceController.historyEpoch)
    }
}
