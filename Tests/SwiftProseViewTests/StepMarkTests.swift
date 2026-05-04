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

@Suite("Phase 4 Step variants")
struct StepMarkTests {

    private func makeEnv() throws -> StepEnvironment {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        return StepEnvironment(
            compiler: compiler,
            serializer: serializer,
            theme: .default
        )
    }

    private func makeStorage(_ markdown: String, env: StepEnvironment) -> NSTextStorage {
        let compiled = env.compiler.compile(markdown, theme: env.theme)
        let storage = NSTextStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: compiled)
        return storage
    }

    @Test
    func addMarkStrongStampsProseMarksAndBoldFont() throws {
        let env = try makeEnv()
        let storage = makeStorage("hello world\n", env: env)
        let helloRange = (storage.string as NSString).range(of: "hello")
        let step = Step.addMark(range: helloRange, mark: ProseMark(type: "strong"))
        _ = step.apply(to: storage, env: env)

        let marks = storage.markSet(at: helloRange.location)
        #expect(marks?.contains(type: "strong") == true)
        let font = storage.attribute(.font, at: helloRange.location, effectiveRange: nil) as? PlatformFont
        #expect(font?.proseTraits.contains(.bold) == true)
    }

    @Test
    func removeMarkStrongClearsBoldFont() throws {
        let env = try makeEnv()
        let storage = makeStorage("**hello** world\n", env: env)
        let helloRange = (storage.string as NSString).range(of: "hello")
        let step = Step.removeMark(range: helloRange, markType: "strong")
        _ = step.apply(to: storage, env: env)

        let marks = storage.markSet(at: helloRange.location)
        #expect(marks?.contains(type: "strong") != true)
        let font = storage.attribute(.font, at: helloRange.location, effectiveRange: nil) as? PlatformFont
        #expect(font?.proseTraits.contains(.bold) == false)
    }

    @Test
    func addMarkInverseRestoresOriginalRange() throws {
        let env = try makeEnv()
        let storage = makeStorage("hello world\n", env: env)
        let helloRange = (storage.string as NSString).range(of: "hello")
        let step = Step.addMark(range: helloRange, mark: ProseMark(type: "strong"))
        let applied = step.apply(to: storage, env: env)
        // Apply inverse — should restore the unmarked text.
        _ = applied.inverse.apply(to: storage, env: env)
        let font = storage.attribute(.font, at: helloRange.location, effectiveRange: nil) as? PlatformFont
        #expect(font?.proseTraits.contains(.bold) == false)
    }

    @Test
    func setNodeAttrsResolvesLeafByID() throws {
        let env = try makeEnv()
        let storage = makeStorage("Some heading\n", env: env)
        // Find the paragraph leaf node from storage.
        guard let leaf = storage.nodePath(at: 0)?.leaf else {
            Issue.record("no NodePath at index 0")
            return
        }
        // Build a path with the same leaf id but different attrs.
        let originalPath = storage.nodePath(at: 0)!
        let priorLength = storage.length
        let step = Step.setNodeAttrs(path: originalPath, attrs: ["custom": .string("value")])
        let applied = step.apply(to: storage, env: env)

        let updated = storage.nodePath(at: 0)
        #expect(updated?.leaf?.id == leaf.id)
        #expect(updated?.leaf?.attrs["custom"] == .string("value"))
        #expect(applied.mappedRange.length > 0)
        #expect(storage.length == priorLength)
    }

    @Test
    func addMarkLinkStampsHrefAndUnderline() throws {
        let env = try makeEnv()
        let storage = makeStorage("click here\n", env: env)
        let clickRange = (storage.string as NSString).range(of: "click")
        let mark = ProseMark(type: "link", attrs: ["href": .string("https://example.com")])
        _ = Step.addMark(range: clickRange, mark: mark).apply(to: storage, env: env)

        let marks = storage.markSet(at: clickRange.location)
        #expect(marks?.mark(of: "link")?.attrs["href"] == .string("https://example.com"))
        let inline = storage.attribute(.proseInline, at: clickRange.location, effectiveRange: nil) as? InlineTag
        #expect(inline == .link)
    }
}
