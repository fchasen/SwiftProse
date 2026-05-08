import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) && os(macOS)
/// `NSScrollView` that forwards primarily-vertical scroll-wheel events
/// to its `nextResponder` so the host editor scrolls underneath when
/// the cursor sits over a table. Only events whose dominant axis is
/// horizontal are kept here for the table to scroll its own columns.
/// Without this, scrolling the wheel inside a table dead-ends at the
/// table's scroll view and the document doesn't move at all.
final class TableHostingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        // Treat ambiguous (mostly-zero) and primarily-vertical events as
        // "not for the table"; bubble them up. The horizontal-only path
        // keeps trackpad two-finger sideways scrolls and shift+wheel
        // events targeting the table's own scroll bar.
        if dx > dy {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
#endif

/// Cross-platform horizontal scroll container that wraps a
/// `TableBlockView` so tables whose natural column widths exceed the
/// host text container's width can still be reached without crushing
/// columns into illegible widths. The container's outer frame matches
/// the line fragment width; the inner `TableBlockView` is sized to its
/// natural total width, which is also the scroll content size.
///
/// Cells inside the table render at their natural widths regardless
/// of platform — the column-width algorithm in `TableBlockView`
/// stops shrinking once it hits the content's natural single-line
/// width and the scroll container picks up the slack.
public final class TableScrollContainer: PlatformView {
    public let tableBlockView: TableBlockView

    #if canImport(AppKit) && os(macOS)
    private let scrollView: TableHostingScrollView
    #elseif canImport(UIKit)
    private let scrollView: UIScrollView
    #endif

    /// Wraps an additional layout-change hook so the parent provider's
    /// own `layoutDidChange` (which invalidates the TextKit attachment
    /// range so the line fragment re-queries `attachmentBounds`) keeps
    /// firing alongside our own scroll-content-size update.
    private var nestedLayoutDidChange: (() -> Void)?

    public init(tableBlockView: TableBlockView) {
        self.tableBlockView = tableBlockView
        #if canImport(AppKit) && os(macOS)
        let sv = TableHostingScrollView()
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = false
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.autohidesScrollers = true
        sv.horizontalScrollElasticity = .none
        sv.verticalScrollElasticity = .none
        sv.scrollerStyle = .overlay
        sv.documentView = tableBlockView
        self.scrollView = sv
        #elseif canImport(UIKit)
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = true
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceVertical = false
        sv.alwaysBounceHorizontal = false
        sv.bouncesZoom = false
        sv.delaysContentTouches = false
        sv.canCancelContentTouches = true
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.isOpaque = false
        sv.clipsToBounds = true
        sv.addSubview(tableBlockView)
        self.scrollView = sv
        #endif
        super.init(frame: .zero)
        #if canImport(AppKit) && os(macOS)
        wantsLayer = true
        // Background drawn under everything else — keeps the scroll
        // view's transparent gutter showing the table's own background
        // rather than whatever sits behind the editor.
        layer?.backgroundColor = TableBlockView.backgroundColor.cgColor
        #elseif canImport(UIKit)
        backgroundColor = TableBlockView.backgroundColor
        isOpaque = false
        clipsToBounds = true
        #endif
        addSubview(scrollView)
        wireSizeChangeHook()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    /// Hook into `TableBlockView.layoutDidChange` so updates to the
    /// inner natural size flow through to scroll content size and
    /// onward to the TextKit attachment invalidation.
    private func wireSizeChangeHook() {
        let prior = tableBlockView.layoutDidChange
        nestedLayoutDidChange = prior
        tableBlockView.layoutDidChange = { [weak self] in
            self?.refreshScrollGeometry()
            self?.nestedLayoutDidChange?()
        }
    }

    /// Resync the scroll view's visible frame and content size after
    /// either the inner `TableBlockView` resizes or the outer container
    /// receives a new frame from the attachment provider. The outer
    /// width is the container's frame; the inner width is the table's
    /// natural total — when they differ, the scroll view exposes the
    /// horizontal overflow.
    public func refreshScrollGeometry() {
        let outerSize = bounds.size
        let innerSize = tableBlockView.bounds.size
        // The scroll view always fills the container.
        let scrollFrame = CGRect(origin: .zero, size: outerSize)
        if !scrollView.frame.equalTo(scrollFrame) {
            scrollView.frame = scrollFrame
        }
        // Position the inner table at (0, 0) inside the scroll view.
        // Width is the inner natural width (could exceed outer width).
        // Height matches outer height so the table fills the line
        // fragment vertically — TextKit 2 sized the line fragment from
        // the same intrinsic measurement.
        let tableFrame = CGRect(
            x: 0, y: 0,
            width: max(innerSize.width, outerSize.width),
            height: outerSize.height
        )
        if !tableBlockView.frame.equalTo(tableFrame) {
            tableBlockView.frame = tableFrame
        }
        #if canImport(UIKit) && !os(macOS)
        let contentSize = CGSize(width: tableFrame.width, height: outerSize.height)
        if !scrollView.contentSize.equalTo(contentSize) {
            scrollView.contentSize = contentSize
        }
        #endif
        // Belt-and-suspenders: child views set their own
        // `setNeedsDisplay()` in `frame.didSet`, but the order in which
        // TextKit / UIKit drives these can leave the chrome stale on
        // first display. A no-op redraw here is cheap and ensures the
        // border/header background paint with the latest geometry.
        tableBlockView.platformSetNeedsDisplay()
    }

    #if canImport(AppKit) && os(macOS)
    public override func layout() {
        super.layout()
        refreshScrollGeometry()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshScrollGeometry()
    }

    public override var isFlipped: Bool { true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Re-bake the layer's CGColor under the new appearance and
        // ask the table view to re-render so chrome / cell text pick
        // up the swapped system colors.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor =
                TableBlockView.backgroundColor.cgColor
        }
        tableBlockView.refreshAppearance()
    }
    #elseif canImport(UIKit)
    public override func layoutSubviews() {
        super.layoutSubviews()
        refreshScrollGeometry()
    }

    public override var frame: CGRect {
        didSet { refreshScrollGeometry() }
    }

    public override func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(
            comparedTo: previousTraitCollection
        ) {
            tableBlockView.refreshAppearance()
            setNeedsDisplay()
        }
    }
    #endif
}

