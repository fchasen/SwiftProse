import Foundation
import SwiftUI
import MarginaliaView
import MarginaliaRendering

// MARK: - environment values

private struct DialectKey: EnvironmentKey {
    static let defaultValue: Dialect = .commonMark
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: MarginaliaTheme = .default
}

private struct ConfigurationKey: EnvironmentKey {
    static let defaultValue = Marginalia.Configuration()
}

private struct InlineContentProviderKey: EnvironmentKey {
    static let defaultValue: ((MarginaliaInlineContent) -> NSTextAttachment?)? = nil
}

private struct ControllerReadyKey: EnvironmentKey {
    static let defaultValue: ((EditorController) -> Void)? = nil
}

extension EnvironmentValues {
    public var marginaliaDialect: Dialect {
        get { self[DialectKey.self] }
        set { self[DialectKey.self] = newValue }
    }

    public var marginaliaTheme: MarginaliaTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    public var marginaliaConfiguration: Marginalia.Configuration {
        get { self[ConfigurationKey.self] }
        set { self[ConfigurationKey.self] = newValue }
    }

    public var marginaliaInlineContentProvider: ((MarginaliaInlineContent) -> NSTextAttachment?)? {
        get { self[InlineContentProviderKey.self] }
        set { self[InlineContentProviderKey.self] = newValue }
    }

    public var marginaliaControllerReady: ((EditorController) -> Void)? {
        get { self[ControllerReadyKey.self] }
        set { self[ControllerReadyKey.self] = newValue }
    }
}

// MARK: - public modifiers

extension View {
    public func dialect(_ dialect: Dialect) -> some View {
        environment(\.marginaliaDialect, dialect)
    }

    public func theme(_ theme: MarginaliaTheme) -> some View {
        environment(\.marginaliaTheme, theme)
    }

    public func configuration(_ configuration: Marginalia.Configuration) -> some View {
        environment(\.marginaliaConfiguration, configuration)
    }

    public func inlineContentProvider(
        _ provider: @escaping (MarginaliaInlineContent) -> NSTextAttachment?
    ) -> some View {
        environment(\.marginaliaInlineContentProvider, provider)
    }

    /// Receive the live `EditorController` once the editor finishes setup.
    /// Invoked from `onAppear`, so callers can capture the controller in
    /// `@State` and route cursor-aware insertions (link, image, mention)
    /// through it.
    public func onMarginaliaControllerReady(
        _ callback: @escaping (EditorController) -> Void
    ) -> some View {
        environment(\.marginaliaControllerReady, callback)
    }
}
