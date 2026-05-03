import Foundation
import SwiftUI
@_exported import MarginaliaSyntax
@_exported import MarginaliaRendering
@_exported import MarginaliaView

#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct Marginalia: View {
    @Binding public var text: String

    @Environment(\.marginaliaConfiguration) private var configuration
    @Environment(\.marginaliaDialect) private var dialect
    @Environment(\.marginaliaTheme) private var theme
    @Environment(\.marginaliaInlineContentProvider) private var inlineProvider
    @Environment(\.marginaliaControllerReady) private var onControllerReady

    @AppStorage("marginalia.toolbarVisible") private var toolbarVisible = true
    @AppStorage("marginalia.mode") private var modeRawValue: String = Mode.rich.rawValue
    @StateObject private var hosting = MarginaliaHosting()

    private var mode: Mode {
        Mode(rawValue: modeRawValue) ?? .rich
    }

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if toolbarVisible, !configuration.toolbar.isEmpty || !configuration.statusItems.isEmpty {
                HStack(spacing: 12) {
                    if !configuration.toolbar.isEmpty {
                        MarginaliaToolbar(
                            items: configuration.toolbar + [.spacer, modeToggleItem],
                            perform: { action in
                                guard let controller = hosting.controller else { return }
                                MarginaliaToolbarActions.perform(
                                    action,
                                    controller: controller,
                                    text: $text
                                )
                            }
                        )
                    }
                    if !configuration.statusItems.isEmpty {
                        Spacer()
                        MarginaliaStatusBar(
                            items: configuration.statusItems,
                            text: text,
                            selection: NSRange(location: 0, length: 0)
                        )
                    }
                }
                .padding(6)
            }
            editorBody
        }
        .onAppear {
            hosting.ensureController(initialText: text, dialect: dialect, theme: theme, mode: mode)
            if let controller = hosting.controller {
                if controller.markdown() != text { controller.setMarkdown(text) }
                controller.mode = mode
                onControllerReady?(controller)
            }
        }
        .onChange(of: dialect) { _, newDialect in
            hosting.controller?.dialect = newDialect
        }
        .onChange(of: theme) { _, newTheme in
            hosting.controller?.theme = newTheme
        }
        .onChange(of: modeRawValue) { _, _ in
            hosting.controller?.mode = mode
        }
    }

    private var modeToggleItem: Marginalia.ToolbarItem {
        let label = mode == .source ? "Show rendered" : "Show source"
        let symbol = mode == .source ? "eye" : "doc.plaintext"
        return .custom(
            id: "marginaliaModeToggle",
            label: label,
            systemImage: symbol,
            shortcut: nil,
            topLevel: true,
            action: {
                let next: Mode = (mode == .source) ? .rich : .source
                modeRawValue = next.rawValue
            }
        )
    }

    @ViewBuilder
    private var editorBody: some View {
        if let controller = hosting.controller {
            #if os(macOS)
            MarginaliaTextViewMac(
                controller: controller,
                text: $text,
                sizing: configuration.sizing,
                minHeight: configuration.minHeight,
                contextMenuItems: macContextMenuItems()
            )
            .modifier(SizingFrame(sizing: configuration.sizing))
            #else
            MarginaliaTextViewIOS(
                controller: controller,
                text: $text,
                sizing: configuration.sizing,
                minHeight: configuration.minHeight,
                editMenuBuilder: makeIOSEditMenuBuilder(controller: controller)
            )
            .modifier(SizingFrame(sizing: configuration.sizing))
            #endif
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: configuration.minHeight)
        }
    }

    #if os(macOS)
    private func macContextMenuItems() -> [MarginaliaContextMenuItem] {
        var items: [MarginaliaContextMenuItem] = []
        if !configuration.toolbar.isEmpty {
            let visible = toolbarVisible
            items.append(MarginaliaContextMenuItem(
                title: "Show Toolbar",
                systemImage: "richtext.page",
                isOn: visible,
                action: { toolbarVisible.toggle() }
            ))
        }
        items.append(contentsOf: configuration.contextMenuItems.map { item in
            MarginaliaContextMenuItem(
                title: item.title,
                systemImage: item.systemImage,
                isOn: item.isOn,
                action: item.action
            )
        })
        return items
    }
    #endif

    #if os(iOS)
    private func makeIOSEditMenuBuilder(controller: EditorController) -> MarginaliaTextViewIOS.EditMenuBuilder? {
        let toolbar = configuration.toolbar
        guard !toolbar.isEmpty else { return nil }
        let textBinding = $text
        return { _, suggested in
            var topLevel: [UIAction] = []
            var sections: [UIMenuElement] = []
            var current: [UIAction] = []
            func flush() {
                if !current.isEmpty {
                    sections.append(UIMenu(title: "", options: .displayInline, children: current))
                    current.removeAll()
                }
            }
            for item in toolbar {
                switch item {
                case .action(let action):
                    current.append(UIAction(
                        title: editMenuTitle(for: action),
                        image: UIImage(systemName: editMenuSymbol(for: action))
                    ) { _ in
                        MarginaliaToolbarActions.perform(
                            action,
                            controller: controller,
                            text: textBinding
                        )
                    })
                case .custom(_, let label, let symbol, _, let isTopLevel, let custom):
                    let action = UIAction(
                        title: label,
                        image: UIImage(systemName: symbol),
                        handler: { _ in custom() }
                    )
                    if isTopLevel {
                        flush()
                        topLevel.append(action)
                    } else {
                        current.append(action)
                    }
                case .divider, .spacer:
                    flush()
                }
            }
            flush()
            var children: [UIMenuElement] = suggested
            children.append(contentsOf: topLevel)
            if !sections.isEmpty {
                children.append(UIMenu(
                    title: "Format",
                    image: UIImage(systemName: "textformat"),
                    children: sections
                ))
            }
            return UIMenu(children: children)
        }
    }
    #endif
}

