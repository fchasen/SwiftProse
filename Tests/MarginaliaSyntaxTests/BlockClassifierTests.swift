import Testing
import Foundation
import SwiftTreeSitter
@testable import MarginaliaSyntax

@Suite(.serialized) struct BlockClassifierTests {

    private func classify(_ source: String) throws -> [BlockRegion] {
        let p = try MarkdownParser(grammar: .block)
        let tree = try #require(p.parse(source))
        let root = try #require(tree.rootNode)
        return BlockClassifier.classify(rootNode: root, mapping: p.mapping)
    }

    @Test func paragraph() throws {
        let regions = try classify("hello world\n")
        #expect(regions.contains { $0.kind == .paragraph })
    }

    @Test(arguments: 1...6) func atxHeadingLevels(level: Int) throws {
        let hashes = String(repeating: "#", count: level)
        let regions = try classify("\(hashes) heading\n")
        let headings = regions.filter {
            if case .heading = $0.kind { return true } else { return false }
        }
        #expect(headings.count == 1)
        if case .heading(let l) = headings[0].kind {
            #expect(l == level, "expected level \(level), got \(l)")
        }
    }

    @Test func setextHeadings() throws {
        let r1 = try classify("title\n=====\n")
        let h1 = r1.first { if case .setextHeading = $0.kind { return true } else { return false } }
        #expect(h1 != nil)
        if case .setextHeading(let lvl)? = h1?.kind {
            #expect(lvl == 1)
        }

        let r2 = try classify("title\n-----\n")
        let h2 = r2.first { if case .setextHeading = $0.kind { return true } else { return false } }
        #expect(h2 != nil)
        if case .setextHeading(let lvl)? = h2?.kind {
            #expect(lvl == 2)
        }
    }

    @Test func fencedCodeBlockNoLanguage() throws {
        let regions = try classify("```\nlet x = 1\n```\n")
        let code = regions.first { if case .fencedCode = $0.kind { return true } else { return false } }
        #expect(code != nil)
        if case .fencedCode(let lang)? = code?.kind {
            #expect(lang == nil)
        }
    }

    @Test func fencedCodeBlockWithLanguage() throws {
        let regions = try classify("```swift\nlet x = 1\n```\n")
        let code = regions.first { if case .fencedCode = $0.kind { return true } else { return false } }
        #expect(code != nil)
        if case .fencedCode(let lang)? = code?.kind {
            #expect(lang == "swift")
        }
    }

    @Test func indentedCodeBlock() throws {
        let regions = try classify("    code\n")
        #expect(regions.contains { $0.kind == .indentedCode })
    }

    @Test func blockquoteDepth() throws {
        let r1 = try classify("> quoted\n")
        let bq1 = r1.first { if case .blockquote = $0.kind { return true } else { return false } }
        #expect(bq1 != nil)
        if case .blockquote(let d)? = bq1?.kind {
            #expect(d == 1)
        }

        let r2 = try classify("> > nested\n")
        let depths = r2.compactMap { region -> Int? in
            if case .blockquote(let d) = region.kind { return d } else { return nil }
        }
        #expect(depths.sorted() == [1, 2])
    }

    @Test func unorderedList() throws {
        let regions = try classify("- one\n- two\n")
        #expect(regions.contains { $0.kind == .unorderedList })
    }

    @Test func orderedList() throws {
        let regions = try classify("1. one\n2. two\n")
        #expect(regions.contains { $0.kind == .orderedList })
    }

    @Test func taskList() throws {
        let regions = try classify("- [ ] todo\n- [x] done\n")
        #expect(regions.contains { $0.kind == .taskList })
    }

    @Test func horizontalRule() throws {
        let regions = try classify("---\n")
        #expect(regions.contains { $0.kind == .horizontalRule })
    }

    @Test func rangesAreInUTF16Offsets() throws {
        // Headings starting after an emoji — verify the range is in UTF-16
        // (where 🚀 takes 2 code units), not bytes (where it takes 4).
        let source = "🚀\n# heading\n"
        let regions = try classify(source)
        let heading = regions.first { if case .heading = $0.kind { return true } else { return false } }
        #expect(heading != nil)
        // 🚀 = utf16 length 2, then \n = 1, so heading starts at utf16 offset 3
        #expect(heading?.range.location == 3)
    }

    @Test func mixedDocumentEnumeration() throws {
        let source = """
        # heading

        paragraph

        ```swift
        code
        ```

        - bullet

        > quote
        """
        let regions = try classify(source)
        let kinds = regions.map { $0.kind }
        #expect(kinds.contains(where: { if case .heading(level: 1) = $0 { return true } else { return false } }))
        #expect(kinds.contains(.paragraph))
        #expect(kinds.contains(where: { if case .fencedCode = $0 { return true } else { return false } }))
        #expect(kinds.contains(.unorderedList))
        #expect(kinds.contains(where: { if case .blockquote = $0 { return true } else { return false } }))
    }
}