extension PlatformView {
    /// Cross-platform shim: triggers the platform-native "this view
    /// needs to redraw" call. Used by the scroll container to nudge
    /// the table when geometry settles after a structural change.
    fileprivate func platformSetNeedsDisplay() {
        #if canImport(AppKit) && os(macOS)
        self.needsDisplay = true
        #else
        self.setNeedsDisplay()
        #endif
    }
}

/// `NSTextAttachmentViewProvider` that vends a `TableScrollContainer`
/// (which itself hosts a `TableBlockView`) for a `ProseNodeAttachment`
/// whose subtree is a `table`. The provider holds a weak reference to
/// the attachment so subtree mutations (cell edits, structural
/// commands) can re-render in place.
public final class TableAttachmentViewProvider: NSTextAttachmentViewProvider {
    /// Register this provider class for every `ProseNodeAttachment`'s
    /// file type. Idempotent; safe to call multiple times. Called from
    /// `EditorController` on first instantiation so demos and tests pick
    /// up the rich grid without manual setup.
    public static func registerOnce() {
        if registered { return }
        registered = true
        NSTextAttachment.registerViewProviderClass(
            TableAttachmentViewProvider.self,
            forFileType: ProseNodeAttachment.attachmentFileType
        )
        // TK2 sizes line fragments through the TK1 attachmentBounds
        // path; route that to the same measurement the provider uses,
        // capping the reported width to the container so the line
        // fragment never exceeds the editor width — overflow is
        // exposed via the scroll container instead.
        ProseNodeAttachment.sizingProvider = { subtree, width in
            let inner = TableBlockView.intrinsicSize(
                for: subtree,
                theme: TableAttachmentViewProvider.sharedTheme,
                proposedWidth: width
            )
            return CGSize(width: min(inner.width, width), height: inner.height)
        }
    }
    private static var registered = false

    /// Theme used by every realized provider until/unless an
    /// `EditorController` registers one. Defaults to `.default` so the
    /// provider works in headless / preview contexts without setup.
    public static var sharedTheme: ProseTheme = .default

    /// Closure invoked by the table view's edit/structural transactions.
    /// `EditorController.attachHostView` swaps this in so cell edits route
    /// to the active controller.
    public static var sharedDispatch: ((Transaction) -> Void)? = nil

    /// Closure invoked when a `TableBlockView`'s reported intrinsic size
    /// changes after a cell or structural mutation. The controller hooks
    /// this to call `layoutManager.invalidateLayout(for:)` for the
    /// attachment's storage range — without that, TextKit 2 keeps the
    /// previously-reported `attachmentBounds` and the line fragment
    /// hosting the table clips taller rows.
    public static var sharedInvalidateAttachment: ((ProseNodeAttachment) -> Void)? = nil

    /// The realized `TableBlockView`, lifted from the scroll container
    /// for callers that previously read `provider.view as TableBlockView`
    /// directly. The actual `view` is the scroll container (so the
    /// attachment can scroll horizontally); routes that target the
    /// table — cell edits, focus, structural mutations — go through
    /// this view.
    public var tableBlockView: TableBlockView? {
        (view as? TableScrollContainer)?.tableBlockView
            ?? view as? TableBlockView
    }

