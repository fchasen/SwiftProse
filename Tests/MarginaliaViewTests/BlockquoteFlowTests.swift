import Testing
import Foundation
import MarginaliaSyntax
import MarginaliaRendering
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct BlockquoteFlowTests {

    private func dump(_ controller: EditorController, label: String) {
        let storage = controller.textStorage
        let raw = storage.string.replacingOccurrences(of: "\u{FFFC}", with: "[FFFC]")
        print("\(label): raw='\(raw)' length=\(storage.length) markdown='\(controller.markdown())'")
        for i in 0..<storage.length {
            let attrs = storage.attributes(at: i, effectiveRange: nil)
            let charHex = String((storage.string as NSString).character(at: i), radix: 16)
            let specKey = storage.blockSpec(at: i).map { "kind=\($0.kind) qd=\($0.blockquoteDepth)" } ?? "nil"
            let psFirst = (attrs[.paragraphStyle] as? NSParagraphStyle).map { "firstLineHeadIndent=\($0.firstLineHeadIndent)" } ?? "nil"
            print("  [\(i)] char=0x\(charHex) spec=\(specKey) style=\(psFirst)")
        }
    }

    @Test func clickBlockquoteOnEmptyEditorRendersWithDepth() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.blockquote)
        dump(controller, label: "after click-blockquote")
        let storage = controller.textStorage
        #expect(storage.length > 0)
        let spec = storage.blockSpec(at: 0)
        #expect(spec?.blockquoteDepth ?? 0 > 0, "first character should carry blockquote depth")
    }

    @Test func typingIntoBlockquotePreservesDepth() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.blockquote)
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.insert(text: "fred")
        dump(controller, label: "after typing 'fred'")
        let storage = controller.textStorage
        for i in 0..<storage.length {
            let depth = storage.blockSpec(at: i)?.blockquoteDepth ?? 0
            #expect(depth > 0, "char at \(i) should have blockquote depth, got \(depth)")
        }
        #expect(controller.markdown() == "> fred\n")
    }
}
