import Foundation
import SwiftProseSyntax

/// Payload delivered to `onDocumentChange` / `addOnDocumentChange`
/// subscribers after a character edit.
///
/// `document` is computed on read, not on publish: projecting the whole
/// storage to a typed tree is O(document), and the common subscriber
/// (toolbar state, completion refresh) never looks at it. Subscribers that
/// do want the tree pay for it; the rest don't.
public struct DocumentChange {
    /// Forward-only description of the storage edit.
    public let step: Step

    unowned let controller: EditorController

    /// Where the edit came from. A `.load` replaced the whole document
    /// on the host's behalf; the text-view coordinators don't push that
    /// back into the binding.
    let origin: EditOrigin

    init(step: Step, controller: EditorController, origin: EditOrigin = .platform) {
        self.step = step
        self.controller = controller
        self.origin = origin
    }

    /// Tree view of the storage as of this change. Projected on first
    /// read and cached on the controller until the next edit.
    public var document: ProseDocument { controller.document }
}
