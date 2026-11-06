import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import Foundation
import SwiftUI

struct EditorToolbar: View {
    let items: [SwiftProseEditor.ToolbarItem]
    let perform: (SwiftProseEditor.Action) -> Void
    var canPerform: (SwiftProseEditor.Action) -> Bool = { _ in true }
    var isActive: (SwiftProseEditor.Action) -> Bool = { _ in false }
    var isEnabled: Bool = true
    var mode: EditorMode = .rich
    var onToggleMode: (() -> Void)?

    var body: some View {
        let groups = makeGroups(from: items, includesModeToggle: onToggleMode != nil)
        let row = GlassEffectContainer(spacing: ToolbarButtonMetrics.groupSpacing / 2) {
            HStack(spacing: ToolbarButtonMetrics.groupSpacing) {
                ForEach(groups.indices, id: \.self) { i in
                    groupView(groups[i])
                }
            }
        }
        .controlSize(.small)
        .disabled(!isEnabled)
        #if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) {
            row
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        #else
        row
        #endif
    }

    @ViewBuilder
    private func groupView(_ group: ToolbarGroup) -> some View {
        switch group {
        case .spacer:
            Spacer()
        case .items(let items):
            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    if i > 0 {
                        ToolbarSeparator()
                            .opacity(itemIsActive(items[i - 1]) || itemIsActive(items[i]) ? 0 : 1)
                    }
                    button(for: items[i])
                }
            }
            .padding(ToolbarButtonMetrics.groupInset)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
        }
    }

    private func itemIsActive(_ item: SwiftProseEditor.ToolbarItem) -> Bool {
        if case .action(let action) = item { return isActive(action) }
        return false
    }

    @ViewBuilder
    private func button(for item: SwiftProseEditor.ToolbarItem) -> some View {
        switch item {
        case .action(.heading(let level)):
            ToolbarLabelButton(
                label: "H\(level)",
                help: SwiftProseEditor.Action.heading(level: level).helpText,
                shortcut: nil,
                isActive: isActive(.heading(level: level)),
                action: { perform(.heading(level: level)) }
            )
            .disabled(!canPerform(.heading(level: level)))
        case .action(let action):
            ToolbarActionButton(
                systemImage: action.systemImage,
                help: action.helpText,
                shortcut: nil,
                isActive: isActive(action),
                action: { perform(action) }
            )
            .disabled(!canPerform(action))
        case let .custom(_, label, symbol, shortcut, _, customPerform):
            ToolbarActionButton(
                systemImage: symbol,
                help: label,
                shortcut: shortcut,
                isActive: false,
                action: customPerform
            )
        case let .menu(_, label, symbol, _, entries):
            ToolbarMenuButton(systemImage: symbol, help: label, entries: entries)
        case .modeToggle:
            if let onToggleMode {
                ToolbarActionButton(
                    systemImage: SwiftProseEditor.modeToggleSystemImage(for: mode),
                    help: SwiftProseEditor.modeToggleTitle(for: mode),
                    shortcut: nil,
                    isActive: false,
                    action: onToggleMode
                )
            }
        case .divider, .spacer:
            EmptyView()
        }
    }
}

private enum ToolbarGroup {
    case items([SwiftProseEditor.ToolbarItem])
    case spacer
}

private func makeGroups(from items: [SwiftProseEditor.ToolbarItem], includesModeToggle: Bool) -> [ToolbarGroup] {
    var groups: [ToolbarGroup] = []
    var current: [SwiftProseEditor.ToolbarItem] = []

    func flush() {
        if !current.isEmpty {
            groups.append(.items(current))
            current.removeAll()
        }
    }

    for item in items {
        switch item {
        case .modeToggle where !includesModeToggle:
            continue
        case .divider:
            flush()
        case .spacer:
            flush()
            groups.append(.spacer)
        default:
            current.append(item)
        }
    }
    flush()
    return groups
}

private struct ToolbarMenuButton: View {
    let systemImage: String
    let help: String
    let entries: [SwiftProseEditor.MenuEntry]

    var body: some View {
        Menu {
            ForEach(entries.indices, id: \.self) { i in
                let entry = entries[i]
                Button(action: entry.action) {
                    if let symbol = entry.systemImage {
                        Label(entry.title, systemImage: symbol)
                    } else {
                        Text(entry.title)
                    }
                }
            }
        } label: {
            Image(systemName: systemImage)
                .frame(width: ToolbarButtonMetrics.width, height: ToolbarButtonMetrics.height)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

private struct ToolbarActionButton: View {
    let systemImage: String
    let help: String
    let shortcut: KeyboardShortcut?
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(ToolbarGlassButtonStyle(isActive: isActive))
        .help(help)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private struct ToolbarLabelButton: View {
    let label: String
    let help: String
    let shortcut: KeyboardShortcut?
    var isActive: Bool = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 13

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: labelSize, weight: .semibold))
        }
        .buttonStyle(ToolbarGlassButtonStyle(isActive: isActive))
        .help(help)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private struct ToolbarGlassButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        ToolbarGlassButtonBody(
            label: configuration.label,
            isActive: isActive,
            isPressed: configuration.isPressed
        )
    }
}

private struct ToolbarGlassButtonBody<Label: View>: View {
    let label: Label
    let isActive: Bool
    let isPressed: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .frame(width: ToolbarButtonMetrics.width, height: ToolbarButtonMetrics.height)
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var fill: AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(Color.accentColor.opacity(isPressed ? 0.8 : 1))
        }
        if isPressed {
            return AnyShapeStyle(Color.primary.opacity(0.14))
        }
        if isHovered, isEnabled {
            return AnyShapeStyle(Color.primary.opacity(0.07))
        }
        return AnyShapeStyle(Color.clear)
    }
}

private struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: ToolbarButtonMetrics.separatorHeight)
    }
}

private enum ToolbarButtonMetrics {
    #if os(iOS)
    static let width: CGFloat = 40
    static let height: CGFloat = 32
    static let separatorHeight: CGFloat = 16
    #else
    static let width: CGFloat = 32
    static let height: CGFloat = 24
    static let separatorHeight: CGFloat = 14
    #endif
    static let groupInset: CGFloat = 2
    static let groupSpacing: CGFloat = 8
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

extension Array where Element == SwiftProseEditor.ToolbarItem {
    var actions: [EditorAction] {
        compactMap { item in
            if case .action(let action) = item { return action }
            return nil
        }
    }
}

enum EditorToolbarActions {
    static func perform(
        _ action: SwiftProseEditor.Action,
        controller: EditorController
    ) {
        controller.perform(action)
    }
}