#if os(iOS)
private func editMenuTitle(for action: Marginalia.Action) -> String {
    switch action {
    case .bold: return "Bold"
    case .italic: return "Italic"
    case .strikethrough: return "Strikethrough"
    case .heading(let level): return "Heading \(level)"
    case .unorderedList: return "Bullet List"
    case .orderedList: return "Numbered List"
    case .taskList: return "Task List"
    case .blockquote: return "Quote"
    case .codeSpan: return "Inline Code"
    case .codeBlock: return "Code Block"
    case .link: return "Link"
    case .horizontalRule: return "Horizontal Rule"
    case .indent: return "Indent"
    case .outdent: return "Outdent"
    }
}

private func editMenuSymbol(for action: Marginalia.Action) -> String {
    switch action {
    case .bold: return "bold"
    case .italic: return "italic"
    case .strikethrough: return "strikethrough"
    case .heading(let level): return "h\(level).square"
    case .unorderedList: return "list.bullet"
    case .orderedList: return "list.number"
    case .taskList: return "checklist"
    case .blockquote: return "text.quote"
    case .codeSpan: return "chevron.left.slash.chevron.right"
    case .codeBlock: return "curlybraces"
    case .link: return "link"
    case .horizontalRule: return "minus"
    case .indent: return "increase.indent"
    case .outdent: return "decrease.indent"
    }
}
#endif

private struct SizingFrame: ViewModifier {
    let sizing: EditorSizing
    func body(content: Content) -> some View {
        switch sizing {
        case .fitsContent:
            content.frame(maxWidth: .infinity)
        case .fillContainer:
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class MarginaliaHosting: ObservableObject {
    @Published var controller: EditorController?

    func ensureController(
        initialText: String,
        dialect: Dialect,
        theme: MarginaliaTheme,
        mode: Mode
    ) {
        if controller == nil {
            controller = try? EditorController(
                initialMarkdown: initialText,
                theme: theme,
                dialect: dialect,
                mode: mode
            )
        }
    }
}
