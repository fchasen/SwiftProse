import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

let samplePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

final class ImageRecordingPlugin: EditorPlugin {
    let key = AnyPluginKey(name: "test.images")
    var consumes: Bool
    private(set) var pastes: [PasteEvent] = []

    init(consumes: Bool) {
        self.consumes = consumes
    }

    var props: PluginProps {
        PluginProps(handlePaste: { [weak self] _, event in
            guard let self else { return false }
            pastes.append(event)
            return consumes && !event.images.isEmpty
        })
    }
}

@Suite("Pasted image policy", .serialized)
struct PastedImagePolicyTests {
    private let dataImage = PastedImage(data: samplePNG, contentType: .png)

    private func images(
        hasMarkdown: Bool = false,
        forcePlain: Bool = false,
        plainText: String? = nil,
        fileURLs: [URL] = []
    ) -> [PastedImage] {
        PastedImagePolicy.images(
            hasMarkdown: hasMarkdown,
            forcePlain: forcePlain,
            plainText: plainText,
            fileURLs: fileURLs,
            dataImages: { [dataImage] }
        )
    }

    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    @Test func imageDataAloneIsAnImage() {
        #expect(images() == [dataImage])
        #expect(images(plainText: "  \n") == [dataImage])
    }

    @Test func aURLBesideImageDataStillPastesTheImage() {
        #expect(images(plainText: "https://example.com/shot.png") == [dataImage])
    }

    @Test func copiedTextWinsOverItsRenderedPicture() {
        #expect(images(plainText: "A1\tB1\nA2\tB2").isEmpty)
        #expect(images(plainText: "see https://example.com").isEmpty)
    }

    @Test func editorMarkdownAndPlainPasteNeverYieldImages() {
        #expect(images(hasMarkdown: true).isEmpty)
        #expect(images(forcePlain: true).isEmpty)
    }

    @Test func imageFilesAreReadWithTheirNames() throws {
        let url = try temporaryFile(named: "shot one.png", contents: samplePNG)
        let result = images(plainText: "shot one.png", fileURLs: [url])
        #expect(result == [PastedImage(data: samplePNG, contentType: .png, suggestedName: "shot one.png")])
    }

    @Test func nonImageFilesSuppressTheFileIcon() throws {
        let url = try temporaryFile(named: "notes.txt", contents: Data("hi".utf8))
        #expect(images(fileURLs: [url]).isEmpty)
    }

    @Test func preferredDataTypeFavorsLosslessFormats() {
        #expect(PastedImagePolicy.preferredDataType(in: ["public.tiff", "public.png"]) == .png)
        #expect(PastedImagePolicy.preferredDataType(in: ["public.tiff"]) == .tiff)
        #expect(PastedImagePolicy.preferredDataType(in: ["public.utf8-plain-text"]) == nil)
    }
}

#if canImport(AppKit) && os(macOS)
import AppKit

@Suite("Image paste (macOS, .serialized)")
@MainActor
struct ImagePasteMacTests {
    @Test func readablePasteboardTypesIncludeImages() {
        let harness = EditorHarness(markdown: "")
        let types = harness.textView.readablePasteboardTypes
        #expect(types.contains(.png))
        #expect(types.contains(.tiff))
        #expect(types.contains(.fileURL))
        #expect(harness.textView.acceptableDragTypes.contains(.png))
    }

    @Test func pastedPNGReachesPlugins() {
        let harness = EditorHarness(markdown: "ab")
        let plugin = ImageRecordingPlugin(consumes: true)
        harness.controller.register(plugin: plugin)
        harness.select(1)
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(samplePNG, forType: .png)

        var handled = false
        harness.step { handled = harness.textView.readSelection(from: pasteboard, type: .png) }

        #expect(handled)
        #expect(plugin.pastes.first?.images == [PastedImage(data: samplePNG, contentType: .png)])
        #expect(plugin.pastes.first?.selection == NSRange(location: 1, length: 0))
        #expect(harness.string == "ab")
    }

