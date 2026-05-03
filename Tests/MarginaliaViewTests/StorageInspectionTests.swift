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

@Suite struct StorageInspectionTests {

    private func compile(_ markdown: String) throws -> NSAttributedString {
        let compiler = try MarkdownAttributedCompiler()
        return compiler.compile(markdown, dialect: .commonMark, mode: .rich, theme: .default)
    }

    /// Documents a limitation: tree-sitter's CommonMark grammar does NOT
    /// recognize "- \n" or "- " (no body content) as a list_item — it produces
    /// literal paragraph text. Operations.toggleUnorderedList works around this
    /// in `injectEmptyListIfNeeded` by constructing the marker run directly via
    /// `MarkdownAttributedCompiler.makeListItem` instead of recompiling.
    @Test func dashSpaceWithEmptyContentDoesNotParseAsList() throws {
        let attr = try compile("- \n")
        let firstChar = (attr.string as NSString).character(at: 0)
        let attachment = attr.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(firstChar == 0x2d, "tree-sitter sees literal '-' for empty list line")
        #expect(attachment == nil)
    }

    @Test func dashWithContentProducesBulletAttachment() throws {
        let attr = try compile("- one\n")
        let raw = attr.string
        let firstChar = (raw as NSString).character(at: 0)
        let attachment = attr.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(firstChar == 0xFFFC)
        #expect(attachment is BulletGlyphAttachment)
    }

    @Test func dumpListWithTrailingEmptyItem() throws {
        let attr = try compile("- one\n- \n")
        let raw = attr.string.replacingOccurrences(of: "\u{FFFC}", with: "[FFFC]")
        print("compile('- one\\n- \\n'): raw='\(raw)' length=\(attr.length)")
        for i in 0..<attr.length {
            let char = String((attr.string as NSString).character(at: i), radix: 16)
            let attach = attr.attribute(.attachment, at: i, effectiveRange: nil) != nil
            let listItem = attr.blockSpec(at: i)?.isListItem ?? false
            print("  [\(i)] char=0x\(char) attach=\(attach) listItem=\(listItem)")
        }
    }

    @Test func toggleUnorderedListOnEmptyEditorProducesAttachment() throws {
        let storage = NSTextStorage()
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        Operations.toggleUnorderedList(
            in: storage, range: NSRange(location: 0, length: 0),
            compiler: compiler, serializer: serializer,
            dialect: .commonMark, mode: .rich, theme: .default
        )
        let raw = storage.string
        print("toggle-on-empty result raw='\(raw.replacingOccurrences(of: "\u{FFFC}", with: "[FFFC]"))' length=\(raw.count)")
        for i in 0..<storage.length {
            let attrs = storage.attributes(at: i, effectiveRange: nil)
            let attachKey = attrs[.attachment].map { String(describing: type(of: $0)) } ?? "nil"
            let listMarkerKey = (attrs[.marginaliaListMarker] as? Bool).map { String($0) } ?? "nil"
            let specKey = storage.blockSpec(at: i).map { "kind=\($0.kind)" } ?? "nil"
            let charHex = String((raw as NSString).character(at: i), radix: 16)
            print("  [\(i)] char=0x\(charHex) attachment=\(attachKey) marker=\(listMarkerKey) spec=\(specKey)")
        }
        guard storage.length > 0 else {
            Issue.record("storage is empty after toggle")
            return
        }
        let firstChar = (raw as NSString).character(at: 0)
        let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(firstChar == 0xFFFC, "first char of toggled-on-empty list should be FFFC, got 0x\(String(firstChar, radix: 16))")
        #expect(attachment is BulletGlyphAttachment, "should have BulletGlyphAttachment, got \(String(describing: attachment))")
    }
}
