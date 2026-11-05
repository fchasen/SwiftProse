import CoreGraphics
import Foundation
import Testing
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
private struct Rendered {
    let controller: EditorController

    init(_ markdown: String, width: CGFloat = 480) {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        controller = EditorController(markdown: markdown, undoManager: undoManager)
        controller.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    }

    var paragraphStarts: [Int] {
        controller.textStorage.markdownParagraphRanges().filter { $0.length > 0 }.map(\.location)
    }

    func fragments() -> [Int: NSTextLayoutFragment] {
        let storage = controller.textContentStorage
        var result: [Int: NSTextLayoutFragment] = [:]
        controller.textLayoutManager.enumerateTextLayoutFragments(
            from: storage.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let start = fragment.textElement?.elementRange?.location {
                result[storage.offset(from: storage.documentRange.location, to: start)] = fragment
            }
            return true
        }
        return result
    }

    func fragment(paragraph index: Int) -> NSTextLayoutFragment? {
        fragments()[paragraphStarts[index]]
    }

    func marker(paragraph index: Int) -> ListMarker.Kind? {
        (fragment(paragraph: index) as? MarkdownLayoutFragment)?.marker?.kind
    }

    func contentX(paragraph index: Int) -> CGFloat? {
        guard let fragment = fragment(paragraph: index) as? MarkdownLayoutFragment else {
            return fragment(paragraph: index)?.layoutFragmentFrame.minX
        }
        return fragment.layoutFragmentFrame.minX + fragment.contentStartX
    }
}

private func inkPixels(of fragment: MarkdownLayoutFragment, in band: CGRect) -> Int {
    let frame = fragment.layoutFragmentFrame
    let width = Int(ceil(frame.maxX + 20))
    let height = Int(ceil(frame.height + 4))
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    fragment.draw(at: CGPoint(x: frame.minX, y: 0), in: context)
    guard let data = context.data else { return 0 }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var count = 0
    let minX = max(0, Int(band.minX)), maxX = min(width, Int(band.maxX))
    for row in 0..<height {
        for column in minX..<maxX where pixels[(row * width + column) * 4 + 3] > 40 {
            count += 1
        }
    }
    return count
}

