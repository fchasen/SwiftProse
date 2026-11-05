import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum Locality {
    static let marker = "ZQX"

    struct Target {
        let index: Int
        let paragraph: NSRange
        let content: NSRange
        let block: MarkdownBlock
    }

    struct Edit: CustomTestStringConvertible, Sendable {
        let name: String
        let applies: @Sendable (Target) -> Bool
        let apply: @Sendable (NSMutableAttributedString, Target) -> (edited: NSRange, delta: Int)
        var testDescription: String { name }
    }

    static func targets(in storage: NSAttributedString) -> [Target] {
        let ns = storage.string as NSString
        var result: [Target] = []
        for (index, paragraph) in storage.markdownParagraphRanges().enumerated() where paragraph.length > 0 {
            var content = paragraph
            if ns.character(at: NSMaxRange(paragraph) - 1) == MarkdownParagraph.separator {
                content.length -= 1
            }
            guard content.length > 0,
                  let block = storage.markdownBlock(at: paragraph.location),
                  !block.isAtom
            else { continue }
            result.append(Target(index: index, paragraph: paragraph, content: content, block: block))
        }
        return result
    }

    static func plainAttributes(of storage: NSAttributedString, in target: Target) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.markdownBlock: target.block]
        if let style = storage.attribute(.paragraphStyle, at: target.paragraph.location, effectiveRange: nil) {
            attributes[.paragraphStyle] = style
        }
        return attributes
    }

    static func insert(_ text: String, at location: Int, in storage: NSMutableAttributedString, target: Target) -> (NSRange, Int) {
        let inserted = NSAttributedString(string: text, attributes: plainAttributes(of: storage, in: target))
        storage.insert(inserted, at: location)
        return (NSRange(location: location, length: inserted.length), inserted.length)
    }

    static let prefixMarker = Edit(name: "prefix marker", applies: { _ in true }) { storage, target in
        insert(marker + " ", at: target.content.location, in: storage, target: target)
    }

    static let suffixMarker = Edit(name: "suffix marker", applies: { _ in true }) { storage, target in
        insert(" " + marker, at: NSMaxRange(target.content), in: storage, target: target)
    }

    static let edits: [Edit] = [
        Edit(name: "new paragraph after", applies: { _ in true }) { storage, target in
            insert("\n" + marker, at: NSMaxRange(target.content), in: storage, target: target)
        },
        Edit(name: "delete content", applies: { _ in true }) { storage, target in
            storage.deleteCharacters(in: target.content)
            return (NSRange(location: target.content.location, length: 0), -target.content.length)
        },
        Edit(name: "replace middle", applies: { $0.content.length >= 3 }) { storage, target in
            let middle = NSRange(location: target.content.location + target.content.length / 2, length: 1)
            let attributes = storage.attributes(at: middle.location, effectiveRange: nil)
            storage.replaceCharacters(in: middle, with: NSAttributedString(string: marker, attributes: attributes))
            return (NSRange(location: middle.location, length: marker.utf16.count), marker.utf16.count - 1)
        },
        Edit(name: "bold content", applies: { !$0.block.isCode }) { storage, target in
            var runs: [(NSRange, MarkdownInlineIntent)] = []
            storage.enumerateAttribute(.markdownInlineIntent, in: target.content) { value, range, _ in
                runs.append((range, MarkdownInlineIntent(attributeValue: value) ?? []))
            }
            for (range, intent) in runs {
                storage.addAttribute(
                    .markdownInlineIntent,
                    value: intent.union(.stronglyEmphasized).attributeValue,
                    range: range
                )
            }
            return (target.content, 0)
        },
        Edit(name: "make heading", applies: { $0.block.leaf == .paragraph }) { storage, target in
            storage.addAttribute(.markdownBlock, value: target.block.with(leaf: .heading(level: 2)), range: target.paragraph)
            return (target.paragraph, 0)
        },
    ]

    static func edited(_ source: String, labels: Bool, targetIndex: Int, edit: Edit) -> String? {
        let storage = Corpus.load(source, labels: labels)
        guard let target = targets(in: storage).first(where: { $0.index == targetIndex }) else { return nil }
        let (range, delta) = edit.apply(storage, target)
        Normalizer().normalize(storage, editedRange: range, changeInLength: delta)
        return Corpus.write(storage)
    }

    static func linesAboveBlockStart(in storage: NSAttributedString, target: Target) -> Int {
        guard let group = target.block.codeGroup else { return 0 }
        let paragraphs = storage.markdownParagraphRanges()
        var count = 1
        var index = target.index - 1
        while index >= 0, storage.markdownBlock(at: paragraphs[index].location)?.codeGroup == group {
            count += 1
            index -= 1
        }
        return count
    }

    static func lineStart(in text: String, before index: String.Index, linesAbove: Int) -> String.Index {
        var start = text[..<index].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        for _ in 0..<linesAbove where start > text.startIndex {
            let previousEnd = text.index(before: start)
            start = text[..<previousEnd].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        }
        return start
    }

    static func stablePrefixLength(_ text: String, lineStart: String.Index) -> String.Index {
        var end = lineStart
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard "\n >".contains(text[previous]) else { break }
            end = previous
        }
        return end
    }

    static func samples() -> [(CorpusSample, Bool)] {
        CorpusFixtures.canonical.map { ($0, false) }
            + CorpusFixtures.remarkupDrafts.filter(\.isCanonical).map { ($0, true) }
    }
}

