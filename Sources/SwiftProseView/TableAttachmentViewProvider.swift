import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// `NSTextAttachmentViewProvider` that vends a `TableBlockView` for a
/// `ProseNodeAttachment` whose subtree is a `table`. The provider holds a
/// weak reference to the attachment so subtree mutations (cell edits,
/// structural commands) can re-render in place.
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

    public override func loadView() {
        super.loadView()
        let theme = TableAttachmentViewProvider.sharedTheme
        let subtree: TreeNode
        if let attachment = textAttachment as? ProseNodeAttachment {
            subtree = attachment.subtree
        } else {
            subtree = .structural(ProseNode(type: "table"), [])
        }
        // Use the live container width when available so the initial
        // frame matches what `attachmentBounds` will report; otherwise
        // fall back to a reasonable default so cell layout produces a
        // non-zero grid even before `setFrameSize` fires.
        let initialWidth: CGFloat = {
            if let cw = textLayoutManager?.textContainer?.size.width,
               cw > 0, cw < CGFloat.greatestFiniteMagnitude {
                return cw
            }
            return 600
        }()
        let initialSize = TableBlockView.intrinsicSize(
            for: subtree,
            theme: theme,
            proposedWidth: initialWidth
        )
        let blockView = TableBlockView(subtree: subtree, theme: theme)
        blockView.frame = CGRect(origin: .zero, size: initialSize)
        blockView.dispatch = TableAttachmentViewProvider.sharedDispatch
        if let attachment = textAttachment as? ProseNodeAttachment {
            attachment.viewProvider = self
            attachment.boundView = blockView
        }
        // Tell TextKit 2 to track the view's bounds so layout updates
        // when the grid grows after a structural mutation (insert row,
        // wrap inside taller cell text).
        tracksTextAttachmentViewBounds = true
        view = blockView
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
        let size = TableBlockView.intrinsicSize(
            for: subtree,
            theme: theme,
            proposedWidth: proposedWidth
        )
        // Resize the realized view in lock-step so the on-screen frame
        // matches the size we just reported to the layout manager.
        if let blockView = view as? TableBlockView {
            blockView.frame = CGRect(origin: .zero, size: size)
            #if canImport(AppKit) && os(macOS)
            blockView.needsLayout = true
            blockView.needsDisplay = true
            #else
            blockView.setNeedsLayout()
            blockView.setNeedsDisplay()
            #endif
        }
        return CGRect(origin: .zero, size: size)
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
