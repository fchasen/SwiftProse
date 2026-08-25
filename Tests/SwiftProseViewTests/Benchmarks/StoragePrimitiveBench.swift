import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTPROSE_BENCH"] != nil))
struct StoragePrimitiveBench {
    static func time(_ name: String, _ iters: Int, _ body: () -> Void) {
        for _ in 0..<3 { body() }
        let clock = ContinuousClock()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let d = clock.measure { for _ in 0..<iters { body() } }
            let us = Double(d.components.attoseconds) / 1e12 + Double(d.components.seconds) * 1e6
            best = min(best, us / Double(iters))
        }
        print(String(format: "PRIM %-46s %8.2f us", (name as NSString).utf8String!, best))
    }

    @Test func comparePrimitives() throws {
        try compare(BenchmarkFixtures.mixedDocument(), "mixed")
    }

    @Test func compareLongFencePrimitives() throws {
        try compare(BenchmarkFixtures.longFenceDocument(), "fence")
    }

    func compare(_ md: String, _ tag: String) throws {
        let controller = try EditorController(initialMarkdown: md)
        let attributed = controller.textStorage.attributedSubstring(
            from: NSRange(location: 0, length: controller.textStorage.length))

        let plain = NSTextStorage(attributedString: attributed)
        let prose = ProseTextStorage()
        prose.replaceCharacters(in: NSRange(location: 0, length: 0), with: attributed)

        for (rawLabel, st) in [("NSTextStorage", plain), ("ProseTextStorage", prose as NSTextStorage)] {
            let label = "\(tag) \(rawLabel)"
            let full = NSRange(location: 0, length: st.length)
            Self.time("\(label).string as NSString", 200) { _ = st.string as NSString }
            Self.time("\(label).string.count-probe", 200) { _ = (st.string as NSString).character(at: 10) }
            Self.time("\(label) paragraphRange", 200) {
                _ = (st.string as NSString).paragraphRange(for: NSRange(location: st.length / 2, length: 0))
            }
            Self.time("\(label) enumerateNodePaths", 20) { st.enumerateNodePaths { _, _ in } }
            Self.time("\(label) enumerateBlockSpecs", 20) { st.enumerateBlockSpecs { _, _ in } }
            Self.time("\(label) attributedSubstring(full)", 20) { _ = st.attributedSubstring(from: full) }
            Self.time("\(label) attributes(at:)", 200) { _ = st.attributes(at: st.length / 2, effectiveRange: nil) }
            Self.time("\(label) 1-char edit", 200) {
                st.beginEditing()
                st.replaceCharacters(in: NSRange(location: st.length / 2, length: 0), with: "a")
                st.endEditing()
                st.beginEditing()
                st.replaceCharacters(in: NSRange(location: st.length / 2, length: 1), with: "")
                st.endEditing()
            }
        }
    }
}
