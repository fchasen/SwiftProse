import Foundation
import SwiftUI
import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Host-supplied configuration for the in-line completions popup. Generic
/// over `Item` so the host owns the data shape and the row builder.
public struct ProseCompletionConfiguration<Item: Identifiable> {
    public let triggers: [CompletionTrigger]
    public let fetch: (CompletionContext) async -> [Item]
    public let row: (Item, Bool) -> AnyView
    public let onSelect: (EditorController, NSRange, Item) -> Void
    public let maxHeight: CGFloat
    public let width: CGFloat

    public init(
        triggers: [CompletionTrigger],
        fetch: @escaping (CompletionContext) async -> [Item],
        row: @escaping (Item, Bool) -> AnyView,
        onSelect: @escaping (EditorController, NSRange, Item) -> Void,
        maxHeight: CGFloat = 240,
        width: CGFloat = 280
    ) {
        self.triggers = triggers
        self.fetch = fetch
        self.row = row
        self.onSelect = onSelect
        self.maxHeight = maxHeight
        self.width = width
    }
}

extension View {
    /// Wire up an inline-completions popup driven by a `CompletionPlugin`.
    /// The popup positions itself against the caret rect, lets the host
    /// render rows, and dispatches to `onSelect` on Enter / Tab / click.
    public func proseCompletions<Item: Identifiable>(
        _ configuration: ProseCompletionConfiguration<Item>
    ) -> some View {
        modifier(ProseCompletionsModifier(configuration: configuration))
    }
}

private struct ProseCompletionsModifier<Item: Identifiable>: ViewModifier {
    let configuration: ProseCompletionConfiguration<Item>

    @State private var controller: EditorController?
    @State private var session: CompletionSession?
    @State private var items: [Item] = []
    @State private var fetchTask: Task<Void, Never>?
    @State private var plugin: CompletionPlugin?

    func body(content: Content) -> some View {
        content
            .onProseControllerReady { ctrl in
                attach(to: ctrl)
            }
            .overlay(alignment: .topLeading) {
                if let session, let controller, !items.isEmpty {
                    CompletionPopup(
                        session: session,
                        items: items,
                        configuration: configuration
                    )
                    .frame(width: configuration.width)
                    .frame(maxHeight: configuration.maxHeight)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4, y: 2)
                    .offset(popupOffset(for: session, controller: controller))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: session != nil && !items.isEmpty)
    }

    private func attach(to ctrl: EditorController) {
        let plugin = CompletionPlugin(triggers: configuration.triggers)
        plugin.onSessionChanged = { newSession in
            DispatchQueue.main.async {
                self.session = newSession
                if let newSession {
                    refetch(for: newSession.context, controller: ctrl, plugin: plugin)
                } else {
                    fetchTask?.cancel()
                    items = []
                }
            }
        }
        plugin.onCommit = { ctrl, session in
            // Pull the latest items from the SwiftUI state directly.
            DispatchQueue.main.async {
                guard !self.items.isEmpty,
                      session.highlightedIndex >= 0,
                      session.highlightedIndex < self.items.count else { return }
                let item = self.items[session.highlightedIndex]
                configuration.onSelect(ctrl, session.context.range, item)
            }
        }
        ctrl.register(plugin: plugin)
        plugin.attach(to: ctrl)
        self.controller = ctrl
        self.plugin = plugin
    }

    private func refetch(
        for context: CompletionContext,
        controller: EditorController,
        plugin: CompletionPlugin
    ) {
        fetchTask?.cancel()
        let fetch = configuration.fetch
        fetchTask = Task {
            let results = await fetch(context)
            if Task.isCancelled { return }
            await MainActor.run {
                self.items = results
                plugin.updateItemCount(results.count, controller: controller)
            }
        }
    }

    private func popupOffset(
        for session: CompletionSession,
        controller: EditorController
    ) -> CGSize {
        guard let rect = session.context.caretRect ?? controller.caretRect() else {
            return .zero
        }
        // Place the popup just below the caret line.
        return CGSize(width: rect.minX, height: rect.maxY + 4)
    }
}

private struct CompletionPopup<Item: Identifiable>: View {
    let session: CompletionSession
    let items: [Item]
    let configuration: ProseCompletionConfiguration<Item>

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        configuration.row(item, index == session.highlightedIndex)
                            .id(index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .onChange(of: session.highlightedIndex) { _, new in
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }
}
