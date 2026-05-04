import Foundation
import SwiftUI
import SwiftProseView
import SwiftProseRendering
import SwiftProseSyntax

// MARK: - environment values

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: ProseTheme = .default
}

private struct ConfigurationKey: EnvironmentKey {
    static let defaultValue = SwiftProseEditor.Configuration()
}

private struct InlineContentProviderKey: EnvironmentKey {
    static let defaultValue: ((ProseInlineContent) -> NSTextAttachment?)? = nil
}

private struct ControllerReadyKey: EnvironmentKey {
    static let defaultValue: ((EditorController) -> Void)? = nil
}

private struct CodeBlockHighlighterKey: EnvironmentKey {
    static let defaultValue: CodeBlockHighlighter? = nil
}

extension EnvironmentValues {
    public var proseTheme: ProseTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    public var proseConfiguration: SwiftProseEditor.Configuration {
        get { self[ConfigurationKey.self] }
        set { self[ConfigurationKey.self] = newValue }
    }

    public var proseInlineContentProvider: ((ProseInlineContent) -> NSTextAttachment?)? {
        get { self[InlineContentProviderKey.self] }
        set { self[InlineContentProviderKey.self] = newValue }
    }

    public var proseControllerReady: ((EditorController) -> Void)? {
        get { self[ControllerReadyKey.self] }
        set { self[ControllerReadyKey.self] = newValue }
    }

    public var proseCodeBlockHighlighter: CodeBlockHighlighter? {
        get { self[CodeBlockHighlighterKey.self] }
        set { self[CodeBlockHighlighterKey.self] = newValue }
    }
}

extension View {
    public func theme(_ theme: ProseTheme) -> some View {
        environment(\.proseTheme, theme)
    }

    public func configuration(_ configuration: SwiftProseEditor.Configuration) -> some View {
        environment(\.proseConfiguration, configuration)
    }

    public func inlineContentProvider(
        _ provider: @escaping (ProseInlineContent) -> NSTextAttachment?
    ) -> some View {
        environment(\.proseInlineContentProvider, provider)
    }

    /// Receive the live `EditorController` once the editor finishes setup.
    /// Invoked from `onAppear`, so callers can capture the controller in
    /// `@State` and route cursor-aware insertions (link, image, mention)
    /// through it.
    public func onProseControllerReady(
        _ callback: @escaping (EditorController) -> Void
    ) -> some View {
        environment(\.proseControllerReady, callback)
    }

    /// Inject a tree-sitter (or other) `CodeBlockHighlighter` to syntax-color
    /// fenced code-block bodies. The host registers per-language grammars on
    /// the highlighter before passing it in.
    public func codeBlockHighlighter(
        _ highlighter: CodeBlockHighlighter?
    ) -> some View {
        environment(\.proseCodeBlockHighlighter, highlighter)
    }
}
