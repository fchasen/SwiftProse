import Foundation

/// Undo / redo configuration. Mirrors PM's `history` plugin options.
///
/// - `depth` caps the number of undoable transactions; nil leaves the
///   default `levelsOfUndo` (0 = unlimited) untouched.
/// - `newGroupDelay` (seconds) — gap before subsequent edits start a new
///   undo group. The host's `UndoManager` coalesces edits within a group
///   so a single undo reverts a burst of typing.
public struct HistoryConfig: Sendable, Equatable {
    public var depth: Int?
    public var newGroupDelay: TimeInterval

    public init(depth: Int? = nil, newGroupDelay: TimeInterval = 0.5) {
        self.depth = depth
        self.newGroupDelay = newGroupDelay
    }

    public static let `default` = HistoryConfig()
}
