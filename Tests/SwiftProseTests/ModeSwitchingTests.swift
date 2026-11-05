import Foundation
import SwiftUI
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseView
@testable import SwiftProse
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

@Suite("Mode switching", .serialized)
@MainActor
struct ModeSwitchingTests {
    private func makeHosting(_ markdown: String, mode: EditorMode = .rich) -> EditorHosting {
        let hosting = EditorHosting()
        hosting.trackedActions = SwiftProseEditor.Configuration.defaultToolbar.editorActions
        hosting.ensureController(
            markdown: markdown,
            theme: .default,
            inlineContentRules: [],
            inlineContentProvider: nil,
            allowsCheckboxToggle: false,
            mode: mode
        )
        return hosting
    }

    @Test func richToSourceToRichKeepsTheOriginalBytes() throws {
        let original = "* item\n\nSetext\n======\n\n1) one\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n"
        let hosting = makeHosting(original)
        let rich = try #require(hosting.controller)
        let source = try #require(hosting.sourceController)
        hosting.setMode(.source)
        #expect(source.text == original)
        #expect(hosting.handle?.mode == .source)
        hosting.setMode(.rich)
        #expect(rich.markdown() == original)
        hosting.setMode(.source)
        #expect(source.text == original)
    }

    @Test func sourceEditsCarryIntoRichMode() throws {
        let hosting = makeHosting("hello")
        hosting.setMode(.source)
        let source = try #require(hosting.sourceController)
        source.insertMarkdown(" **world**", replacing: NSRange(location: 5, length: 0))
        hosting.setMode(.rich)
        #expect(hosting.controller?.markdown() == "hello **world**")
        #expect(hosting.controller?.textStorage.string == "hello world")
    }

    @Test func sourceModeToolbarStateComesFromTheFormatter() throws {
        let hosting = makeHosting("**bold** text")
        hosting.setMode(.source)
        hosting.sourceController?.setSelection(NSRange(location: 3, length: 1))
        hosting.refreshToolbarState()
        #expect(hosting.isActive(.bold))
        #expect(!hosting.canPerform(.deleteTableRow))
        let resolved = SwiftProseEditor.Configuration.defaultToolbar.resolvingEditorActions(
            isAvailable: { hosting.canPerform($0) },
            perform: { _ in }
        )
        var tableEntries: [String] = []
        for item in resolved {
            if case let .menu(id, _, _, _, entries) = item, id == SwiftProseEditor.tableMenuID {
                tableEntries = entries.map(\.id)
            }
        }
        #expect(tableEntries == [EditorAction.insertTable(rows: 2, columns: 3).stableID])
        hosting.perform(.italic)
        #expect(hosting.sourceController?.text == "**b*o*ld** text")
    }

    @Test func themeAndHighlighterReachBothControllers() throws {
        let hosting = makeHosting("```\nx\n```")
        let highlighter = FakeCodeHighlighter()
        hosting.apply(codeBlockHighlighter: highlighter)
        hosting.apply(theme: .default(fontScale: 1.5))
        #expect(hosting.sourceController?.codeBlockHighlighter === highlighter)
        #expect(hosting.controller?.codeBlockHighlighter === highlighter)
        #expect(hosting.sourceController?.theme == .default(fontScale: 1.5))
    }

    private func endEvent() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    @Test func undoReachesEditsMadeBeforeEachSwitch() throws {
        let hosting = makeHosting("one")
        let rich = try #require(hosting.controller)
        let source = try #require(hosting.sourceController)
        rich.insertMarkdown(" two", replacing: NSRange(location: 3, length: 0))
        endEvent()
        #expect(rich.markdown() == "one two")
        hosting.setMode(.source)
        endEvent()
        source.insertMarkdown(" **three**", replacing: NSRange(location: 7, length: 0))
        endEvent()
        hosting.setMode(.rich)
        endEvent()
        #expect(rich.markdown() == "one two **three**")
        #expect(rich.undoManager.undoActionName == EditorHandle.sourceEditsActionName)
        rich.undoManager.undo()
        #expect(rich.markdown() == "one two")
        rich.undoManager.undo()
        #expect(rich.markdown() == "one")
        rich.undoManager.redo()
        rich.undoManager.redo()
        #expect(rich.markdown() == "one two **three**")
        rich.insertMarkdown("!", replacing: NSRange(location: rich.textStorage.length, length: 0))
        endEvent()
        hosting.setMode(.source)
        endEvent()
        #expect(source.text == "one two **three**!")
        source.undoManager.undo()
        #expect(source.text == "one two **three**")
        source.undoManager.undo()
        #expect(source.text == "one two")
    }