@MainActor
@Suite("Rendering")
struct RenderingTests {
    @Test func listElementsCarryNoNativeTextLists() {
        let editor = Rendered("- one\n- two")
        let storage = editor.controller.textContentStorage
        var elements: [NSTextParagraph] = []
        storage.enumerateTextElements(from: storage.documentRange.location) { element in
            if let paragraph = element as? NSTextParagraph { elements.append(paragraph) }
            return true
        }
        #expect(elements.count == 2)
        for element in elements {
            let style = element.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.textLists.isEmpty == true)
            #expect(!element.attributedString.string.contains("\t"))
        }
        #expect(StorageReader.textLists(in: editor.controller.textStorage, at: 0).count == 1)
    }

    @Test func bulletItemsGetBulletMarkers() {
        let editor = Rendered("- one\n  - nested\n- two")
        #expect(editor.marker(paragraph: 0) == .bullet("•"))
        #expect(editor.marker(paragraph: 1) == .bullet("◦"))
        #expect(editor.marker(paragraph: 2) == .bullet("•"))
    }

    @Test func orderedItemsNumberAcrossContinuationsAndSublists() {
        let editor = Rendered("7. seven\n\n   more seven\n   - nested\n8. eight\n9. nine")
        #expect(editor.marker(paragraph: 0) == .ordinal(7))
        #expect(editor.marker(paragraph: 1) == nil)
        #expect(editor.marker(paragraph: 2) == .bullet("◦"))
        #expect(editor.marker(paragraph: 3) == .ordinal(8))
        #expect(editor.marker(paragraph: 4) == .ordinal(9))
    }

    @Test(arguments: [
        ("> 3. a\n\n> 7. b", [ListMarker.Kind.ordinal(3), .ordinal(7)]),
        ("> 1. a\n\n1. b", [.ordinal(1), .ordinal(1)]),
        ("1. a\n\n> 1. b", [.ordinal(1), .ordinal(1)]),
        ("- x\n  1. a\n\n> 5. b", [.bullet("•"), .ordinal(1, .lowerAlpha), .ordinal(5)]),
        ("> 1. a\n> 2. b", [.ordinal(1), .ordinal(2)]),
    ])
    func orderedNumberingRestartsAtQuoteBoundaries(markdown: String, expected: [ListMarker.Kind]) {
        let editor = Rendered(markdown)
        #expect(editor.paragraphStarts.indices.compactMap { editor.marker(paragraph: $0) } == expected)
    }

    @Test func nestedOrderedMarkersCycleByDepth() {
        let editor = Rendered("1. a\n   1. b\n      1. c\n         1. d\n      2. e\n   2. f\n2. g")
        #expect(editor.paragraphStarts.indices.map { editor.marker(paragraph: $0) } == [
            .ordinal(1, .decimal), .ordinal(1, .lowerAlpha), .ordinal(1, .lowerRoman), .ordinal(1, .decimal),
            .ordinal(2, .lowerRoman), .ordinal(2, .lowerAlpha), .ordinal(2, .decimal)
        ])
        let texts = editor.paragraphStarts.indices.map { index in
            (editor.fragment(paragraph: index) as? MarkdownLayoutFragment)?.marker?.text
        }
        #expect(texts == ["1.", "a.", "i.", "1.", "ii.", "b.", "2."])
        #expect(editor.controller.markdown() == "1. a\n   1. b\n      1. c\n         1. d\n      2. e\n   2. f\n2. g")

        let mixed = Rendered("- x\n  1. a\n  2. b")
        #expect(mixed.paragraphStarts.indices.map { mixed.marker(paragraph: $0) } == [.bullet("•"), .ordinal(1, .lowerAlpha), .ordinal(2, .lowerAlpha)])
    }

    @Test func orderedMarkerStyleForDepth() {
        #expect([1, 2, 3, 4, 5, 6].map(OrderedMarkerStyle.init(depth:)) == [.decimal, .lowerAlpha, .lowerRoman, .decimal, .lowerAlpha, .lowerRoman])
        #expect(OrderedMarkerStyle(depth: 0) == .decimal)
    }

    @Test(arguments: [
        (OrderedMarkerStyle.decimal, 1, "1."), (.decimal, 42, "42."), (.decimal, 0, "0."),
        (.lowerAlpha, 1, "a."), (.lowerAlpha, 2, "b."), (.lowerAlpha, 26, "z."),
        (.lowerAlpha, 27, "aa."), (.lowerAlpha, 28, "ab."), (.lowerAlpha, 52, "az."), (.lowerAlpha, 53, "ba."),
        (.lowerAlpha, 0, "a."),
        (.lowerRoman, 1, "i."), (.lowerRoman, 2, "ii."), (.lowerRoman, 3, "iii."), (.lowerRoman, 4, "iv."),
        (.lowerRoman, 9, "ix."), (.lowerRoman, 40, "xl."), (.lowerRoman, 90, "xc."), (.lowerRoman, 1994, "mcmxciv."),
        (.lowerRoman, 0, "i."), (.lowerRoman, 5000, "mmmcmxcix.")
    ])
    func orderedMarkerText(style: OrderedMarkerStyle, number: Int, expected: String) {
        #expect(style.marker(for: number) == expected)
        #expect(ListMarker.Kind.ordinal(number, style) != .ordinal(number, style == .decimal ? .lowerAlpha : .decimal))
    }

    @Test func orderedListsWithDistinctDelimitersNumberSeparately() {
        let editor = Rendered("1. a\n2. b\n1) c\n2) d")
        #expect(editor.marker(paragraph: 1) == .ordinal(2))
        #expect(editor.marker(paragraph: 2) == .ordinal(1))
        #expect(editor.marker(paragraph: 3) == .ordinal(2))
    }

    @Test func continuationAlignsWithItemContent() throws {
        let editor = Rendered("1. first\n\n   continued\n2. second")
        let item = try #require(editor.contentX(paragraph: 0))
        let continuation = try #require(editor.contentX(paragraph: 1))
        let second = try #require(editor.contentX(paragraph: 2))
        #expect(abs(item - continuation) < 0.5)
        #expect(abs(item - second) < 0.5)
        #expect(item >= Restyler.listIndent)
    }

    @Test func listInsideQuoteIsIndentedPastTheQuote() throws {
        let editor = Rendered("- plain\n\n> - quoted")
        let plain = try #require(editor.contentX(paragraph: 0))
        let quoted = try #require(editor.contentX(paragraph: 1))
        #expect(abs((quoted - plain) - Restyler.quoteIndent) < 0.5)
        let fragment = try #require(editor.fragment(paragraph: 1) as? MarkdownLayoutFragment)
        #expect(fragment.quoteBars.count == 1)
        #expect(fragment.marker?.kind == .bullet("•"))
    }

    @Test func taskItemsDrawCheckboxes() throws {
        let editor = Rendered("- [ ] open\n- [x] done\n- plain")
        #expect(editor.marker(paragraph: 0) == .task(.unchecked))
        #expect(editor.marker(paragraph: 1) == .task(.checked))
        #expect(editor.marker(paragraph: 2) == .bullet("•"))
        let fragment = try #require(editor.fragment(paragraph: 1) as? MarkdownLayoutFragment)
        let box = try #require(fragment.markerRect)
        let contentX = fragment.contentStartX
        #expect(box.maxX <= contentX)
        #expect(box.minX >= contentX - MarkdownTaskGutter.width)
    }

    @Test func rightToLeftParagraphsResolveTheirWritingDirection() {
        let editor = Rendered("1. שלום עולם\n2. second\n3. 42 שלום\n4. abc שלום\n\n```\nשלום\n```")
        let storage = editor.controller.textStorage
        let directions = editor.paragraphStarts.map {
            (storage.attribute(.paragraphStyle, at: $0, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection
        }
        #expect(directions == [.rightToLeft, .natural, .rightToLeft, .natural, .natural])
    }

    @Test func rightToLeftMarkersSitOnTheRightOfTheText() throws {
        let editor = Rendered("1. שלום עולם זה טקסט\n- [ ] שלום עולם\n- שלום \n\n> - שלום")
        for index in 0..<4 {
            let fragment = try #require(editor.fragment(paragraph: index) as? MarkdownLayoutFragment)
            let line = try #require(fragment.textLineFragments.first)
            let box = try #require(fragment.markerRect)
            #expect(box.minX >= line.typographicBounds.maxX, "paragraph \(index)")
            #expect(box.maxX <= line.typographicBounds.maxX + Restyler.listIndent, "paragraph \(index)")
            #expect(fragment.layoutFragmentFrame.minX + box.maxX <= 480, "paragraph \(index)")
        }
    }

    @Test func rightToLeftQuoteBarsSitOnTheRightOfTheText() throws {
        let editor = Rendered("> שלום עולם")
        let fragment = try #require(editor.fragment(paragraph: 0) as? MarkdownLayoutFragment)
        let line = try #require(fragment.textLineFragments.first)
        let bars = fragment.quoteBarRects(fragment.decorations)
        #expect(bars.count == 1)
        #expect(bars.allSatisfy { $0.minX >= line.typographicBounds.maxX })
        #expect(bars.allSatisfy { fragment.layoutFragmentFrame.minX + $0.maxX <= 480 })
    }

    @Test func togglingTaskRefreshesItsMarker() {
        let editor = Rendered("- [ ] open")
        #expect(editor.marker(paragraph: 0) == .task(.unchecked))
        #expect(editor.controller.toggleCheckbox(at: 0))
        #expect(editor.marker(paragraph: 0) == .task(.checked))
    }

    @Test func insertingAnItemRenumbersLaterItems() {
        let editor = Rendered("1. a\n2. b\n3. c")
        #expect(editor.marker(paragraph: 2) == .ordinal(3))
        _ = editor.fragments()
        let storage = editor.controller.textStorage
        let attributes = storage.attributes(at: 0, effectiveRange: nil)
        #expect(editor.controller.replace(
            NSRange(location: 1, length: 0),
            with: NSAttributedString(string: "\nnew", attributes: attributes),
            actionName: "Insert",
            selection: nil
        ))
        #expect(storage.string == "a\nnew\nb\nc")
        let numbers = editor.paragraphStarts.indices.compactMap { editor.marker(paragraph: $0) }
        #expect(numbers == [.ordinal(1), .ordinal(2), .ordinal(3), .ordinal(4)])
    }

    @Test func markersFollowCommandsThatChangeListStructure() {
        let editor = Rendered("1. a\n2. b\n3. c\n4. d")
        _ = editor.fragments()
        let markers = { editor.paragraphStarts.indices.map { editor.marker(paragraph: $0) } }
        editor.controller.setSelection(NSRange(location: 2, length: 0))
        editor.controller.perform(.blockquote)
        #expect(editor.controller.markdown() == "1. a\n\n> 1. b\n\n1. c\n2. d")
        #expect(markers() == [.ordinal(1), .ordinal(1), .ordinal(1), .ordinal(2)])
        editor.controller.undoManager.undo()
        #expect(markers() == [.ordinal(1), .ordinal(2), .ordinal(3), .ordinal(4)])
        editor.controller.setSelection(NSRange(location: 0, length: 0))
        editor.controller.perform(.orderedList)
        #expect(markers() == [nil, .ordinal(1), .ordinal(2), .ordinal(3)])
    }

    @Test func numberingALongListIsLinear() {
        let markdown = (1...2000).map { "\($0). item \($0)" }.joined(separator: "\n")
        let editor = Rendered(markdown)
        let clock = ContinuousClock()
        var fragments: [MarkdownLayoutFragment] = []
        let layout = clock.measure {
            editor.controller.textLayoutManager.ensureLayout(for: editor.controller.textContentStorage.documentRange)
            fragments = editor.fragments().values.compactMap { $0 as? MarkdownLayoutFragment }
        }
        #expect(fragments.count == 2000)
        #expect(layout < .milliseconds(600), "layout took \(layout)")
        let starts = editor.paragraphStarts
        var last: ListMarker.Kind?
        let access = clock.measure {
            for _ in 0..<5 {
                for start in starts { last = FragmentDecorations.make(paragraphAt: start, controller: editor.controller).marker?.kind }
            }
        }
        #expect(last == .ordinal(2000))
        #expect(access < .milliseconds(300), "decorations took \(access)")
    }

    @Test func markersAndBarsDrawInk() throws {
        let editor = Rendered("- [x] done\n- bullet\n\n> quote")
        let task = try #require(editor.fragment(paragraph: 0) as? MarkdownLayoutFragment)
        let bullet = try #require(editor.fragment(paragraph: 1) as? MarkdownLayoutFragment)
        let quote = try #require(editor.fragment(paragraph: 2) as? MarkdownLayoutFragment)
        #expect(inkPixels(of: task, in: CGRect(x: 0, y: 0, width: Restyler.listIndent, height: 100)) > 40)
        #expect(inkPixels(of: bullet, in: CGRect(x: 0, y: 0, width: Restyler.listIndent, height: 100)) > 4)
        #expect(inkPixels(of: quote, in: CGRect(x: 0, y: 0, width: 6, height: 100)) > 10)
    }

    @Test func themeChangeRefreshesDecorations() throws {
        let editor = Rendered("> - [ ] quoted")
        _ = editor.fragments()
        var theme = ProseTheme.default
        theme.blockquote.barColor = .systemRed
        editor.controller.theme = theme
        let fragment = try #require(editor.fragment(paragraph: 0) as? MarkdownLayoutFragment)
        #expect(fragment.barColor == .systemRed)
    }

    @Test func continuationDrawsNoMarkerInk() throws {
        let editor = Rendered("- item\n\n  continued")
        let continuation = try #require(editor.fragment(paragraph: 1))
        #expect((continuation as? MarkdownLayoutFragment)?.marker == nil)
    }

    @Test func codeInsideListItemKeepsMarkerAndIndent() throws {
        let editor = Rendered("- ```\n  code\n  ```")
        let fragment = try #require(editor.fragment(paragraph: 0) as? FencedCodeBlockLayoutFragment)
        #expect(fragment.marker?.kind == .bullet("•"))
        let bands = CodeBandPath.leadingOffset(forGroupStartingAt: 0, in: editor.controller.textStorage)
        #expect(bands == Restyler.listIndent)
    }
}
