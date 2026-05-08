import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct InternalLinkPluginTests {

    private func storage(from markdown: String) throws -> NSAttributedString {
        let compiler = try MarkdownAttributedCompiler()
        return compiler.compile(markdown, theme: .default)
    }

    @Test func slugifyMatchesGitHubStyle() {
        let plugin = InternalLinkPlugin()
        #expect(plugin.slugify("Hello World") == "hello-world")
        #expect(plugin.slugify("API: v2 — getting started") == "api-v2-getting-started")
        #expect(plugin.slugify("  trim  ") == "trim")
        #expect(plugin.slugify("multi --- dash") == "multi-dash")
    }

    @Test func resolvesFragmentToHeadingRange() throws {
        let md = """
        # Intro

        See [the part](#the-deep-end).

        ## The Deep End

        body
        """
        let s = try storage(from: md)
        let plugin = InternalLinkPlugin()
        let range = plugin.resolveFragment("the-deep-end", in: s)
        #expect(range != nil)
        guard let range else { return }
        let text = (s.string as NSString).substring(with: range)
        #expect(text == "The Deep End")
    }

    @Test func unresolvedFragmentReturnsNil() throws {
        let md = """
        # Only Heading

        text
        """
        let s = try storage(from: md)
        let plugin = InternalLinkPlugin()
        #expect(plugin.resolveFragment("missing", in: s) == nil)
    }

    @Test func resolvesAcrossInlineMarkSplitsInsideHeading() throws {
        // The heading body splits into multiple proseMarks runs because of
        // the bold span — the resolver must expand to the whole heading,
        // not just the run the slug-walk happened to land on.
        let md = """
        # Bold **inside** heading

        ok
        """
        let s = try storage(from: md)
        let plugin = InternalLinkPlugin()
        let range = plugin.resolveFragment("bold-inside-heading", in: s)
        #expect(range != nil)
    }
}
