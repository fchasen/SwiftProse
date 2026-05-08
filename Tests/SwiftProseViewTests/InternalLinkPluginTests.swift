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

    @Test func detectsExternalSchemes() {
        let plugin = InternalLinkPlugin()
        #expect(plugin.isExternalScheme("http://example.com"))
        #expect(plugin.isExternalScheme("https://example.com"))
        #expect(plugin.isExternalScheme("mailto:hi@example.com"))
        #expect(plugin.isExternalScheme("file:///tmp/a.md"))
    }

    @Test func relativeAndAnchorHrefsAreNotExternal() {
        let plugin = InternalLinkPlugin()
        #expect(!plugin.isExternalScheme("#anchor"))
        #expect(!plugin.isExternalScheme("./other.md"))
        #expect(!plugin.isExternalScheme("../sibling.md"))
        #expect(!plugin.isExternalScheme("subdir/foo.md"))
        #expect(!plugin.isExternalScheme("foo bar.md"))
        // Leading `:` isn't a valid scheme.
        #expect(!plugin.isExternalScheme(":weird"))
    }

    @Test func parseRelativeSplitsPathAndFragment() {
        let plugin = InternalLinkPlugin()

        let withFrag = plugin.parseRelativeLink("./other.md#section")
        #expect(withFrag == LinkTarget(path: "./other.md", fragment: "section"))

        let pathOnly = plugin.parseRelativeLink("subdir/foo.md")
        #expect(pathOnly == LinkTarget(path: "subdir/foo.md", fragment: nil))

        let upDir = plugin.parseRelativeLink("../bar.md#a")
        #expect(upDir == LinkTarget(path: "../bar.md", fragment: "a"))
    }

    @Test func parseRelativeDecodesPercentEncoding() {
        let plugin = InternalLinkPlugin()

        let space = plugin.parseRelativeLink("./My%20File.md#A%20Section")
        #expect(space == LinkTarget(path: "./My File.md", fragment: "A Section"))
    }

    @Test func parseRelativeRejectsPureFragment() {
        // Pure-fragment hrefs are handled by the same-doc anchor path before
        // parseRelativeLink is consulted; calling it directly returns nil so
        // we don't accidentally feed a fragment to the host as a path.
        let plugin = InternalLinkPlugin()
        #expect(plugin.parseRelativeLink("#anchor") == nil)
        #expect(plugin.parseRelativeLink("") == nil)
    }
}
