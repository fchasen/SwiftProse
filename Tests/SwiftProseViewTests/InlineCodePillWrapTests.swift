import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct InlineCodeFontTests {

    /// Inline code in a heading inherits the heading's bold weight + size,
    /// just delivered through the monospaced system font.
    @Test func headingCodeSpanFontIsHeadingSizedMono() throws {
        let theme = ProseTheme.default
        let controller = try EditorController(initialMarkdown: "# Title `code` end\n", theme: theme)
        let storage = controller.textStorage
        let codeRange = (storage.string as NSString).range(of: "code")
        try #require(codeRange.location != NSNotFound)
        let font = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? PlatformFont
        let mono = try #require(font)
        #expect(mono.isMonospace, "Heading code span should be monospaced; got \(mono.fontName)")
        let headingScale = theme.headingScale[1] ?? 1.0
        let expectedSize = theme.bodyFont.pointSize * headingScale
        #expect(abs(mono.pointSize - expectedSize) < 0.01,
                "Mono should match heading point size \(expectedSize); got \(mono.pointSize)")
        #expect(mono.proseTraits.contains(.bold), "Heading code span should be bold; got \(mono.proseTraits)")
    }

    /// Body-paragraph inline code stays at body size (mono regular).
    @Test func paragraphCodeSpanFontIsBodySizedMono() throws {
        let theme = ProseTheme.default
        let controller = try EditorController(initialMarkdown: "hello `world` foo\n", theme: theme)
        let storage = controller.textStorage
        let codeRange = (storage.string as NSString).range(of: "world")
        try #require(codeRange.location != NSNotFound)
        let font = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? PlatformFont
        let mono = try #require(font)
        #expect(mono.isMonospace)
        #expect(abs(mono.pointSize - theme.bodyFont.pointSize) < 0.01)
        #expect(!mono.proseTraits.contains(.bold))
    }
}