    @Test func undoAfterASwitchPushesTheRestoredTextToTheBinding() throws {
        let hosting = makeHosting("one")
        let rich = try #require(hosting.controller)
        var pushed: [String] = []
        rich.textSink = { pushed.append($0) }
        hosting.setMode(.source)
        hosting.sourceController?.insertMarkdown(" two", replacing: NSRange(location: 3, length: 0))
        hosting.setMode(.rich)
        rich.undoManager.undo()
        #expect(pushed.last == "one")
    }

    @Test func externalLoadsDoNotLinkHistories() throws {
        let hosting = makeHosting("one")
        let rich = try #require(hosting.controller)
        let source = try #require(hosting.sourceController)
        hosting.setMode(.source)
        source.insertMarkdown(" two", replacing: NSRange(location: 3, length: 0))
        hosting.setMode(.rich)
        rich.setMarkdown("other")
        hosting.setMode(.source)
        #expect(source.text == "other")
        #expect(!source.undoManager.canUndo)
    }

    @Test func selectionCarriesAcrossSwitches() throws {
        let markdown = "# Title\n\nHello **world** and [a link](https://x.test) end\n\n- item one\n"
        let hosting = makeHosting(markdown)
        let rich = try #require(hosting.controller)
        let source = try #require(hosting.sourceController)
        let richText = rich.textStorage.string as NSString
        rich.setSelection(NSRange(location: richText.range(of: "world").location + 2, length: 3))
        hosting.setMode(.source)
        let sourceText = markdown as NSString
        #expect(source.currentSelection == NSRange(location: sourceText.range(of: "world").location + 2, length: 3))
        source.setSelection(NSRange(location: sourceText.range(of: "item one").location + 5, length: 0))
        hosting.setMode(.rich)
        #expect(rich.currentSelection == NSRange(location: richText.range(of: "item one").location + 5, length: 0))
        rich.setSelection(NSRange(location: richText.range(of: " end").location + 1, length: 0))
        hosting.setMode(.source)
        #expect(source.currentSelection.location == sourceText.range(of: " end").location + 1)
    }

    @Test func selectionMappingSkipsSyntax() {
        let rich = "item\nlink text\na\tb" as NSString
        let source = "- item\n\n[link text](https://x.test)\n\n| a | b |\n| - | - |" as NSString
        #expect(SourceSelectionMapping.sourceLocation(forRich: 0, rich: rich, source: source) == 2)
        let link = rich.range(of: "text").location
        #expect(SourceSelectionMapping.sourceLocation(forRich: link, rich: rich, source: source) == source.range(of: "text").location)
        let b = rich.length - 1
        #expect(SourceSelectionMapping.sourceLocation(forRich: b, rich: rich, source: source) == source.range(of: "b |").location)
        #expect(SourceSelectionMapping.richLocation(forSource: source.range(of: "https").location, rich: rich, source: source) == link + 4)
        #expect(SourceSelectionMapping.richLocation(forSource: source.range(of: "b |").location, rich: rich, source: source) == b)
    }

    @Test func sourceModeSpellCheckingLeavesOutAutocorrection() {
        #expect(SwiftProseEditor.Configuration().sourceSpellChecking == .spellingAndGrammar)
        #expect(SwiftProseEditor.Configuration(spellChecking: .spelling).sourceSpellChecking == .spelling)
        #expect(SwiftProseEditor.Configuration(sourceSpellChecking: .full).sourceSpellChecking == .full)
        #expect(!ProseSpellChecking.full.withoutAutocorrection.autocorrectEnabled)
    }

    @Test func defaultToolbarEndsWithTheModeToggle() {
        let toolbar = SwiftProseEditor.Configuration.defaultToolbar
        guard case .modeToggle = toolbar.last else {
            Issue.record("the default toolbar does not end with the mode toggle")
            return
        }
        guard case .spacer = toolbar[toolbar.count - 2] else {
            Issue.record("the mode toggle is not separated by a spacer")
            return
        }
    }
}

