import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
@Suite(.serialized) struct ResegmentCoalescingTests {

    @Test func scheduleResegmentCoalescesMultipleCallsWithinOneRunloopTick() async throws {
        let controller = try EditorController(initialMarkdown: "alpha\nbeta\ngamma\n")
        let baseline = controller.resegmentRunCount

        // Three rapid scheduleResegment calls in one tick — the
        // single-flight flag should collapse them into one deferred
        // dispatch.
        controller.scheduleResegment()
        controller.scheduleResegment()
        controller.scheduleResegment()

        // Nothing has run yet; we haven't yielded.
        #expect(controller.resegmentRunCount == baseline,
                "deferred resegment must not run synchronously")

        // Yield long enough for the dispatched block to fire.
        try await Task.sleep(nanoseconds: 30_000_000)

        let delta = controller.resegmentRunCount - baseline
        #expect(delta == 1,
                "expected exactly one coalesced resegment; got \(delta)")
    }

    @Test func scheduleResegmentCanRunAgainAfterDispatchCompletes() async throws {
        let controller = try EditorController(initialMarkdown: "x\n")
        let baseline = controller.resegmentRunCount

        controller.scheduleResegment()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.resegmentRunCount == baseline + 1)

        // After the first dispatch completes, the flag is reset and a new
        // schedule should produce a fresh deferred resegment.
        controller.scheduleResegment()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.resegmentRunCount == baseline + 2)
    }

    @Test func hostedKeystrokeBlocksUpdateAfterRunloopYield() async throws {
        // End-to-end: when a host text view is attached, a storage edit
        // does not synchronously update `controller.blocks`, but `blocks`
        // does eventually reflect the new content after the runloop tick
        // drains.
        let controller = try EditorController(initialMarkdown: "first\n")
        controller.hostTextView = NSObject()
        let blocksBefore = controller.blocks.count

        controller.textStorage.beginEditing()
        controller.textStorage.replaceCharacters(
            in: NSRange(location: controller.textStorage.length, length: 0),
            with: NSAttributedString(string: "second\n")
        )
        controller.textStorage.endEditing()

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(controller.blocks.count > blocksBefore,
                "blocks should grow after deferred resegment runs")
    }
}