    @Test func unhandledImageOnlyPasteChangesNothing() {
        let harness = EditorHarness(markdown: "ab")
        let plugin = ImageRecordingPlugin(consumes: false)
        harness.controller.register(plugin: plugin)
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.tiff], owner: nil)
        pasteboard.setData(samplePNG, forType: .tiff)

        var handled = true
        harness.step { handled = harness.textView.readSelection(from: pasteboard, type: .tiff) }

        #expect(!handled)
        #expect(plugin.pastes.count == 1)
        #expect(harness.string == "ab")
    }

    @Test func copiedTextWithAPictureStaysText() {
        let harness = EditorHarness(markdown: "")
        let plugin = ImageRecordingPlugin(consumes: true)
        harness.controller.register(plugin: plugin)
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.string, .tiff], owner: nil)
        pasteboard.setString("cell text", forType: .string)
        pasteboard.setData(samplePNG, forType: .tiff)

        harness.step { _ = harness.textView.readSelection(from: pasteboard, type: .string) }

        #expect(plugin.pastes.first?.images.isEmpty == true)
        #expect(harness.markdown == "cell text")
    }

    @Test func editorMarkdownWinsOverImages() {
        let harness = EditorHarness(markdown: "")
        let plugin = ImageRecordingPlugin(consumes: true)
        harness.controller.register(plugin: plugin)
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([ProseNSTextView.markdownType, .tiff], owner: nil)
        pasteboard.setString("**b**", forType: ProseNSTextView.markdownType)
        pasteboard.setData(samplePNG, forType: .tiff)

        harness.step { _ = harness.textView.readSelection(from: pasteboard, type: ProseNSTextView.markdownType) }

        #expect(plugin.pastes.first?.images.isEmpty == true)
        #expect(harness.markdown == "**b**")
    }

    @Test func pastedImageFileCarriesItsName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("capture.png")
        try samplePNG.write(to: url)

        let harness = EditorHarness(markdown: "")
        let plugin = ImageRecordingPlugin(consumes: true)
        harness.controller.register(plugin: plugin)
        let pasteboard = harness.privatePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        harness.step { _ = harness.textView.readSelection(from: pasteboard, type: .fileURL) }

        #expect(plugin.pastes.first?.images.first?.suggestedName == "capture.png")
        #expect(plugin.pastes.first?.images.first?.contentType == .png)
    }

    @Test func plainPasteIgnoresImages() {
        let harness = EditorHarness(markdown: "")
        let plugin = ImageRecordingPlugin(consumes: true)
        harness.controller.register(plugin: plugin)
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(samplePNG, forType: .png)

        #expect(ProseNSTextView.pastedImages(from: pasteboard, forcePlain: true).isEmpty)
        #expect(ProseNSTextView.pastedImages(from: pasteboard, forcePlain: false).count == 1)
    }

    @Test func insertMarkdownReplacingRangeIsOneUndoStep() {
        let harness = EditorHarness(markdown: "a b")
        harness.select(3)
        harness.step {
            harness.controller.insertMarkdown(
                "![shot.png](zilla-upload:1)",
                replacing: NSRange(location: 1, length: 1),
                label: "Insert Image"
            )
        }
        #expect(harness.markdown == "a![shot.png](zilla-upload:1)b")
        let attachment = harness.storage.proseSourceAttachment(at: 1)
        #expect(attachment?.contentKind == AtomKind.image)
        harness.undo()
        #expect(harness.markdown == "a b")
    }

    @Test func imageDragsAreAcceptedAsCopies() throws {
        let harness = EditorHarness(markdown: "")
        let images = harness.privatePasteboard()
        images.declareTypes([.png], owner: nil)
        images.setData(samplePNG, forType: .png)
        #expect(harness.textView.dragOperation(for: DraggingInfoStub(pasteboard: images), type: .png) == .copy)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("drop.png")
        try samplePNG.write(to: file)
        let files = harness.privatePasteboard()
        files.clearContents()
        files.writeObjects([file as NSURL])
        #expect(ProseNSTextView.carriesImages(files))

        let text = harness.privatePasteboard()
        text.declareTypes([.string, .tiff], owner: nil)
        text.setString("cell", forType: .string)
        text.setData(samplePNG, forType: .tiff)
        #expect(!ProseNSTextView.carriesImages(text))
    }
}

private final class DraggingInfoStub: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
#endif

#if canImport(UIKit) && os(iOS)
import UIKit

@Suite("Image paste (iOS, .serialized)")
@MainActor
struct ImagePasteIOSTests {
    private func renderedPNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func pasteboard() throws -> UIPasteboard {
        try #require(UIPasteboard(name: UIPasteboard.Name("mek.test.\(UUID().uuidString)"), create: true))
    }

    @Test func pasteConfigurationAcceptsImages() throws {
        let host = IOSHostHarness(markdown: "")
        let accepted = try #require(host.textView.pasteConfiguration?.acceptableTypeIdentifiers)
        #expect(accepted.contains(UTType.png.identifier))
        #expect(accepted.contains(UTType.jpeg.identifier))
    }

    @Test func pastedImageReachesPlugins() throws {
        let host = IOSHostHarness(markdown: "ab")
        let plugin = ImageRecordingPlugin(consumes: true)
        host.controller.register(plugin: plugin)
        let board = try pasteboard()
        let png = renderedPNG()
        board.setData(png, forPasteboardType: UTType.png.identifier)
        host.textView.pasteboard = board
        host.select(1)

        #expect(host.textView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        host.textView.paste(nil)

        let event = try #require(plugin.pastes.first)
        #expect(event.images.count == 1)
        #expect(event.images.first?.contentType == .png)
        #expect(event.selection == NSRange(location: 1, length: 0))
        #expect(host.markdown == "ab")
    }

    @Test func pastedTextStaysText() throws {
        let host = IOSHostHarness(markdown: "")
        let plugin = ImageRecordingPlugin(consumes: true)
        host.controller.register(plugin: plugin)
        let board = try pasteboard()
        board.string = "*a*"
        host.textView.pasteboard = board

        host.textView.paste(nil)

        #expect(plugin.pastes.first?.images.isEmpty == true)
        #expect(host.markdown == "*a*")
    }

    @Test func droppedImageReachesPluginsAtTheDropRange() throws {
        let host = IOSHostHarness(markdown: "ab")
        let plugin = ImageRecordingPlugin(consumes: true)
        host.controller.register(plugin: plugin)
        let delegate = try #require(host.textView.pasteDelegate)
        let start = try #require(host.textView.position(from: host.textView.beginningOfDocument, offset: 1))
        let range = try #require(host.textView.textRange(from: start, to: start))
        let image = PastedImage(data: renderedPNG(), contentType: .png, suggestedName: "drop.png")
        let dropped = NSAttributedString(attachment: PastedImageAttachment(pastedImage: image))

        _ = delegate.textPasteConfigurationSupporting?(host.textView, performPasteOf: dropped, to: range)

        let event = try #require(plugin.pastes.first)
        #expect(event.images == [image])
        #expect(event.text == nil)
        #expect(event.selection == NSRange(location: 1, length: 0))
        #expect(host.markdown == "ab")
    }
}
#endif
