import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct ValidationRangeTests {

    @Test func transactionUnionRangeIsValidated() throws {
        // Two-step transaction whose first step injects corruption and
        // whose second step touches a different range. With the union
        // range validated, the corruption from step 1 should fire a
        // diagnostic. With only the last step's range validated, it
        // would silently survive.
        let controller = try EditorController(initialMarkdown: "alpha\nbeta\n")
        var captured: [SpecDiagnostic] = []
        controller.onDiagnostic = { captured.append($0) }

        // line 0 = "alpha\n" (chars 0..6)
        // line 1 = "beta\n" (chars 6..11)
        let line0 = NSRange(location: 0, length: 6)
        let line1 = NSRange(location: 6, length: 5)

        // Replace line 0 with raw text that has no BlockSpec; then
        // setSpec on line 1. The union [0, end-of-line1] must be the
        // validation range so the corruption on line 0 surfaces.
        let corrupted = NSAttributedString(string: "gamma\n")
        controller.apply(Transaction(steps: [
            .replaceText(range: line0, with: corrupted),
            .setSpec(lineRange: line1, BlockSpec(kind: .heading(level: 1)))
        ]))

        #expect(!captured.isEmpty,
                "expected at least one diagnostic for corruption on line 0, got \(captured)")
    }

    @Test func multiLineStorageEditRepairsAllAffectedLines() throws {
        let controller = try EditorController(initialMarkdown: "")
        // Inject a 3-line block of unspec'd text directly into storage —
        // this fires the storage observer, which must repair every line
        // covered by editedRange, not just the line at editedRange.location.
        let injected = NSAttributedString(string: "one\ntwo\nthree\n")
        controller.textStorage.beginEditing()
        controller.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: injected
        )
        controller.textStorage.endEditing()

        // Every char should now carry a BlockSpec, not just chars on line 0.
        let total = controller.textStorage.length
        var missingByLine: [Int: Int] = [:]
        var lineIndex = 0
        for i in 0..<total {
            if controller.textStorage.blockSpec(at: i) == nil {
                missingByLine[lineIndex, default: 0] += 1
            }
            if (controller.textStorage.string as NSString).character(at: i) == 0x0A {
                lineIndex += 1
            }
        }
        #expect(missingByLine.isEmpty,
                "expected every line repaired by the observer, got missing-spec counts \(missingByLine)")
    }
}
