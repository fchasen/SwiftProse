import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct InlineMarkInListTests {

    private func compiler() throws -> MarkdownAttributedCompiler {
        try MarkdownAttributedCompiler()
    }

    @Test func boldInLevelZeroBulletRoundTrips() throws {
        let compiler = try compiler()
        let serializer = AttributedMarkdownSerializer()
        let storage = NSTextStorage(attributedString: compiler.compile(
            "- **bold** rest\n",
            dialect: .commonMark, mode: .rich, theme: .default
        ))
        let md = serializer.serialize(storage, dialect: .commonMark)
        #expect(md == "- **bold** rest\n", "got '\(md)'")
    }

    @Test func boldInParagraphRoundTrips() throws {
        let compiler = try compiler()
        let serializer = AttributedMarkdownSerializer()
        let storage = NSTextStorage(attributedString: compiler.compile(
            "**bold** rest\n",
            dialect: .commonMark, mode: .rich, theme: .default
        ))
        let md = serializer.serialize(storage, dialect: .commonMark)
        #expect(md == "**bold** rest\n", "got '\(md)'")
    }

    @Test func dumpListWithBold() throws {
        let compiler = try compiler()
        let storage = compiler.compile(
            "- **bold** rest\n",
            dialect: .commonMark, mode: .rich, theme: .default
        )
        print("storage='\(storage.string)' length=\(storage.length)")
        for i in 0..<storage.length {
            let attrs = storage.attributes(at: i, effectiveRange: nil)
            let charHex = String((storage.string as NSString).character(at: i), radix: 16)
            #if canImport(AppKit) && os(macOS)
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits
            let isBold = traits?.contains(.bold) == true
            #else
            let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits
            let isBold = traits?.contains(.traitBold) == true
            #endif
            let marker = (attrs[.marginaliaListMarker] as? Bool) == true
            print("  [\(i)] char=0x\(charHex) bold=\(isBold) marker=\(marker)")
        }
    }
}
