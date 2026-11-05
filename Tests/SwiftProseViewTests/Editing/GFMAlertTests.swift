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

@Suite(.serialized)
@MainActor
struct GFMAlertTests {
    private static let sample = """
        > [!IMPORTANT]
        > The preset queries use the `@me` sentinel (`BugQuery.me`). BMO's REST API does **not** expand `@me` the way the web UI does — you must call `substitutingMe(with:)` with the real login email before sending the query. Calling `whoami()` once at startup is the recommended pattern.

        """

    private static let codeProbes = ["@me", "BugQuery.me", "substitutingMe(with:)", "whoami()"]

    private func load(_ markdown: String) -> EditorController {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return EditorController(markdown: markdown, undoManager: undoManager)
    }

    private func range(of needle: String, in storage: NSAttributedString) throws -> NSRange {
        let range = (storage.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound, "expected to find \(needle)")
        return range
    }

    private func font(_ storage: NSAttributedString, at index: Int) -> PlatformFont? {
        storage.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont
    }

    @Test func alertHeaderLineCarriesBlockquoteDepth() throws {
        let storage = load(Self.sample).textStorage
        let header = try range(of: "IMPORTANT", in: storage)
        #expect(storage.markdownBlock(at: header.location)?.quoteTokens.count == 1)
    }

    @Test func alertBodyLineCarriesBlockquoteDepth() throws {
        let storage = load(Self.sample).textStorage
        let header = try range(of: "IMPORTANT", in: storage)
        let body = try range(of: "preset queries", in: storage)
        let tokens = storage.markdownBlock(at: body.location)?.quoteTokens
        #expect(tokens?.count == 1)
        #expect(tokens == storage.markdownBlock(at: header.location)?.quoteTokens)
    }

    @Test func everyContentCharacterCarriesBlockquoteDepth() {
        let storage = load(Self.sample).textStorage
        let ns = storage.string as NSString
        var missing: [Int] = []
        for index in 0..<storage.length where ns.character(at: index) != MarkdownParagraph.separator {
            if storage.markdownBlock(at: index)?.isInQuote != true { missing.append(index) }
        }
        #expect(missing.isEmpty, "offenders: \(missing)")
    }

    @Test func inlineCodeSpansAreTaggedAsCodeSpan() throws {
        let storage = load(Self.sample).textStorage
        for probe in Self.codeProbes {
            let r = try range(of: probe, in: storage)
            #expect(storage.markdownInlineIntent(at: r.location + r.length / 2).contains(.code), "\(probe)")
        }
    }

    @Test func boldRunInsideAlertCarriesStrongMark() throws {
        let storage = load(Self.sample).textStorage
        let r = try range(of: "not", in: storage)
        #expect(storage.markdownInlineIntent(at: r.location).contains(.stronglyEmphasized))
    }

    @Test func codeSpanRunUsesMonospaceFont() throws {
        let storage = load(Self.sample).textStorage
        let r = try range(of: "substitutingMe(with:)", in: storage)
        let font = try #require(font(storage, at: r.location + r.length / 2))
        #expect(font.isMonospace, "got \(font.fontName)")
    }

    @Test func codeSpanInsidePlainBlockquoteIsMonospace() throws {
        let storage = load("> call `whoami()` please\n").textStorage
        let r = try range(of: "whoami()", in: storage)
        #expect(font(storage, at: r.location)?.isMonospace == true)
        #expect(storage.markdownBlock(at: r.location)?.isInQuote == true)
    }

    @Test func codeSpanRunIsMonospaceOverEntireRange() throws {
        let storage = load(Self.sample).textStorage
        for probe in Self.codeProbes {
            let r = try range(of: probe, in: storage)
            let mono = (0..<r.length).filter { font(storage, at: r.location + $0)?.isMonospace == true }.count
            #expect(mono == r.length, "\(probe): \(mono) of \(r.length) monospace")
        }
    }

    @Test func codeSpanRunCoversFullTextRange() throws {
        let storage = load(Self.sample).textStorage
        for probe in Self.codeProbes {
            let r = try range(of: probe, in: storage)
            let tagged = (0..<r.length).filter { storage.markdownInlineIntent(at: r.location + $0).contains(.code) }.count
            #expect(tagged == r.length, "\(probe): \(tagged) of \(r.length) tagged")
        }
    }

    @Test func decorationProviderProducesBlockquoteBarsForBothLines() throws {
        let controller = load(Self.sample)
        let storage = controller.textStorage
        for needle in ["IMPORTANT", "preset queries"] {
            let r = try range(of: needle, in: storage)
            let decorations = FragmentDecorations.make(paragraphAt: r.location, controller: controller)
            #expect(decorations.quoteBars.count == 1, "\(needle)")
        }
    }
}
