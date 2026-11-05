import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite
@MainActor
struct InlineMarkInListTests {
    @Test func boldInLevelZeroBulletRoundTrips() {
        let controller = EditorController(markdown: "- **bold** rest\n")
        #expect(controller.serialize() == "- **bold** rest")
    }

    @Test func dumpListWithBold() {
        let controller = EditorController(markdown: "- **bold** rest\n")
        let storage = controller.textStorage
        let ns = storage.string as NSString
        let bold = ns.range(of: "bold")
        let rest = ns.range(of: "rest")
        #expect(storage.string == "bold rest")
        #expect(storage.markdownBlock(at: 0)?.listDepth == 1)
        for index in bold.location..<NSMaxRange(bold) {
            #expect(storage.markdownInlineIntent(at: index) == .stronglyEmphasized, "\(index)")
        }
        for index in rest.location..<NSMaxRange(rest) {
            #expect(storage.markdownInlineIntent(at: index).isEmpty, "\(index)")
        }
    }
}
