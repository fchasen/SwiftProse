import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport

@Suite("Top-level units")
struct TopLevelUnitTests {
    static let samples: [CorpusSample] = CorpusFixtures.bugzilla + CorpusFixtures.phabricator
        + CorpusFixtures.remarkupDrafts + CorpusFixtures.canonicalizing + edgeSamples

    static let edgeSamples: [CorpusSample] = [
        CorpusSample("empty", ""),
        CorpusSample("blank lines only", "\n\n\n"),
        CorpusSample("leading and trailing blanks", "\n\n\npara\n\n\n"),
        CorpusSample("bullet chain", "- a\n\n* b\n\n- c\n\n* d"),
        CorpusSample("ordered chain", "1. a\n\n1) b\n\n3. c"),
        CorpusSample("indented code after list", "- a\n\n      code\n\npara\n\n    code"),
        CorpusSample("quotes with blanks", "> a\n>\n> b\n\n> c\n\npara"),
        CorpusSample("empty items", "- \n- a\n- \n\npara\n\n- "),
        CorpusSample("table", "| a | b |\n|---|:-:|\n| 1 | 2 |\n\npara"),
        CorpusSample("fences", "```swift\nlet a = 1\n```\n\n~~~\n```\n~~~"),
    ]

    static func join(_ scan: TopLevelScan, after context: TopLevelContext = .start) -> String {
        var context = context
        var pieces: [String] = []
        for unit in scan.units {
            let written = MarkdownWriter.writeTopLevel(unit.block, after: context)
            context = written.context
            if let text = written.text { pieces.append(text) }
        }
        return pieces.joined(separator: "\n\n")
    }

    @Test(arguments: samples)
    func joinedUnitsEqualTheWriter(_ sample: CorpusSample) {
        for labels in [false, true] {
            let storage = Corpus.load(sample.source, labels: labels)
            let scan = StorageReader().units(in: storage, from: 0, previous: nil)
            #expect(scan.units.reduce(0) { $0 + $1.length } == (scan.units.isEmpty ? 0 : storage.length))
            #expect(scan.end == storage.length)
            #expect(!scan.stopped)
            #expect(Self.join(scan) == MarkdownWriter().markdown(from: storage))
            let full = NSRange(location: 0, length: storage.length)
            #expect(StorageReader().document(from: storage) == StorageReader().document(from: storage, range: full))
        }
    }

    @Test(arguments: samples)
    func readingFromAnyBoundaryMatchesTheFullRead(_ sample: CorpusSample) {
        let storage = Corpus.load(sample.source)
        let units = StorageReader().units(in: storage, from: 0, previous: nil).units
        var start = 0
        for index in units.indices {
            defer { start += units[index].length }
            guard index > 0 else { continue }
            let tail = StorageReader().units(in: storage, from: start, previous: units[index - 1].list)
            #expect(tail.units == Array(units[index...]))
        }
    }

    @Test(arguments: samples)
    func stoppingAtABoundaryEndsTheScanBeforeIt(_ sample: CorpusSample) {
        let storage = Corpus.load(sample.source)
        let units = StorageReader().units(in: storage, from: 0, previous: nil).units
        guard units.count >= 3 else { return }
        let stop = units[0].length + units[1].length
        let scan = StorageReader().units(in: storage, from: 0, previous: nil) { $0 == stop }
        #expect(scan.stopped)
        #expect(scan.end == stop)
        #expect(scan.units == Array(units[0..<2]))
    }

    @Test func listSeparationFollowsThePreviousUnit() {
        let storage = Corpus.load("- a\n\n* b\n\n- c")
        let units = StorageReader().units(in: storage, from: 0, previous: nil).units
        #expect(units.count == 3)
        let flags = units.map { unit -> Bool in
            guard case .list(let list) = unit.block else { return false }
            return list.separatesFromPrevious
        }
        #expect(flags == [false, true, true])
        var context = TopLevelContext.start
        var texts: [String?] = []
        for unit in units {
            let written = MarkdownWriter.writeTopLevel(unit.block, after: context)
            texts.append(written.text)
            context = written.context
        }
        #expect(texts == ["- a", "* b", "- c"])
        #expect(context == .list(isOrdered: false, alternate: false))
    }

    @Test func emptyParagraphUnitsAreTransparent() {
        let empty = EditorDocument.Block.paragraph([])
        let context = TopLevelContext.list(isOrdered: true, alternate: true)
        let written = MarkdownWriter.writeTopLevel(empty, after: context)
        #expect(written.text == nil)
        #expect(written.context == context)
    }
}
