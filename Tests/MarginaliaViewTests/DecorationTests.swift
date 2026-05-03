import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct DecorationTests {

    private func compiled(_ md: String) throws -> NSAttributedString {
        let compiler = try MarkdownAttributedCompiler()
        return compiler.compile(md, dialect: .commonMark, mode: .rich, theme: .default)
    }

    @Test func singleBlockquoteHasSingleBar() throws {
        let storage = NSTextStorage(attributedString: try compiled("> hello\n"))
        let provider = BlockSpecDecorationProvider()
        let decorations = provider.decorations(in: NSRange(location: 0, length: storage.length), storage: storage)
        let bars = decorations.filter { if case .blockquoteBar = $0.kind { return true } else { return false } }
        #expect(bars.count == 1)
        if case .blockquoteBar(_, let position) = bars.first?.kind {
            #expect(position == .single)
        } else {
            Issue.record("expected blockquoteBar")
        }
    }

    @Test func threeBlockquoteLinesHaveStartMiddleEnd() throws {
        let storage = NSTextStorage(attributedString: try compiled("> a\n> b\n> c\n"))
        let provider = BlockSpecDecorationProvider()
        let decorations = provider.decorations(in: NSRange(location: 0, length: storage.length), storage: storage)
        let bars = decorations.compactMap { dec -> RunPosition? in
            if case .blockquoteBar(_, let pos) = dec.kind { return pos }
            return nil
        }
        #expect(bars.count == 3)
        #expect(bars == [.start, .middle, .end])
    }

    @Test func separatedBlockquotesAreEachSingles() throws {
        let storage = NSTextStorage(attributedString: try compiled("> a\n\n> b\n"))
        let provider = BlockSpecDecorationProvider()
        let decorations = provider.decorations(in: NSRange(location: 0, length: storage.length), storage: storage)
        let bars = decorations.compactMap { dec -> RunPosition? in
            if case .blockquoteBar(_, let pos) = dec.kind { return pos }
            return nil
        }
        #expect(bars.count == 2)
        #expect(bars == [.single, .single])
    }

    @Test func fencedCodeBlockHasContinuousBackground() throws {
        let storage = NSTextStorage(attributedString: try compiled("```\nlet x = 1\nlet y = 2\n```\n"))
        let provider = BlockSpecDecorationProvider()
        let decorations = provider.decorations(in: NSRange(location: 0, length: storage.length), storage: storage)
        let bgs = decorations.filter { if case .codeBackground = $0.kind { return true } else { return false } }
        #expect(bgs.count >= 1, "fenced code block should produce background decoration(s)")
    }

    @Test func decorationProviderScansParagraphForAnySpec() throws {
        // Strip the spec from char 0 and confirm the provider still
        // reports a blockquote bar from the surviving spec on later chars.
        let storage = NSTextStorage(attributedString: try compiled("> hello\n"))
        storage.removeAttribute(.marginaliaBlockSpec, range: NSRange(location: 0, length: 1))
        let provider = BlockSpecDecorationProvider()
        let decorations = provider.decorations(in: NSRange(location: 0, length: storage.length), storage: storage)
        let bars = decorations.filter { if case .blockquoteBar = $0.kind { return true } else { return false } }
        #expect(bars.count == 1,
                "provider must scan the paragraph for a spec; trusting char 0 only would miss this case")
    }

    @Test func paragraphHasNoDecorations() throws {
        let storage = NSTextStorage(attributedString: try compiled("hello world\n"))
        let provider = BlockSpecDecorationProvider()
        let decorations = provider.decorations(in: NSRange(location: 0, length: storage.length), storage: storage)
        #expect(decorations.isEmpty)
    }
}
