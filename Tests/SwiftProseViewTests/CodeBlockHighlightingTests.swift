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
    var detectionCalls: [String] = []
    var detectionResponse: String?
    let response: [HighlightSpan]
    init(response: [HighlightSpan], detectionResponse: String? = nil) {
        self.response = response
        self.detectionResponse = detectionResponse
    }
    func highlights(for source: String, language: String?) -> [HighlightSpan] {
        sourceSeen = source
        languageSeen = language
        return response
    }
    func detectLanguage(for source: String) -> String? {
        detectionCalls.append(source)
        return detectionResponse
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
        return compiler.compile(md, theme: .default)
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
    /// disturb the `proseNodePath` attribute that the editor relies on for
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

    /// Detection over a single registered grammar returns the language for
    /// markdown-shaped input that exceeds the 30% coverage threshold.
    @Test func detectLanguageReturnsRegisteredNameForMatchingInput() throws {
        let highlighter = TreeSitterCodeBlockHighlighter()
        let language = Language(language: tree_sitter_markdown())
        // Wide net so coverage on heading-heavy input is well above 30%.
        let query = """
        (atx_heading (inline) @keyword)
        (atx_heading (atx_h1_marker) @punctuation.special)
        (atx_heading (atx_h2_marker) @punctuation.special)
        (atx_heading (atx_h3_marker) @punctuation.special)
        """
        try highlighter.register(language: "markdown", language: language,
                                 queryData: query.data(using: .utf8)!)
        let body = "# Heading One\n## Heading Two\n### Heading Three\n"
        #expect(highlighter.detectLanguage(for: body) == "markdown")
    }

    /// Detection returns nil for input that no registered grammar covers
    /// well — e.g. plain prose against a markdown-headings-only query.
    @Test func detectLanguageReturnsNilForUnrecognizedInput() throws {
        let highlighter = TreeSitterCodeBlockHighlighter()
        let language = Language(language: tree_sitter_markdown())
        let query = "(atx_heading (inline) @keyword)"
        try highlighter.register(language: "markdown", language: language,
                                 queryData: query.data(using: .utf8)!)
        // No headings — coverage should be 0%.
        #expect(highlighter.detectLanguage(for: "just a regular sentence with words") == nil)
    }

    /// Very short bodies skip detection (16-char floor) — auto-coloring a
    /// two-line snippet is too noisy.
    @Test func detectLanguageReturnsNilForShortBodies() throws {
        let highlighter = TreeSitterCodeBlockHighlighter()
        let language = Language(language: tree_sitter_markdown())
        let query = "(atx_heading (inline) @keyword)"
        try highlighter.register(language: "markdown", language: language,
                                 queryData: query.data(using: .utf8)!)
        #expect(highlighter.detectLanguage(for: "# Hi") == nil)
    }

    /// When the fence has no info string, the compiler asks the highlighter
    /// to detect, then queries with the detected language.
    @Test func compilerCallsDetectionWhenLanguageMissing() throws {
        let stub = StubHighlighter(
            response: [HighlightSpan(range: NSRange(location: 0, length: 3), tag: .keyword)],
            detectionResponse: "swift"
        )
        let body = "let x = 1\nlet y = 2"
        let md = "```\n\(body)\n```\n"
        let compiler = try MarkdownAttributedCompiler(codeBlockHighlighter: stub)
        _ = compiler.compile(md, theme: .default)
        #expect(stub.detectionCalls == [body])
        #expect(stub.languageSeen == "swift")
    }

    /// When the fence has an explicit info string, detection is skipped.
    @Test func compilerSkipsDetectionWhenLanguageProvided() throws {
        let stub = StubHighlighter(response: [], detectionResponse: "swift")
        let md = "```ruby\nputs 'hi'\n```\n"
        let compiler = try MarkdownAttributedCompiler(codeBlockHighlighter: stub)
        _ = compiler.compile(md, theme: .default)
        #expect(stub.detectionCalls.isEmpty)
        #expect(stub.languageSeen == "ruby")
    }

    // MARK: - typing-time rehighlight (Bug 1)

    /// Typing into a fenced code block re-runs the highlighter so freshly
    /// typed code picks up token coloring. Before the fix the highlighter
    /// only ran at compile time, so the post-typing body was uncolored.
    /// Tests drive the headless path (no host text view) so `resegment()`
    /// — and the rehighlight pass it kicks off — runs synchronously after
    /// each typed character.
    @Test func typingInsideFencedBlockReinvokesHighlighter() throws {
        let stub = StubHighlighter(response: [])
        let controller = try EditorController(
            initialMarkdown: "```swift\n\n```\n",
            codeBlockHighlighter: stub
        )
        // Initial compile already saw an empty body. Reset the stub's view
        // so we can assert the typing-driven call distinctly.
        stub.sourceSeen = nil
        stub.languageSeen = nil
        controller.testSelection = NSRange(location: 9, length: 0) // "```swift\n" = 9
        type("let x = 1", in: controller)
        #expect(stub.languageSeen == "swift")
        #expect(stub.sourceSeen == "let x = 1")
    }

    /// The rehighlight stamps colors onto the typed body. With a stub that
    /// returns a keyword span at offset 0..3, the body's "let" must end up
    /// the palette's keyword color after typing.
    @Test func typingInsideFencedBlockColorsTokensFromHighlighter() throws {
        let stub = StubHighlighter(response: [
            HighlightSpan(range: NSRange(location: 0, length: 3), tag: .keyword)
        ])
        let theme = ProseTheme.default
        let controller = try EditorController(
            initialMarkdown: "```swift\n\n```\n",
            theme: theme,
            codeBlockHighlighter: stub
        )
        controller.testSelection = NSRange(location: 9, length: 0)
        type("let x = 1", in: controller)
        let storage = controller.textStorage
        let ns = storage.string as NSString
        let letRange = ns.range(of: "let")
        guard letRange.location != NSNotFound else {
            Issue.record("typed 'let' not found in storage")
            return
        }
        let color = storage.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? PlatformColor
        #expect(color === theme.codePalette.keyword || color == theme.codePalette.keyword)
    }

    /// Typing outside any code block must NOT call the highlighter — it's a
    /// per-edit cost we only pay when the edit lands on a code-block run.
    @Test func typingOutsideCodeBlockSkipsHighlighter() throws {
        let stub = StubHighlighter(response: [])
        let controller = try EditorController(
            initialMarkdown: "",
            codeBlockHighlighter: stub
        )
        type("hello world", in: controller)
        #expect(stub.sourceSeen == nil)
    }

    private func type(_ chars: String, in controller: EditorController) {
        for char in chars {
            insertSingleCharacter(String(char), in: controller)
        }
    }

    private func insertSingleCharacter(_ char: String, in controller: EditorController) {
        let selection = controller.testSelection ?? NSRange(location: 0, length: 0)
        let storage = controller.textStorage
        let typedLength = (char as NSString).length
        let preLength = storage.length
        storage.beginEditing()
        storage.replaceCharacters(in: selection, with: char)
        controller.testSelection = NSRange(
            location: selection.location + typedLength,
            length: 0
        )
        storage.endEditing()
        let postLength = storage.length
        if postLength != preLength + typedLength {
            let ns = storage.string as NSString
            let cursorPos = postLength > 0 && ns.character(at: postLength - 1) == 0x0A
                ? postLength - 1
                : postLength
            controller.testSelection = NSRange(location: cursorPos, length: 0)
        }
    }
}
