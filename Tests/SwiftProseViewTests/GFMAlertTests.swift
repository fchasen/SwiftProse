import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView

@Suite(.serialized) struct GFMAlertTests {

    private static let sample = """
        > [!IMPORTANT]
        > The preset queries use the `@me` sentinel (`BugQuery.me`). BMO's REST API does **not** expand `@me` the way the web UI does — you must call `substitutingMe(with:)` with the real login email before sending the query. Calling `whoami()` once at startup is the recommended pattern.

        """

    private func compile(_ markdown: String) throws -> NSAttributedString {
        let compiler = try MarkdownAttributedCompiler()
        return compiler.compile(markdown, theme: .default)
    }

    @Test func alertHeaderLineCarriesBlockquoteDepth() throws {
        let storage = try compile(Self.sample)
        let header = (storage.string as NSString).range(of: "IMPORTANT")
        try #require(header.location != NSNotFound)
        let spec = storage.blockSpec(at: header.location)
        #expect((spec?.blockquoteDepth ?? 0) > 0,
                "header line of GFM alert should be inside a blockquote")
    }

    @Test func alertBodyLineCarriesBlockquoteDepth() throws {
        let storage = try compile(Self.sample)
        let body = (storage.string as NSString).range(of: "preset queries")
        try #require(body.location != NSNotFound)
        let spec = storage.blockSpec(at: body.location)
        #expect((spec?.blockquoteDepth ?? 0) > 0,
                "body line of GFM alert should be inside a blockquote")
    }

    @Test func everyContentCharacterCarriesBlockquoteDepth() throws {
        let storage = try compile(Self.sample)
        let ns = storage.string as NSString
        var missing: [(Int, Character)] = []
        for i in 0..<storage.length {
            let scalar = ns.character(at: i)
            if scalar == 0x000A { continue }
            let depth = storage.blockSpec(at: i)?.blockquoteDepth ?? 0
            if depth == 0 {
                let ch = Character(UnicodeScalar(scalar)!)
                missing.append((i, ch))
            }
        }
        #expect(missing.isEmpty,
                "every non-newline character in the alert should carry blockquoteDepth>0; offenders: \(missing)")
    }

    @Test func inlineCodeSpansAreTaggedAsCodeSpan() throws {
        let storage = try compile(Self.sample)
        let probes = ["@me", "BugQuery.me", "substitutingMe(with:)", "whoami()"]
        for probe in probes {
            let r = (storage.string as NSString).range(of: probe)
            try #require(r.location != NSNotFound, "expected to find \(probe) in compiled output")
            let mid = r.location + r.length / 2
            let tag = storage.attribute(.proseInline, at: mid, effectiveRange: nil) as? InlineTag
            #expect(tag == .codeSpan,
                    "\(probe) should carry InlineTag.codeSpan but had \(String(describing: tag))")
        }
    }

    @Test func boldRunInsideAlertCarriesStrongMark() throws {
        let storage = try compile(Self.sample)
        let r = (storage.string as NSString).range(of: "not")
        try #require(r.location != NSNotFound)
        let marks = storage.markSet(at: r.location)
        #expect(marks?.contains(type: "strong") == true,
                "**not** inside the alert should carry the strong mark")
    }

    @Test func codeSpanRunUsesMonospaceFont() throws {
        let storage = try compile(Self.sample)
        let r = (storage.string as NSString).range(of: "substitutingMe(with:)")
        try #require(r.location != NSNotFound)
        let mid = r.location + r.length / 2
        let font = storage.attribute(.font, at: mid, effectiveRange: nil) as? PlatformFont
        try #require(font != nil, "code span should have an explicit font")
        #expect(font!.isProseMonospace,
                "substitutingMe(with:) should render in monospace, got \(font!.fontName)")
    }

    @Test func plainCodeSpanOutsideBlockquoteIsMonospace() throws {
        let storage = try compile("call `whoami()` please\n")
        let r = (storage.string as NSString).range(of: "whoami()")
        try #require(r.location != NSNotFound)
        let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? PlatformFont
        #expect(font?.isProseMonospace == true,
                "plain code span (no blockquote) should be monospace, got \(String(describing: font?.fontName))")
    }

    @Test func codeSpanInsidePlainBlockquoteIsMonospace() throws {
        let storage = try compile("> call `whoami()` please\n")
        let r = (storage.string as NSString).range(of: "whoami()")
        try #require(r.location != NSNotFound)
        let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? PlatformFont
        #expect(font?.isProseMonospace == true,
                "code span inside a plain blockquote should be monospace, got \(String(describing: font?.fontName))")
    }

    @Test func codeSpanRunIsMonospaceOverEntireRange() throws {
        let storage = try compile(Self.sample)
        let probes = ["@me", "BugQuery.me", "substitutingMe(with:)", "whoami()"]
        var report: [String: (mono: Int, total: Int)] = [:]
        for probe in probes {
            let r = (storage.string as NSString).range(of: probe)
            try #require(r.location != NSNotFound)
            var mono = 0
            for i in 0..<r.length {
                let font = storage.attribute(.font, at: r.location + i, effectiveRange: nil) as? PlatformFont
                if font?.isProseMonospace == true { mono += 1 }
            }
            report[probe] = (mono, r.length)
        }
        for (probe, counts) in report {
            #expect(counts.mono == counts.total,
                    "\(probe): expected all \(counts.total) chars in monospace, only \(counts.mono) are")
        }
    }

    @Test func codeSpanRunCoversFullTextRange() throws {
        let storage = try compile(Self.sample)
        let probes = ["@me", "BugQuery.me", "substitutingMe(with:)", "whoami()"]
        for probe in probes {
            let r = (storage.string as NSString).range(of: probe)
            try #require(r.location != NSNotFound)
            var tagged = 0
            for i in 0..<r.length {
                let tag = storage.attribute(.proseInline, at: r.location + i, effectiveRange: nil) as? InlineTag
                if tag == .codeSpan { tagged += 1 }
            }
            #expect(tagged == r.length,
                    "\(probe) (\(r.length) chars) should carry .codeSpan on every char, got \(tagged)")
        }
    }

    @Test func decorationProviderProducesBlockquoteBarsForBothLines() throws {
        let storage = try compile(Self.sample)
        let provider = BlockSpecDecorationProvider()
        let decorations = provider.decorations(
            in: NSRange(location: 0, length: storage.length),
            storage: storage
        )

        let ns = storage.string as NSString
        let headerLine = ns.paragraphRange(for: ns.range(of: "IMPORTANT"))
        let bodyLine = ns.paragraphRange(for: ns.range(of: "preset queries"))

        let headerHasBar = decorations.contains { deco in
            guard case .blockquoteBar = deco.kind else { return false }
            return NSEqualRanges(deco.range, headerLine)
        }
        let bodyHasBar = decorations.contains { deco in
            guard case .blockquoteBar = deco.kind else { return false }
            return NSEqualRanges(deco.range, bodyLine)
        }
        #expect(headerHasBar, "header line should produce a .blockquoteBar decoration")
        #expect(bodyHasBar, "body line should produce a .blockquoteBar decoration")
    }
}

private extension PlatformFont {
    var isProseMonospace: Bool {
        // `monospacedSystemFont` doesn't always set the descriptor's
        // `.monoSpace` symbolic trait, so check the font name as a
        // fallback — `.AppleSystemUIFontMonospaced` is the system mono
        // alias on macOS / iOS.
        if fontName.localizedCaseInsensitiveContains("monospace") { return true }
        if fontName.localizedCaseInsensitiveContains("mono") { return true }
        #if canImport(AppKit) && os(macOS)
        return fontDescriptor.symbolicTraits.contains(.monoSpace)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #endif
    }
}
