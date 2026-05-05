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
        let blockView = TableBlockView(subtree: subtree, theme: theme)
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
        let proposedWidth = proposedLineFragment.width > 0
            ? proposedLineFragment.width
            : (textContainer?.size.width ?? TableBlockView.minTableWidth)
        let size = TableBlockView.intrinsicSize(
            for: subtree,
            theme: theme,
            proposedWidth: proposedWidth
        )
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
