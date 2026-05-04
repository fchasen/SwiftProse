import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
import SwiftTreeSitter
import TreeSitterMarkdown
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A `CodeBlockHighlighter` whose responses are scripted by the test. Lets us
/// assert that the compiler correctly offsets returned spans into the
/// rendered storage and applies the theme's color for each `HighlightTag`
/// without needing a real tree-sitter language grammar.
private final class StubHighlighter: CodeBlockHighlighter {
    var languageSeen: String?
    var sourceSeen: String?
    let response: [HighlightSpan]
    init(response: [HighlightSpan]) { self.response = response }
    func highlights(for source: String, language: String?) -> [HighlightSpan] {
        sourceSeen = source
        languageSeen = language
        return response
    }
}

@Suite struct CodeBlockHighlightingTests {

    private func compileFenced(
        body: String,
        language: String?,
        highlighter: CodeBlockHighlighter?
    ) throws -> NSAttributedString {
        let lang = language.map { " " + $0 } ?? ""
        let md = "```\(lang)\n\(body)\n```\n"
        let compiler = try MarkdownAttributedCompiler(codeBlockHighlighter: highlighter)
        return compiler.compile(md, mode: .rich, theme: .default)
    }

    /// The compiler asks the highlighter for body text only (not the fence
    /// or info-string lines) and forwards the language string as written in
    /// the info string.
    @Test func compilerForwardsLanguageAndBodyOnly() throws {
        let stub = StubHighlighter(response: [])
        _ = try compileFenced(body: "let x = 1\nlet y = 2", language: "swift", highlighter: stub)
        #expect(stub.languageSeen == "swift")
        #expect(stub.sourceSeen == "let x = 1\nlet y = 2")
    }

    /// A span returned by the highlighter at body-local coordinates lands on
    /// the corresponding characters in the rendered storage, picking up the
    /// palette's keyword color (purple by default).
    @Test func keywordSpanColorsBodyTokens() throws {
        // Body is "let x = 1"; the "let" prefix is at positions 0..3 in
        // body-local coordinates. The compiler must offset into storage
        // (which prefixes the body with the opening fence line "```swift\n").
        let span = HighlightSpan(range: NSRange(location: 0, length: 3), tag: .keyword)
        let stub = StubHighlighter(response: [span])
        let attributed = try compileFenced(body: "let x = 1", language: "swift", highlighter: stub)
        // Find the body's "let" inside the rendered string.
        let ns = attributed.string as NSString
        let letRange = ns.range(of: "let")
        #expect(letRange.location != NSNotFound)
        let theme = ProseTheme.default
        let color = attributed.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? PlatformColor
        #expect(color === theme.codePalette.keyword || color == theme.codePalette.keyword)
    }

    /// Without a highlighter, code-block bodies stay the theme foreground.
    @Test func absentHighlighterLeavesForegroundUntouched() throws {
        let attributed = try compileFenced(body: "let x = 1", language: "swift", highlighter: nil)
        let ns = attributed.string as NSString
        let letRange = ns.range(of: "let")
        let theme = ProseTheme.default
        let color = attributed.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? PlatformColor
        #expect(color == theme.foregroundColor)
    }

    /// The block spec round-trip is preserved — adding highlights doesn't
    /// disturb the `proseBlockSpec` attribute that the editor relies on for
    /// per-line decoration and serialization.
    @Test func highlightingPreservesBlockSpec() throws {
        let span = HighlightSpan(range: NSRange(location: 0, length: 3), tag: .keyword)
        let stub = StubHighlighter(response: [span])
        let attributed = try compileFenced(body: "let x = 1", language: "swift", highlighter: stub)
        let ns = attributed.string as NSString
        let letRange = ns.range(of: "let")
        guard letRange.location != NSNotFound else {
            Issue.record("body 'let' not found")
            return
        }
        let spec = attributed.blockSpec(at: letRange.location)
        if case .fencedCode(let lang) = spec?.kind {
            #expect(lang == "swift")
        } else {
            Issue.record("expected fenced code spec at body, got \(String(describing: spec?.kind))")
        }
    }

    /// Spans whose offsets lie outside the body window are dropped rather
    /// than crashing the compiler.
    @Test func outOfBoundsSpansAreIgnored() throws {
        let bogus = HighlightSpan(range: NSRange(location: 999, length: 5), tag: .keyword)
        let stub = StubHighlighter(response: [bogus])
        // Should not crash and should leave the body color intact.
        let attributed = try compileFenced(body: "let x = 1", language: "swift", highlighter: stub)
        let ns = attributed.string as NSString
        let letRange = ns.range(of: "let")
        let theme = ProseTheme.default
        let color = attributed.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? PlatformColor
        #expect(color == theme.foregroundColor)
    }

    /// A real `TreeSitterCodeBlockHighlighter` registered with the bundled
    /// markdown block grammar produces spans for the fenced body — proving
    /// the registry + parser + query path end-to-end.
    @Test func treeSitterHighlighterRegistryRunsAndProducesSpans() throws {
        let highlighter = TreeSitterCodeBlockHighlighter()
        // We borrow the markdown block grammar (already linked in this
        // package) and a tiny query that captures the entire ATX heading
        // text with the `keyword` tag — this is just a stand-in to prove
        // the parser/query pipeline works without pulling a new SwiftPM dep.
        let language = Language(language: tree_sitter_markdown())
        let queryData = "(atx_heading (inline) @keyword)".data(using: .utf8)!
        try highlighter.register(language: "demo", language: language, queryData: queryData)
        // Body containing an ATX-style heading-looking line.
        let spans = highlighter.highlights(for: "# Hello\n", language: "demo")
        #expect(!spans.isEmpty)
        #expect(spans.contains { $0.tag == .keyword })
    }
}
