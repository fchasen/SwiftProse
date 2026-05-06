import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// `NSTextAttachment` carrying the structural subtree of an isolating
/// node (today: `table`). The attachment occupies a single character on
/// storage; the surrounding `proseNodePath` ends at the isolating leaf,
/// and the reverse-projection in `ProseDocument.from(storage:)` lifts
/// `subtree` back into the document tree at that position.
///
/// `update(subtree:)` swaps the carried tree in place — view providers
/// can mutate without forcing a storage reflow. The attachment notifies
/// its `viewProvider` so the realized view can re-render.
public final class ProseNodeAttachment: NSTextAttachment, ProseSubtreeAttachment {
    /// File-type identifier used to register a view-provider class for
    /// every `ProseNodeAttachment` instance via
    /// `NSTextAttachment.registerViewProviderClass(_:forFileType:)`.
    public static let attachmentFileType: String = "dev.swiftprose.node-attachment"

    public private(set) var subtree: TreeNode
    public weak var viewProvider: NSTextAttachmentViewProvider?

    // Always advertise the registered file type so TextKit 2's
    // `viewProviderClass(forFileType:)` lookup hits our registration —
    // `init(data:ofType:)` doesn't reliably store the UTI.
    public override var fileType: String? {
        get { ProseNodeAttachment.attachmentFileType }
        set {}
    }

    public init(subtree: TreeNode) {
        self.subtree = subtree
        super.init(data: nil, ofType: ProseNodeAttachment.attachmentFileType)
    }

    public required init?(coder: NSCoder) {
        self.subtree = .leaf(ProseNode(type: "table"))
        super.init(coder: coder)
    }

    public func update(subtree: TreeNode) {
        self.subtree = subtree
    }

    /// View-layer hook for accurate subtree sizing. The TK2 layout
    /// manager calls this TK1 `attachmentBounds` override when sizing
    /// the hosting line fragment — the view provider's override is not
    /// consulted there, so without this the fragment is too short and
    /// bottom rows fall outside the laid-out region.
    public static var sizingProvider: ((TreeNode, CGFloat) -> CGSize)?

    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let width = ProseNodeAttachment.preferredWidth(
            proposedLineFragment: lineFrag,
            textContainer: textContainer
        )
        if let sizing = ProseNodeAttachment.sizingProvider {
            let size = sizing(subtree, width)
            return CGRect(origin: .zero, size: size)
        }
        let height = ProseNodeAttachment.preferredHeight(
            for: subtree,
            width: width
        )
        return CGRect(origin: .zero, size: CGSize(width: width, height: height))
    }

    public static func preferredWidth(
        proposedLineFragment lineFrag: CGRect,
        textContainer: NSTextContainer?
    ) -> CGFloat {
        if lineFrag.width > 0 { return lineFrag.width }
        if let cw = textContainer?.size.width,
           cw > 0,
           cw < CGFloat.greatestFiniteMagnitude {
            return cw
        }
        return 320
    }

    public static func preferredHeight(
        for subtree: TreeNode,
        width: CGFloat
    ) -> CGFloat {
        guard case .structural(_, let rows) = subtree else { return 30 }
        let rowCount = max(1, rows.count)
        return CGFloat(rowCount) * 30 + 2
    }
}
