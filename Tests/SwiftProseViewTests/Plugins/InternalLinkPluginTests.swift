import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite(.serialized)
@MainActor
struct InternalLinkPluginTests {
    private func storage(from markdown: String) -> NSAttributedString {
        MarkdownLoader().load(markdown)
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
        let s = storage(from: md)
        let plugin = InternalLinkPlugin()
        let range = try #require(plugin.resolveFragment("the-deep-end", in: s))
        #expect((s.string as NSString).substring(with: range) == "The Deep End")
    }

    @Test func unresolvedFragmentReturnsNil() {
        let md = """
        # Only Heading

        text
        """
        let s = storage(from: md)
        #expect(InternalLinkPlugin().resolveFragment("missing", in: s) == nil)
    }

    @Test func resolvesAcrossInlineMarkSplitsInsideHeading() throws {
        let md = """
        # Bold **inside** heading

        ok
        """
        let s = storage(from: md)
        let range = try #require(InternalLinkPlugin().resolveFragment("bold-inside-heading", in: s))
        #expect((s.string as NSString).substring(with: range) == "Bold inside heading")
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
        #expect(!plugin.isExternalScheme(":weird"))
    }

    @Test func parseRelativeSplitsPathAndFragment() {
        let plugin = InternalLinkPlugin()
        #expect(plugin.parseRelativeLink("./other.md#section") == LinkTarget(path: "./other.md", fragment: "section"))
        #expect(plugin.parseRelativeLink("subdir/foo.md") == LinkTarget(path: "subdir/foo.md", fragment: nil))
        #expect(plugin.parseRelativeLink("../bar.md#a") == LinkTarget(path: "../bar.md", fragment: "a"))
    }

    @Test func parseRelativeDecodesPercentEncoding() {
        let plugin = InternalLinkPlugin()
        #expect(plugin.parseRelativeLink("./My%20File.md#A%20Section") == LinkTarget(path: "./My File.md", fragment: "A Section"))
    }

    @Test func parseRelativeRejectsPureFragment() {
        let plugin = InternalLinkPlugin()
        #expect(plugin.parseRelativeLink("#anchor") == nil)
        #expect(plugin.parseRelativeLink("") == nil)
    }
}
