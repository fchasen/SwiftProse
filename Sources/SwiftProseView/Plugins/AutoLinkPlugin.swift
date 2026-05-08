import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct AutoLinkMatch {
    public let storage: NSTextStorage
    public let matchedRange: NSRange
    public let linkRange: NSRange
    public let captureRanges: [NSRange]

    public var text: String { substring(in: matchedRange) ?? "" }
    public var linkText: String { substring(in: linkRange) ?? "" }

    public func capture(_ i: Int) -> String? {
        guard captureRanges.indices.contains(i) else { return nil }
        let range = captureRanges[i]
        guard range.location != NSNotFound else { return nil }
        return substring(in: range)
    }

    private func substring(in range: NSRange) -> String? {
        let ns = storage.string as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= ns.length else {
            return nil
        }
        return ns.substring(with: range)
    }
}

public struct AutoLinkRule {
    public let id: String
    public let pattern: NSRegularExpression
    public let linkCapture: Int
    public let href: (AutoLinkMatch) -> String?
    public let title: (AutoLinkMatch) -> String?

    public init(
        id: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        linkCapture: Int = 1,
        href: @escaping (AutoLinkMatch) -> String?,
        title: @escaping (AutoLinkMatch) -> String? = { _ in nil }
    ) {
        self.id = id
        do {
            self.pattern = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("AutoLinkRule \(id) pattern \(pattern) failed to compile: \(error)")
        }
        self.linkCapture = linkCapture
        self.href = href
        self.title = title
    }
}

public final class AutoLinkPlugin: EditorPlugin {
    public let key = AnyPluginKey(name: "swiftprose.autoLink")
    public let rules: [AutoLinkRule]

    public init(rules: [AutoLinkRule]) {
        self.rules = rules
    }

    public func appendTransaction(after transactions: [Transaction], controller: EditorController) -> Transaction? {
        let ranges = autoLinkParagraphRanges(from: transactions, in: controller.textStorage)
        guard !ranges.isEmpty else { return nil }
        var steps: [Step] = []
        for range in ranges {
            appendAutoLinkSteps(in: range, controller: controller, steps: &steps)
        }
        guard !steps.isEmpty else { return nil }
        return Transaction(
            steps: steps,
            label: "Auto Link",
            selection: .cursor(at: controller.currentSelection.location)
        )
    }

    private func appendAutoLinkSteps(
        in range: NSRange,
        controller: EditorController,
        steps: inout [Step]
    ) {
        let storage = controller.textStorage
        guard range.location < storage.length,
              storage.blockSpec(at: range.location)?.isCodeBlock != true else {
            return
        }
        let ns = storage.string as NSString
        let line = ns.substring(with: range)
        let lineNS = line as NSString
        let searchRange = NSRange(location: 0, length: lineNS.length)
        for rule in rules {
            rule.pattern.enumerateMatches(in: line, options: [], range: searchRange) { result, _, _ in
                guard let result,
                      result.numberOfRanges > rule.linkCapture else {
                    return
                }
                let relativeLinkRange = result.range(at: rule.linkCapture)
                guard relativeLinkRange.location != NSNotFound,
                      relativeLinkRange.length > 0 else {
                    return
                }
                let linkRange = NSRange(
                    location: range.location + relativeLinkRange.location,
                    length: relativeLinkRange.length
                )
                guard !autoLinkRangeHasExcludedMarks(linkRange, in: storage) else { return }
                var captures: [NSRange] = []
                captures.reserveCapacity(result.numberOfRanges)
                for index in 0..<result.numberOfRanges {
                    let capture = result.range(at: index)
                    if capture.location == NSNotFound {
                        captures.append(capture)
                    } else {
                        captures.append(NSRange(
                            location: range.location + capture.location,
                            length: capture.length
                        ))
                    }
                }
                let match = AutoLinkMatch(
                    storage: storage,
                    matchedRange: NSRange(
                        location: range.location + result.range.location,
                        length: result.range.length
                    ),
                    linkRange: linkRange,
                    captureRanges: captures
                )
                guard let href = rule.href(match), !href.isEmpty else { return }
                var attrs: [String: ProseAttrValue] = ["href": .string(href)]
                if let title = rule.title(match), !title.isEmpty {
                    attrs["title"] = .string(title)
                }
                steps.append(.addMark(
                    range: linkRange,
                    mark: ProseMark(type: "link", attrs: attrs)
                ))
            }
        }
    }
}

private func autoLinkParagraphRanges(from transactions: [Transaction], in storage: NSTextStorage) -> [NSRange] {
    let ns = storage.string as NSString
    var ranges: [NSRange] = []
    for transaction in transactions {
        for step in transaction.steps {
            guard case .replaceText(let range, let attributed) = step else { continue }
            let start = max(0, min(range.location, ns.length))
            let end = max(start, min(range.location + max(range.length, attributed.length), ns.length))
            let scanRange = ns.paragraphRange(for: NSRange(location: start, length: end - start))
            if !ranges.contains(where: { NSEqualRanges($0, scanRange) }) {
                ranges.append(scanRange)
            }
        }
    }
    return ranges
}

private func autoLinkRangeHasExcludedMarks(_ range: NSRange, in storage: NSTextStorage) -> Bool {
    var excluded = false
    storage.enumerateAttribute(.proseMarks, in: range) { value, _, stop in
        guard let marks = (value as? MarkSetBox)?.marks else { return }
        if marks.contains(type: "code") || marks.contains(type: "link") {
            excluded = true
            stop.pointee = true
        }
    }
    return excluded
}
