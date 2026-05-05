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
}