@Suite("Round-trip locality")
struct RoundTripLocalityTests {
    @Test(arguments: CorpusFixtures.canonical)
    func markerInsertionChangesOnlyTheMarkerBytes(_ sample: CorpusSample) {
        let storage = Corpus.load(sample.source)
        for target in Locality.targets(in: storage) {
            for edit in [Locality.prefixMarker, Locality.suffixMarker] {
                guard let output = Locality.edited(sample.source, labels: false, targetIndex: target.index, edit: edit) else {
                    Issue.record("paragraph \(target.index) missing")
                    continue
                }
                let inserted = edit.name == "prefix marker" ? Locality.marker + " " : " " + Locality.marker
                #expect(
                    output.components(separatedBy: Locality.marker).count == 2
                        && output.replacingOccurrences(of: inserted, with: "") == sample.source,
                    "\(edit.name) in paragraph \(target.index):\n\(output)"
                )
            }
        }
    }

    @Test(arguments: Locality.edits)
    func editInBlockLeavesEarlierBytesUnchanged(_ edit: Locality.Edit) {
        for (sample, labels) in Locality.samples() {
            let canonical = sample.source
            let storage = Corpus.load(canonical, labels: labels)
            for target in Locality.targets(in: storage) where edit.applies(target) {
                guard let located = Locality.edited(canonical, labels: labels, targetIndex: target.index, edit: Locality.prefixMarker),
                      let markerRange = located.range(of: Locality.marker),
                      let output = Locality.edited(canonical, labels: labels, targetIndex: target.index, edit: edit)
                else {
                    Issue.record("\(sample.name): paragraph \(target.index) could not be edited")
                    continue
                }
                let lineStart = Locality.lineStart(
                    in: located,
                    before: markerRange.lowerBound,
                    linesAbove: Locality.linesAboveBlockStart(in: storage, target: target)
                )
                let offset = located.distance(from: located.startIndex, to: lineStart)
                guard offset <= canonical.count else { continue }
                let canonicalLineStart = canonical.index(canonical.startIndex, offsetBy: offset)
                let stable = canonical[..<Locality.stablePrefixLength(canonical, lineStart: canonicalLineStart)]
                #expect(
                    output.hasPrefix(stable),
                    "\(sample.name): \(edit.name) in paragraph \(target.index) changed earlier bytes:\n\(output)"
                )
            }
        }
    }

    @Test func appendingTenthItemLeavesEarlierItemsUnchanged() {
        let source = (1...9).map { "\($0). item \($0)" }.joined(separator: "\n")
        let storage = Corpus.load(source)
        let last = Locality.targets(in: storage).last!
        let (range, delta) = Locality.insert("\nitem 10", at: NSMaxRange(last.content), in: storage, target: last)
        Normalizer().normalize(storage, editedRange: range, changeInLength: delta)
        #expect(Corpus.write(storage) == source + "\n10. item 10")
    }

    @Test func editAfterLabelKeepsLabelBytes() {
        let source = "{nav,  icon=file, name=Ready} Looks good.\n\nSecond paragraph."
        let storage = Corpus.load(source, labels: true)
        let second = Locality.targets(in: storage).last!
        let (range, delta) = Locality.insert(" More.", at: NSMaxRange(second.content), in: storage, target: second)
        Normalizer().normalize(storage, editedRange: range, changeInLength: delta)
        #expect(Corpus.write(storage) == source + " More.")
    }

    @Test func editAfterCanonicalizedBlockKeepsCanonicalBytes() {
        let source = "* star\n* list\n\nTail"
        let storage = Corpus.load(source)
        let tail = Locality.targets(in: storage).last!
        let (range, delta) = Locality.insert("!", at: NSMaxRange(tail.content), in: storage, target: tail)
        Normalizer().normalize(storage, editedRange: range, changeInLength: delta)
        #expect(Corpus.write(storage) == "- star\n- list\n\nTail!")
    }
}
