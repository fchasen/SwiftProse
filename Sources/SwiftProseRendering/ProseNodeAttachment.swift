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

    /// Override the inherited `fileType` so TextKit 2's
    /// `viewProviderClass(forFileType:)` lookup matches our registration
    /// regardless of how `NSTextAttachment` chooses to persist (or not)
    /// the UTI passed to `init(data:ofType:)`. Setter is a no-op — we
    /// always advertise the same file type.
    public override var fileType: String? {
        get { ProseNodeAttachment.attachmentFileType }
        set { /* fixed */ }
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

    /// Legacy `NSTextAttachment` bounds path — used when the host falls
    /// back to TextKit 1 line-fragment layout for an attachment (e.g.
    /// during a paste preview, or while the view-provider's frame is
    /// being computed). Stays in sync with the view provider's
    /// computation.
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
        // Conservative default: 30pt per row + 2pt borders.
        return CGFloat(rowCount) * 30 + 2
    }
}
