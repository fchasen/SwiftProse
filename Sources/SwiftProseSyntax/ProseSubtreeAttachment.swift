import Foundation

/// Layer-clean probe protocol for an `NSTextAttachment` that carries a
/// `TreeNode` subtree. The reverse-projection in
/// `ProseDocument.from(storage:)` discovers it via the `NSAttachment`
/// string-key probe (avoiding an AppKit/UIKit import here in
/// `SwiftProseSyntax`) and lifts the attachment's `subtree` into the
/// document tree at the run's position when the leaf is `isolating`.
///
/// `ProseNodeAttachment` (in `SwiftProseRendering`) conforms.
public protocol ProseSubtreeAttachment: AnyObject {
    var subtree: TreeNode { get }
}
