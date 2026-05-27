import Foundation
import SwiftUI
@_exported import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Where the completion popup sits relative to the caret.
///
/// Retained as an API hint for hosts; the actual placement is now decided
/// by `CompletionPopupPlacement.origin` based on available room. The case
/// is ignored at render time.
@available(*, deprecated, message: "Placement is auto-decided; this parameter is ignored. See ProseCompletionConfiguration.containerBoundsProvider.")
public enum CompletionPlacement: Sendable {
    case below
    case above
}

/// Smart placement for the completion popup, ported from zilla-tracker.
///
/// Picks below-the-caret if there's room, otherwise above, otherwise
/// whichever side has more room. Horizontal position is clamped inside
/// `containerBounds` with a small edge inset.
public enum CompletionPopupPlacement {
    public static func origin(
        anchorRect: CGRect,
        menuSize: CGSize,
        containerBounds: CGRect,
        gap: CGFloat = 4,
        edgeInset: CGFloat = 24
    ) -> CGPoint {
        let horizontalInset = min(edgeInset, max(0, (containerBounds.width - menuSize.width) / 2))
        let verticalInset = min(edgeInset, max(0, containerBounds.height / 4))
        let effectiveBounds = containerBounds.insetBy(dx: horizontalInset, dy: verticalInset)
        let maxX = max(effectiveBounds.minX, effectiveBounds.maxX - menuSize.width)
        let x = min(max(anchorRect.minX, effectiveBounds.minX), maxX)
        let belowY = anchorRect.maxY + gap
        let aboveY = anchorRect.minY - menuSize.height - gap
        let availableBelow = effectiveBounds.maxY - belowY
        let availableAbove = anchorRect.minY - effectiveBounds.minY - gap
        let y: CGFloat
        if availableBelow >= menuSize.height {
            y = belowY
        } else if availableAbove >= menuSize.height {
            y = aboveY
        } else if availableBelow >= availableAbove {
            y = belowY
        } else {
            y = aboveY
        }
        return CGPoint(x: x, y: y)
    }
}

/// Host-supplied configuration for the in-line completions popup. Generic
/// over `Item` so the host owns the data shape and the row builder.
public struct ProseCompletionConfiguration<Item: Identifiable> {
    public let triggers: [CompletionTrigger]
    public let fetch: (CompletionContext) async -> [Item]
    public let row: (Item, Bool) -> AnyView
    public let onSelect: (EditorController, NSRange, Item) -> Void
    public let maxHeight: CGFloat
    public let width: CGFloat
    /// Optional closure returning the room the popup is allowed to use, in
    /// the editor view's local coordinate space. When `nil`, the editor's
    /// own bounds are used — fine for full-screen editors but typically
    /// too small for a bottom-anchored composer. Hosts that want
    /// window-level smart-flipping should supply this.
    public let containerBoundsProvider: (@MainActor () -> CGRect)?
    /// Optional closure returning the popup's preferred width in points.
    /// When non-nil, overrides `width` per render — lets the popup track a
    /// resizable host (e.g. a composer card that stretches with the
    /// window). Return a clamped value if you want min/max bounds.
    public let widthProvider: (@MainActor () -> CGFloat)?

    public init(
        triggers: [CompletionTrigger],
        fetch: @escaping (CompletionContext) async -> [Item],
        row: @escaping (Item, Bool) -> AnyView,
        onSelect: @escaping (EditorController, NSRange, Item) -> Void,
        maxHeight: CGFloat = 240,
        width: CGFloat = 280,
        containerBoundsProvider: (@MainActor () -> CGRect)? = nil,
        widthProvider: (@MainActor () -> CGFloat)? = nil
    ) {
        self.triggers = triggers
        self.fetch = fetch
        self.row = row
        self.onSelect = onSelect
        self.maxHeight = maxHeight
        self.width = width
        self.containerBoundsProvider = containerBoundsProvider
        self.widthProvider = widthProvider
    }