#if canImport(AppKit) && os(macOS)
@Suite("Mode switching hosted (macOS, .serialized)")
@MainActor
struct ModeSwitchingHostedTests {
    final class Box: @unchecked Sendable {
        var text: String
        var mode: EditorMode
        var writes: [String] = []
        var handles: [EditorHandle] = []
        init(_ text: String, mode: EditorMode = .rich) {
            self.text = text
            self.mode = mode
        }
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0; self.writes.append($0) }) }
        var modeBinding: Binding<EditorMode> { Binding(get: { self.mode }, set: { self.mode = $0 }) }
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func editor(_ box: Box, boundMode: Bool = true) -> AnyView {
        let base = SwiftProseEditor(text: box.binding)
            .configuration(SwiftProseEditor.Configuration(minHeight: 60))
            .onProseHandleReady { box.handles.append($0) }
            .frame(width: 600)
        return boundMode ? AnyView(base.editorMode(box.modeBinding)) : AnyView(base)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        var result: [NSSegmentedControl] = []
        if let control = view as? NSSegmentedControl { result.append(control) }
        for subview in view.subviews { result += segmentedControls(in: subview) }
        return result
    }

    private func host(_ view: AnyView) -> (NSWindow, NSHostingView<AnyView>) {
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        spin()
        return (window, hostingView)
    }

    private func refresh(_ hostingView: NSHostingView<AnyView>, _ view: AnyView) {
        hostingView.rootView = view
        hostingView.layoutSubtreeIfNeeded()
        spin()
    }

    @Test func switchingModesCarriesTheSelectionIntoTheNewHost() throws {
        let box = Box("Hello **world** end")
        let (window, hostingView) = host(editor(box))
        defer { window.close() }
        let richView = try #require(find(ProseNSTextView.self, in: hostingView))
        richView.setSelectedRange(NSRange(location: 8, length: 0))
        box.mode = .source
        refresh(hostingView, editor(box))
        let sourceView = try #require(find(ProseSourceNSTextView.self, in: hostingView))
        #expect(sourceView.selectedRange() == NSRange(location: 10, length: 0))
        #expect(!sourceView.isAutomaticSpellingCorrectionEnabled)
        #expect(sourceView.isContinuousSpellCheckingEnabled)
        sourceView.setSelectedRange(NSRange(location: 17, length: 0))
        box.mode = .rich
        refresh(hostingView, editor(box))
        let nextRich = try #require(find(ProseNSTextView.self, in: hostingView))
        #expect(nextRich.selectedRange() == NSRange(location: 13, length: 0))
    }

    @Test func switchingModesSwapsTheHostAndKeepsBytes() throws {
        let original = "* item\n\nSetext\n======\n\n| a | b |\n|---|:-:|\n| 1 | 2 |"
        let box = Box(original)
        let (window, hostingView) = host(editor(box))
        defer { window.close() }
        #expect(find(ProseNSTextView.self, in: hostingView) != nil)
        #expect(find(ProseSourceNSTextView.self, in: hostingView) == nil)

        box.mode = .source
        refresh(hostingView, editor(box))
        let sourceView = try #require(find(ProseSourceNSTextView.self, in: hostingView))
        #expect(find(ProseNSTextView.self, in: hostingView) == nil)
        #expect(sourceView.string == original)
        #expect(box.handles.last?.mode == .source)
        #expect(box.handles.last?.hostTextView === sourceView)

        box.mode = .rich
        refresh(hostingView, editor(box))
        let richView = try #require(find(ProseNSTextView.self, in: hostingView))
        #expect(box.handles.last?.richController.markdown() == original)
        #expect(box.writes.isEmpty)

        richView.setSelectedRange(NSRange(location: 0, length: 0))
        richView.insertText("x", replacementRange: richView.selectedRange())
        #expect(richView.textStorage === box.handles.last?.richController.textStorage)
        #expect(richView.string.hasPrefix("xitem"))
        #expect(box.text.hasPrefix("- xitem"))
    }

    @Test func typingInSourceModeUpdatesTheBindingAndRichMode() throws {
        let box = Box("hello", mode: .source)
        let (window, hostingView) = host(editor(box))
        defer { window.close() }
        let sourceView = try #require(find(ProseSourceNSTextView.self, in: hostingView))
        sourceView.setSelectedRange(NSRange(location: 5, length: 0))
        sourceView.insertText(" *there*", replacementRange: sourceView.selectedRange())
        #expect(box.text == "hello *there*")
        box.mode = .rich
        refresh(hostingView, editor(box))
        let handle = try #require(box.handles.last)
        #expect(handle.richController.markdown() == "hello *there*")
        #expect(handle.richController.textStorage.string == "hello there")
    }

    @Test func toolbarShowsTheToggleInBothModes() {
        for mode in EditorMode.allCases {
            let box = Box("text", mode: mode)
            let (window, hostingView) = host(editor(box))
            defer { window.close() }
            let tips = segmentedControls(in: hostingView).flatMap { control in
                (0..<control.segmentCount).compactMap { control.toolTip(forSegment: $0) }
            }
            #expect(tips.last == SwiftProseEditor.modeToggleTitle(for: mode))
            #expect(tips.contains("Bold (⌘B)"))
            #expect(tips.count == segmentedControls(in: hostingView).reduce(0) { $0 + $1.segmentCount })
        }
    }

    @Test func emptyToolbarRemovesTheToggle() {
        let box = Box("text")
        let view = AnyView(
            SwiftProseEditor(text: box.binding)
                .configuration(SwiftProseEditor.Configuration(toolbar: [.action(.bold)]))
                .frame(width: 600)
        )
        let (window, hostingView) = host(view)
        defer { window.close() }
        let tips = segmentedControls(in: hostingView).flatMap { control in
            (0..<control.segmentCount).compactMap { control.toolTip(forSegment: $0) }
        }
        #expect(tips == ["Bold (⌘B)"])
    }
}
#endif