    public override func loadView() {
        super.loadView()
        let theme = TableAttachmentViewProvider.sharedTheme
        let subtree: TreeNode
        if let attachment = textAttachment as? ProseNodeAttachment {
            subtree = attachment.subtree
        } else {
            subtree = .structural(ProseNode(type: "table"), [])
        }
        let initialWidth: CGFloat = {
            if let cw = textLayoutManager?.textContainer?.size.width,
               cw > 0, cw < CGFloat.greatestFiniteMagnitude {
                return cw
            }
            return 600
        }()
        let initialInner = TableBlockView.intrinsicSize(
            for: subtree,
            theme: theme,
            proposedWidth: initialWidth
        )
        let blockView = TableBlockView(subtree: subtree, theme: theme)
        let outerWidth = min(initialInner.width, initialWidth)
        // Inner table renders at its natural width (could exceed the
        // outer width — that's the overflow case the scroll wrapper
        // is built for). Outer container is bounded by the line
        // fragment width.
        blockView.frame = CGRect(origin: .zero, size: initialInner)
        blockView.dispatch = TableAttachmentViewProvider.sharedDispatch

        let container = TableScrollContainer(tableBlockView: blockView)
        container.frame = CGRect(
            x: 0, y: 0,
            width: outerWidth,
            height: initialInner.height
        )
        container.refreshScrollGeometry()

        if let attachment = textAttachment as? ProseNodeAttachment {
            attachment.viewProvider = self
            attachment.boundView = blockView
        }
        // Wire the block view's layout-change notification to TextKit 2
        // layout invalidation. Cell edits / structural mutations grow or
        // shrink the table; without this, the line fragment hosting the
        // attachment keeps its prior height and clips the new rows.
        // `TableScrollContainer.wireSizeChangeHook` chains this on top
        // of its own scroll-geometry refresh so both fire.
        let priorHook = blockView.layoutDidChange
        blockView.layoutDidChange = { [weak self] in
            priorHook?()
            guard let self,
                  let att = self.textAttachment as? ProseNodeAttachment else { return }
            TableAttachmentViewProvider.sharedInvalidateAttachment?(att)
        }
        // Tell TextKit 2 to track the view's bounds so layout updates
        // when the grid grows after a structural mutation (insert row,
        // wrap inside taller cell text).
        tracksTextAttachmentViewBounds = true
        view = container
    }

    public override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let theme = TableAttachmentViewProvider.sharedTheme
        let subtree: TreeNode
        if let attachment = textAttachment as? ProseNodeAttachment {
            subtree = attachment.subtree
        } else {
            subtree = .structural(ProseNode(type: "table"), [])
        }
        let proposedWidth = ProseNodeAttachment.preferredWidth(
            proposedLineFragment: proposedLineFragment,
            textContainer: textContainer
        )
        // Inner size: the natural table size — width can exceed the
        // proposed line fragment width, in which case the scroll
        // container exposes the overflow.
        let inner: CGSize
        if let blockView = tableBlockView {
            inner = blockView.intrinsicSizeUsingCache(proposedWidth: proposedWidth)
        } else {
            inner = TableBlockView.intrinsicSize(
                for: subtree,
                theme: theme,
                proposedWidth: proposedWidth
            )
        }
        // Outer size for the line fragment is capped at the proposed
        // width — the editor's text view never grows past the
        // container, the scroll container handles overflow internally.
        let outerSize = CGSize(
            width: min(inner.width, proposedWidth),
            height: inner.height
        )
        // Resize the realized views in lock-step so the on-screen
        // frames match the size we just reported to the layout manager.
        if let blockView = tableBlockView {
            blockView.frame = CGRect(origin: .zero, size: inner)
            #if canImport(AppKit) && os(macOS)
            blockView.needsLayout = true
            blockView.needsDisplay = true
            #else
            blockView.setNeedsLayout()
            blockView.setNeedsDisplay()
            #endif
        }
        if let container = view as? TableScrollContainer {
            container.frame = CGRect(origin: .zero, size: outerSize)
            container.refreshScrollGeometry()
            #if canImport(AppKit) && os(macOS)
            container.needsLayout = true
            container.needsDisplay = true
            #else
            container.setNeedsLayout()
            container.setNeedsDisplay()
            #endif
        }
        return CGRect(origin: .zero, size: outerSize)
    }
}

extension ProseNodeAttachment {
    /// Realized `TableBlockView` for this attachment. Held weakly so the
    /// view's lifetime stays driven by the layout manager. Used by
    /// `Step.replaceCellInline` / `Step.setTableSubtree` to push subtree
    /// updates into the view without forcing a layout invalidation.
    public weak var boundView: TableBlockView? {
        get { (objc_getAssociatedObject(self, &boundViewKey) as? WeakBox)?.value as? TableBlockView }
        set {
            let box = WeakBox(value: newValue)
            objc_setAssociatedObject(self, &boundViewKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private nonisolated(unsafe) var boundViewKey: UInt8 = 0

private final class WeakBox {
    weak var value: AnyObject?
    init(value: AnyObject?) { self.value = value }
}
