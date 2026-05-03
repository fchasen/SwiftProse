import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct BackspaceDemotionTests {

    @Test func backspaceAtStartOfBulletDemotesToParagraph() throws {
        let controller = try EditorController(initialMarkdown: "- apple\n")
        var bodyStart = -1
        controller.textStorage.enumerateAttribute(.marginaliaListMarker, in: NSRange(location: 0, length: controller.textStorage.length)) { value, range, stop in
            if (value as? Bool) == true {
                bodyStart = range.location + range.length
                stop.pointee = true
            }
        }
        #expect(bodyStart > 0, "test setup: marker run not found")
        controller.testSelection = NSRange(location: bodyStart, length: 0)
        #expect(controller.handleBackspace())
        #expect(controller.markdown() == "apple\n")
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.isListItem == false || spec == nil)
    }

    @Test func backspaceMidContentDoesNotDemote() throws {
        let controller = try EditorController(initialMarkdown: "- apple\n")
        controller.testSelection = NSRange(location: controller.textStorage.length - 2, length: 0)
        #expect(controller.handleBackspace() == false)
        #expect(controller.markdown() == "- apple\n")
    }

    @Test func backspaceOnNonListReturnsFalse() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        #expect(controller.handleBackspace() == false)
    }
}
