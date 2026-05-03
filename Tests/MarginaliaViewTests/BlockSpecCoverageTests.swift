import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView

@Suite struct BlockSpecCoverageTests {

    private func compiled(_ md: String) throws -> NSAttributedString {
        let compiler = try MarkdownAttributedCompiler()
        return compiler.compile(md, dialect: .commonMark, mode: .rich, theme: .default)
    }

    @Test func paragraphCoverage() throws {
        let out = try compiled("hello world\n")
        try assertSpecCoversAll(out)
    }

    @Test func headingCoverage() throws {
        let out = try compiled("# Heading\n")
        try assertSpecCoversAll(out)
        let spec = out.blockSpec(at: 0)
        #expect(spec?.kind == .heading(level: 1))
    }

    @Test func blockquoteCoverage() throws {
        let out = try compiled("> quoted text\n")
        try assertSpecCoversAll(out)
        let spec = try #require(out.blockSpec(at: 0))
        #expect(spec.blockquoteDepth == 1)
        #expect(spec.kind == .paragraph)
    }

    @Test func nestedBlockquoteCoverage() throws {
        let out = try compiled("> > nested\n")
        try assertSpecCoversAll(out)
        let spec = try #require(out.blockSpec(at: 0))
        #expect(spec.blockquoteDepth == 2)
    }

    @Test func unorderedListCoverage() throws {
        let out = try compiled("- one\n- two\n")
        try assertSpecCoversAll(out)
        let first = try #require(out.blockSpec(at: 0))
        #expect(first.kind == .unorderedListItem)
    }

    @Test func orderedListCoverage() throws {
        let out = try compiled("1. one\n2. two\n")
        try assertSpecCoversAll(out)
        let first = try #require(out.blockSpec(at: 0))
        if case .orderedListItem(let i) = first.kind {
            #expect(i == 1)
        } else {
            Issue.record("expected ordered list item, got \(first.kind)")
        }
    }

    @Test func taskListCoverage() throws {
        let out = try compiled("- [ ] todo\n- [x] done\n")
        try assertSpecCoversAll(out)
        let first = try #require(out.blockSpec(at: 0))
        #expect(first.kind == .taskListItem(checked: false))
    }

    @Test func fencedCodeCoverage() throws {
        let out = try compiled("```swift\nlet x = 1\n```\n")
        try assertSpecCoversAll(out)
        let spec = try #require(out.blockSpec(at: 0))
        #expect(spec.kind == .fencedCode(language: "swift"))
    }

    @Test func horizontalRuleCoverage() throws {
        let out = try compiled("---\n")
        try assertSpecCoversAll(out)
        let spec = try #require(out.blockSpec(at: 0))
        #expect(spec.kind == .horizontalRule)
    }

    @Test func blockquoteAroundListCoverage() throws {
        let out = try compiled("> - item\n")
        try assertSpecCoversAll(out)
        let spec = try #require(out.blockSpec(at: 0))
        #expect(spec.kind == .unorderedListItem)
        #expect(spec.blockquoteDepth == 1, "list nested in blockquote should carry depth")
    }

    @Test func everyKindCompilesWithSpecPresent() throws {
        let inputs = [
            "# Heading 1\n",
            "## Heading 2\n",
            "> quoted\n",
            "- bullet\n",
            "1. one\n",
            "- [x] done\n",
            "```\ncode\n```\n",
            "---\n",
            "plain paragraph\n"
        ]
        for md in inputs {
            let out = try compiled(md)
            for i in 0..<out.length {
                if out.blockSpec(at: i) == nil {
                    Issue.record("missing BlockSpec at \(i) in '\(md)'")
                }
            }
        }
    }

    private func assertSpecCoversAll(_ out: NSAttributedString) throws {
        guard out.length > 0 else { return }
        for i in 0..<out.length {
            if out.blockSpec(at: i) == nil {
                let ch = (out.string as NSString).character(at: i)
                Issue.record("missing BlockSpec at index \(i) (char=0x\(String(ch, radix: 16)))")
            }
        }
    }
}