    @available(*, deprecated, message: "The placement parameter is ignored — placement is auto-decided. Migrate to containerBoundsProvider.")
    public init(
        triggers: [CompletionTrigger],
        fetch: @escaping (CompletionContext) async -> [Item],
        row: @escaping (Item, Bool) -> AnyView,
        onSelect: @escaping (EditorController, NSRange, Item) -> Void,
        maxHeight: CGFloat = 240,
        width: CGFloat = 280,
        placement: CompletionPlacement
    ) {
        self.init(
            triggers: triggers,
            fetch: fetch,
            row: row,
            onSelect: onSelect,
            maxHeight: maxHeight,
            width: width,
            containerBoundsProvider: nil,
            widthProvider: nil
        )
        _ = placement
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

private struct PopupHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PopupContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct EditorGlobalFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ProseCompletionsModifier<Item: Identifiable>: ViewModifier {
    let configuration: ProseCompletionConfiguration<Item>

    @State private var controller: EditorController?
    @State private var session: CompletionSession?
    @State private var items: [Item] = []
    @State private var fetchTask: Task<Void, Never>?
    @State private var plugin: CompletionPlugin?
    @State private var popupHeight: CGFloat = 0
    @State private var editorGlobalFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onProseControllerReady { ctrl in
                attach(to: ctrl)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: EditorGlobalFrameKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            )
            .onPreferenceChange(EditorGlobalFrameKey.self) { newValue in
                editorGlobalFrame = newValue
            }
            .overlay(alignment: .topLeading) {
                if let session, let controller, !items.isEmpty {
                    CompletionPopup(
                        session: session,
                        items: items,
                        configuration: configuration,
                        maxHeight: configuration.maxHeight
                    )
                    .frame(width: popupWidth())
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(popupBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PopupHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                    .onPreferenceChange(PopupHeightPreferenceKey.self) { newHeight in
                        popupHeight = newHeight
                    }
                    .offset(popupOffset(for: session, controller: controller))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: session != nil && !items.isEmpty)
    }

    private func dynamicMaxHeight(itemCount: Int) -> CGFloat {
        // Per-item height covers the two-line rows hosts may use (basename
        // + subtitle / handle + display-name). 44pt was too tight for
        // two-line rows and clipped the second line.
        min(configuration.maxHeight, max(48, CGFloat(itemCount) * 52))
    }

    @MainActor
    private func popupWidth() -> CGFloat {
        configuration.widthProvider?() ?? configuration.width
    }

    /// Solid, opaque popup chrome. We deliberately bypass SwiftUI's
    /// `.background` ShapeStyle — when the popup is nested inside a host
    /// that uses a Liquid-Glass material (e.g. a `.glassEffect` composer
    /// card), the material can bleed through and produce a frosted look
    /// that's wrong for a completion menu. A concrete `NSColor`/`UIColor`
    /// renders as a flat fill regardless of the surrounding context.
    private var popupBackground: Color {
        #if canImport(AppKit) && os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color.white
        #endif
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

    @MainActor
    private func popupOffset(
        for session: CompletionSession,
        controller: EditorController
    ) -> CGSize {
        guard let rect = session.context.caretRect ?? controller.caretRect() else {
            return .zero
        }
        let height = popupHeight > 0 ? popupHeight : configuration.maxHeight
        let width = popupWidth()
        let bounds = configuration.containerBoundsProvider?() ?? defaultContainerBounds(controller: controller)
        let effectiveBounds = bounds.width > 0 && bounds.height > 0
            ? bounds
            : CGRect(x: rect.minX - 200, y: rect.minY - height - 400,
                     width: max(width, 400), height: height + 400)
        let origin = CompletionPopupPlacement.origin(
            anchorRect: rect,
            menuSize: CGSize(width: width, height: height),
            containerBounds: effectiveBounds
        )
        return CGSize(width: origin.x, height: origin.y)
    }

    /// Compute the container the popup is allowed to occupy, expressed in
    /// the editor's local coordinate space.
    ///
    /// We sidestep SwiftUI's coordinate-space ambiguity by going through
    /// AppKit/UIKit: ask the controller's host text view for its window's
    /// content view and convert that view's bounds into the text view's
    /// local space. `NSView.convert(_:to:)` / `UIView.convert(_:to:)`
    /// handle flipped-vs-unflipped automatically. SwiftUI lays the text
    /// view out flipped (top-left origin), so the result lines up with
    /// the caret rect that SwiftProse hands us.
    @MainActor
    private func defaultContainerBounds(controller: EditorController) -> CGRect {
        #if os(macOS)
        if let textView = controller.hostTextView as? NSView,
           let contentView = textView.window?.contentView {
            return contentView.convert(contentView.bounds, to: textView)
        }
        #elseif canImport(UIKit)
        if let textView = controller.hostTextView as? UIView {
            let host = textView.window ?? textView
            return host.convert(host.bounds, to: textView)
        }
        #endif
        if editorGlobalFrame.size != .zero {
            return CGRect(origin: .zero, size: editorGlobalFrame.size)
        }
        return CGRect(x: 0, y: 0, width: 600, height: 400)
    }
}

private struct CompletionPopup<Item: Identifiable>: View {
    let session: CompletionSession
    let items: [Item]
    let configuration: ProseCompletionConfiguration<Item>
    let maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Measure the VStack content so the scroll view can collapse to
        // exactly the height it needs when only a few rows are visible —
        // otherwise SwiftUI's ScrollView greedily expands to `maxHeight`
        // and the placement math drives the popup hundreds of points
        // away from the caret.
        let clampedHeight = min(maxHeight, max(0, contentHeight))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        configuration.row(item, index == session.highlightedIndex)
                            .id(index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PopupContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            }
            .onChange(of: session.highlightedIndex) { _, new in
                proxy.scrollTo(new, anchor: .center)
            }
        }
        .frame(height: clampedHeight > 0 ? clampedHeight : nil)
        .onPreferenceChange(PopupContentHeightKey.self) { newHeight in
            contentHeight = newHeight
        }
    }
}
