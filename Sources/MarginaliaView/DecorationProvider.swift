import Foundation
import MarginaliaSyntax
import MarginaliaRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct Decoration: Equatable, Sendable {
    public let range: NSRange
    public let kind: DecorationKind
    public let zIndex: Int

    public init(range: NSRange, kind: DecorationKind, zIndex: Int = 0) {
        self.range = range
        self.kind = kind
        self.zIndex = zIndex
    }
}

public enum DecorationKind: Equatable, Sendable {
    case blockquoteBar(depth: Int, position: RunPosition)
    case codeBackground(language: String?, position: RunPosition)
    case horizontalRule
}

public enum RunPosition: Equatable, Sendable {
    case start
    case middle
    case end
    case single
}

public protocol DecorationProvider: AnyObject {
    func decorations(in range: NSRange, storage: NSAttributedString) -> [Decoration]
}

public final class BlockSpecDecorationProvider: DecorationProvider {

    public init() {}

    public func decorations(
        in range: NSRange,
        storage: NSAttributedString
    ) -> [Decoration] {
        guard storage.length > 0 else { return [] }
        let ns = storage.string as NSString
        var out: [Decoration] = []
        var cursor = range.location
        let end = max(range.location, range.location + range.length)
        while cursor < ns.length {
            let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            decorate(line: line, in: storage, into: &out)
            let next = line.location + line.length
            if next == cursor { break }
            cursor = next
            if cursor >= end && range.length > 0 { break }
        }
        return out
    }

    private func decorate(
        line: NSRange,
        in storage: NSAttributedString,
        into out: inout [Decoration]
    ) {
        // Scan the paragraph for any character carrying a spec —
        // trusting char 0 only would miss lines where the leading
        // character lost its spec mid-edit.
        guard let spec = paragraphSpec(in: storage, lineRange: line) else { return }
        if spec.blockquoteDepth > 0 {
            let position = runPosition(for: line, in: storage) { $0.blockquoteDepth > 0 }
            out.append(Decoration(range: line, kind: .blockquoteBar(depth: spec.blockquoteDepth, position: position)))
        }
        switch spec.kind {
        case .fencedCode(let language):
            let position = runPosition(for: line, in: storage) { spec in
                if case .fencedCode = spec.kind { return true } else { return false }
            }
            out.append(Decoration(range: line, kind: .codeBackground(language: language, position: position), zIndex: -1))
        case .indentedCode:
            let position = runPosition(for: line, in: storage) { spec in
                if case .indentedCode = spec.kind { return true } else { return false }
            }
            out.append(Decoration(range: line, kind: .codeBackground(language: nil, position: position), zIndex: -1))
        case .horizontalRule:
            out.append(Decoration(range: line, kind: .horizontalRule))
        default:
            break
        }
    }

    private func paragraphSpec(in storage: NSAttributedString, lineRange: NSRange) -> BlockSpec? {
        var i = lineRange.location
        let end = lineRange.location + lineRange.length
        while i < end {
            if let spec = storage.blockSpec(at: i) { return spec }
            i += 1
        }
        return nil
    }

    private func runPosition(
        for line: NSRange,
        in storage: NSAttributedString,
        match: (BlockSpec) -> Bool
    ) -> RunPosition {
        let prevMatches = lineSpec(before: line, in: storage).map(match) ?? false
        let nextMatches = lineSpec(after: line, in: storage).map(match) ?? false
        switch (prevMatches, nextMatches) {
        case (false, false): return .single
        case (false, true): return .start
        case (true, false): return .end
        case (true, true): return .middle
        }
    }

    private func lineSpec(before line: NSRange, in storage: NSAttributedString) -> BlockSpec? {
        guard line.location > 0 else { return nil }
        return storage.blockSpec(at: line.location - 1)
    }

    private func lineSpec(after line: NSRange, in storage: NSAttributedString) -> BlockSpec? {
        let end = line.location + line.length
        guard end < storage.length else { return nil }
        return storage.blockSpec(at: end)
    }
}
