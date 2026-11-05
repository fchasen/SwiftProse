import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import Foundation
import SwiftUI

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: ProseTheme = .default
}

private struct ConfigurationKey: EnvironmentKey {
    static let defaultValue = SwiftProseEditor.Configuration()
}

private struct InlineContentProviderKey: EnvironmentKey {
    static let defaultValue: ProseInlineContentProvider? = nil
}

private struct InlineContentRulesKey: EnvironmentKey {
    static let defaultValue: [InlineContentRule] = []
}

private struct CodeBlockHighlighterKey: EnvironmentKey {
    static let defaultValue: CodeBlockHighlighter? = nil
}

private struct EditorReadyKey: EnvironmentKey {
    static let defaultValue: ((EditorController) -> Void)? = nil
}

private struct EditorModeKey: EnvironmentKey {
    static let defaultValue: Binding<EditorMode>? = nil
}

private struct EditorHandleKey: EnvironmentKey {
    static let defaultValue: ((EditorHandle) -> Void)? = nil
}

extension EnvironmentValues {
    public var proseEditorMode: Binding<EditorMode>? {
        get { self[EditorModeKey.self] }
        set { self[EditorModeKey.self] = newValue }
    }

    public var proseHandleReady: ((EditorHandle) -> Void)? {
        get { self[EditorHandleKey.self] }
        set { self[EditorHandleKey.self] = newValue }
    }

    public var proseTheme: ProseTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    public var proseConfiguration: SwiftProseEditor.Configuration {
        get { self[ConfigurationKey.self] }
        set { self[ConfigurationKey.self] = newValue }
    }

    public var proseInlineContentProvider: ProseInlineContentProvider? {
        get { self[InlineContentProviderKey.self] }
        set { self[InlineContentProviderKey.self] = newValue }
    }

    public var proseInlineContentRules: [InlineContentRule] {
        get { self[InlineContentRulesKey.self] }
        set { self[InlineContentRulesKey.self] = newValue }
    }

    public var proseCodeBlockHighlighter: CodeBlockHighlighter? {
        get { self[CodeBlockHighlighterKey.self] }
        set { self[CodeBlockHighlighterKey.self] = newValue }
    }

    public var proseControllerReady: ((EditorController) -> Void)? {
        get { self[EditorReadyKey.self] }
        set { self[EditorReadyKey.self] = newValue }
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
        _ provider: @escaping ProseInlineContentProvider
    ) -> some View {
        environment(\.proseInlineContentProvider, provider)
    }

    public func inlineContentRules(_ rules: [InlineContentRule]) -> some View {
        environment(\.proseInlineContentRules, rules)
    }

    public func codeBlockHighlighter(_ highlighter: CodeBlockHighlighter?) -> some View {
        environment(\.proseCodeBlockHighlighter, highlighter)
    }

    public func onProseControllerReady(
        _ callback: @escaping (EditorController) -> Void
    ) -> some View {
        environment(\.proseControllerReady, callback)
    }

    public func editorMode(_ mode: Binding<EditorMode>) -> some View {
        environment(\.proseEditorMode, mode)
    }

    public func onProseHandleReady(
        _ callback: @escaping (EditorHandle) -> Void
    ) -> some View {
        environment(\.proseHandleReady, callback)
    }

    public func editable(_ isEditable: Bool = true) -> some View {
        transformEnvironment(\.proseConfiguration) { config in
            config.isEditable = isEditable
        }
    }
}
