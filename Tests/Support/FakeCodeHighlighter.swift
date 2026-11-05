import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftProseSyntax
import SwiftProseView

package final class FakeCodeHighlighter: CodeBlockHighlighter {
    package static let identifier = PlatformColor.systemRed
    package static let comment = PlatformColor.systemGreen
    package static let resetMarker = PlatformColor.systemBlue

    package var paintsResetMarker = false
    package private(set) var sessions: [FakeCodeSession] = []

    package init() {}

    package func makeSession(language: String?, body: String) -> CodeHighlightSession? {
        let session = FakeCodeSession(language: language, paintsResetMarker: paintsResetMarker)
        sessions.append(session)
        return session
    }

    package var resetCount: Int { sessions.reduce(0) { $0 + $1.resets.count } }
    package var editCount: Int { sessions.reduce(0) { $0 + $1.edits.count } }
    package var isConsistent: Bool { sessions.allSatisfy(\.isConsistent) }

    package static func runs(in body: NSString, range: NSRange) -> [CodeHighlightRun] {
        guard body.length > 0 else { return [] }
        let lines = body.lineRange(for: Normalizer.clamp(range, to: body.length))
        var runs: [CodeHighlightRun] = []
        var index = lines.location
        var inComment = false
        while index < NSMaxRange(lines) {
            let unit = body.character(at: index)
            if unit == 0x0A {
                inComment = false
            } else if inComment {
                runs.append(CodeHighlightRun(range: NSRange(location: index, length: 1), color: comment))
            } else if unit == 0x23 {
                inComment = true
                runs.append(CodeHighlightRun(range: NSRange(location: index, length: 1), color: comment))
            } else if unit == 0x78 {
                runs.append(CodeHighlightRun(range: NSRange(location: index, length: 1), color: identifier))
            }
            index += 1
        }
        return runs
    }
}

package final class FakeCodeSession: CodeHighlightSession {
    package struct Edit: Equatable {
        package var range: NSRange
        package var replacement: String
        package var body: String

        package init(range: NSRange, replacement: String, body: String) {
            self.range = range
            self.replacement = replacement
            self.body = body
        }
    }

    package let language: String?
    package let paintsResetMarker: Bool
    package private(set) var resets: [String] = []
    package private(set) var edits: [Edit] = []
    package private(set) var invalidations: [NSRange] = []
    package private(set) var isConsistent = true
    private var body = ""

    package init(language: String?, paintsResetMarker: Bool) {
        self.language = language
        self.paintsResetMarker = paintsResetMarker
    }

    package func reset(body: String) -> [CodeHighlightRun] {
        resets.append(body)
        self.body = body
        let ns = body as NSString
        if paintsResetMarker {
            return [CodeHighlightRun(range: NSRange(location: 0, length: ns.length), color: FakeCodeHighlighter.resetMarker)]
        }
        return FakeCodeHighlighter.runs(in: ns, range: NSRange(location: 0, length: ns.length))
    }

    package func didEdit(replacedRange: NSRange, replacement: String, body: String) -> CodeHighlightEdit {
        let previous = self.body as NSString
        if NSMaxRange(replacedRange) > previous.length
            || previous.replacingCharacters(in: replacedRange, with: replacement) != body {
            isConsistent = false
        }
        edits.append(Edit(range: replacedRange, replacement: replacement, body: body))
        self.body = body
        let ns = body as NSString
        let edited = NSRange(location: replacedRange.location, length: (replacement as NSString).length)
        let invalidated = ns.length == 0 ? NSRange(location: 0, length: 0) : ns.lineRange(for: Normalizer.clamp(edited, to: ns.length))
        invalidations.append(invalidated)
        return CodeHighlightEdit(invalidatedRange: invalidated, runs: FakeCodeHighlighter.runs(in: ns, range: invalidated))
    }
}

package enum CodeHighlightProbe {
    package static func colors(_ storage: NSAttributedString, in range: NSRange) -> [PlatformColor?] {
        (range.location..<NSMaxRange(range)).map {
            storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? PlatformColor
        }
    }

    package static func expectedColors(body: NSString, base: PlatformColor) -> [PlatformColor] {
        var colors = Array(repeating: base, count: body.length)
        for run in FakeCodeHighlighter.runs(in: body, range: NSRange(location: 0, length: body.length)) {
            for index in run.range.location..<NSMaxRange(run.range) { colors[index] = run.color }
        }
        return colors
    }

    package static func mismatches(in controller: EditorController) -> [String] {
        let storage = controller.textStorage
        let ns = storage.string as NSString
        var failures: [String] = []
        for extent in CodeHighlighting.extents(in: storage) {
            let body = ns.substring(with: extent.body) as NSString
            let expected = expectedColors(body: body, base: controller.codeBaseColor)
            let actual = colors(storage, in: extent.body)
            for (offset, pair) in zip(expected, actual).enumerated() where pair.1?.isEqual(pair.0) != true {
                failures.append("\(extent.key) offset \(offset) '\(body.substring(with: NSRange(location: offset, length: 1)))'")
            }
        }
        return failures
    }
}
