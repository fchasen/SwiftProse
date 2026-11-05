import SwiftProseSyntax
import SwiftProseRendering
import Foundation

public struct DocumentChange: Sendable {
    public enum Origin: Sendable, Equatable {
        case user
        case command
        case undo
        case load
    }

    public let editedRange: NSRange
    public let changeInLength: Int
    public let origin: Origin

    public init(editedRange: NSRange, changeInLength: Int, origin: Origin) {
        self.editedRange = editedRange
        self.changeInLength = changeInLength
        self.origin = origin
    }
}

extension NSRange {
    func shifted(byEdit edited: NSRange, changeInLength delta: Int) -> NSRange {
        let replacedEnd = max(edited.location, NSMaxRange(edited) - delta)
        func map(_ position: Int, inside: Int) -> Int {
            if position <= edited.location { return position }
            if position >= replacedEnd { return position + delta }
            return inside
        }
        let start = map(location, inside: edited.location)
        let end = map(NSMaxRange(self), inside: NSMaxRange(edited))
        return NSRange(location: start, length: max(0, end - start))
    }

    func merged(withEdit edited: NSRange, changeInLength delta: Int) -> NSRange {
        NSUnionRange(shifted(byEdit: edited, changeInLength: delta), edited)
    }
}
