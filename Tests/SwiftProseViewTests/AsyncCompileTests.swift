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
@Suite(.serialized) struct AsyncCompileTests {

    @Test func setMarkdownAsyncOnlyAppliesWhenHostAttached() async throws {
        // No host attached → sync path. Result is observable immediately.
        let headless = try EditorController(initialMarkdown: "")
        headless.setMarkdown("# Sync\n")
        #expect(headless.markdown().contains("Sync"))

        // Host attached → async path. Result not observable immediately;
        // appears after the bg compile + main marshal complete.
        let hosted = try EditorController(initialMarkdown: "")
        hosted.hostTextView = NSObject()
        hosted.setMarkdown("# Async\n")
        // Storage may still be empty here — it depends on how fast the
        // bg queue gets to it. Either way, we shouldn't assert otherwise;
        // just yield and verify the eventual state.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(hosted.markdown().contains("Async"),
                "expected async setMarkdown to apply after runloop drain; got \(hosted.markdown())")
    }

    @Test func rapidAsyncSetMarkdownLandsOnLatestValue() async throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.hostTextView = NSObject()

        // Three rapid setMarkdown calls. Generation counter should make
        // the FINAL value win even if earlier compiles complete out of
        // order — the latest call has the highest generation, and any
        // result with a stale generation drops on the floor.
        controller.setMarkdown("first\n")
        controller.setMarkdown("second\n")
        controller.setMarkdown("third\n")

        try await Task.sleep(nanoseconds: 200_000_000)

        let final = controller.markdown()
        #expect(final.contains("third"),
                "latest-wins should land on \"third\"; got \(final)")
        #expect(!final.contains("first"))
        #expect(!final.contains("second"))
    }

    @Test func explicitAsyncFalseSkipsBackgroundCompile() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.hostTextView = NSObject()

        // async: false forces synchronous compile + replace, even with a
        // host attached. Caller can read markdown() immediately.
        controller.setMarkdown("# Immediate\n", async: false)
        #expect(controller.markdown().contains("Immediate"))
    }

    @Test func recompileFromThemeChangeStillWorks() throws {
        // recompile() calls setMarkdown(currentMd) — since the existing
        // theme/mode setter triggers it via `didSet`, ensure the headless
        // path still produces the expected result.
        let controller = try EditorController(initialMarkdown: "**bold**\n")
        let before = controller.markdown()
        controller.recompile()
        #expect(controller.markdown() == before)
    }
}
