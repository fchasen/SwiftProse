import CoreGraphics
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

@Suite("SwiftUI configuration", .serialized)
struct SwiftUIConfigurationTests {
    @Test func readOnlyKeepsTheToolbarSlot() {
        let configuration = SwiftProseEditor.Configuration(isEditable: false)
        #expect(SwiftProseEditor.showsToolbar(for: configuration))
    }

    @Test func emptyToolbarHidesTheToolbar() {
        #expect(!SwiftProseEditor.showsToolbar(for: SwiftProseEditor.Configuration(toolbar: [])))
    }

    @Test func environmentDisabledOverridesAnEditableConfiguration() {
        let editable = SwiftProseEditor.Configuration(isEditable: true)
        let readOnly = SwiftProseEditor.Configuration(isEditable: false)
        #expect(SwiftProseEditor.effectiveIsEditable(for: editable, isEnabled: true))
        #expect(!SwiftProseEditor.effectiveIsEditable(for: editable, isEnabled: false))
        #expect(!SwiftProseEditor.effectiveIsEditable(for: readOnly, isEnabled: true))
        #expect(!SwiftProseEditor.effectiveIsEditable(for: readOnly, isEnabled: false))
    }

    @Test func defaultToolbarListsTheFormattingActions() {
        let actions = SwiftProseEditor.Configuration.defaultToolbar.actions
        #expect(actions == [
            .bold, .italic, .strikethrough,
            .heading(level: 1), .heading(level: 2), .heading(level: 3),
            .unorderedList, .orderedList, .taskList, .blockquote,
            .codeSpan, .codeBlock, .link, .horizontalRule
        ])
        #expect(SwiftProseEditor.Configuration().toolbar.actions == actions)
    }

    @Test func replacingLinkSwapsInACustomItem() {
        let replaced = SwiftProseEditor.Configuration.defaultToolbar.replacing(
            .link,
            with: .custom(id: "linkInsert", label: "Insert Link", systemImage: "link", action: {})
        )
        #expect(!replaced.actions.contains(.link))
        #expect(replaced.count == SwiftProseEditor.Configuration.defaultToolbar.count)
        let ids = replaced.compactMap { item -> String? in
            if case let .custom(id, _, _, _, _, _) = item { return id }
            return nil
        }
        #expect(ids == ["linkInsert"])
    }

    @Test func replacingAnActionLeavesAMenuItemAlone() {
        let items: [SwiftProseEditor.ToolbarItem] = [
            .action(.bold),
            .menu(id: "labels", label: "Label", systemImage: "tag", entries: [])
        ]
        let replaced = items.replacing(.bold, with: .divider)
        if case .divider = replaced[0] {} else { Issue.record("the action was not replaced") }
        if case .menu = replaced[1] {} else { Issue.record("the menu was rewritten") }
    }

    @Test func menuItemCarriesItsEntries() {
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()
        let item = SwiftProseEditor.ToolbarItem.menu(
            id: "labels",
            label: "Label",
            systemImage: "tag",
            topLevel: true,
            entries: [
                SwiftProseEditor.MenuEntry(id: "note", title: "note:", systemImage: "note.text") { box.fired = true },
                SwiftProseEditor.MenuEntry(id: "issue", title: "issue:", action: {})
            ]
        )
        guard case let .menu(id, _, _, topLevel, entries) = item else {
            Issue.record("expected a menu item")
            return
        }
        #expect(id == "labels")
        #expect(topLevel)
        #expect(entries.map(\.id) == ["note", "issue"])
        #expect(entries[1].systemImage == nil)
        entries[0].action()
        #expect(box.fired)
    }

    @Test func environmentValuesRoundTrip() {
        var environment = EnvironmentValues()
        environment.proseTheme = .default(fontScale: 2)
        environment.proseConfiguration = SwiftProseEditor.Configuration(toolbar: [], minHeight: 40)
        environment.proseInlineContentRules = [InlineContentRule(id: "r", pattern: "x") { _ in nil }]
        #expect(environment.proseTheme == .default(fontScale: 2))
        #expect(environment.proseConfiguration.toolbar.isEmpty)
        #expect(environment.proseConfiguration.minHeight == 40)
        #expect(environment.proseInlineContentRules.map(\.id) == ["r"])
        #expect(environment.proseInlineContentProvider == nil)
        #expect(environment.proseControllerReady == nil)
    }
}

@Suite("Completion popup placement", .serialized)
struct CompletionPopupPlacementTests {
    @Test func placesBelowWhenThereIsRoom() {
        let anchor = CGRect(x: 40, y: 40, width: 2, height: 20)
        let origin = CompletionPopupPlacement.origin(
            anchorRect: anchor,
            menuSize: CGSize(width: 180, height: 120),
            containerBounds: CGRect(x: 0, y: 0, width: 320, height: 400)
        )
        #expect(origin.y >= anchor.maxY)
    }

    @Test func placesAboveWhenTheBottomIsClose() {
        let anchor = CGRect(x: 40, y: 40, width: 2, height: 20)
        let menuSize = CGSize(width: 180, height: 120)
        let origin = CompletionPopupPlacement.origin(
            anchorRect: anchor,
            menuSize: menuSize,
            containerBounds: CGRect(x: 0, y: -260, width: 320, height: 340)
        )
        #expect(origin.y + menuSize.height <= anchor.minY)
    }

    @Test func clampsHorizontallyWithinTheContainer() {
        let anchor = CGRect(x: 290, y: 40, width: 2, height: 20)
        let menuSize = CGSize(width: 180, height: 80)
        let container = CGRect(x: 0, y: 0, width: 320, height: 400)
        let origin = CompletionPopupPlacement.origin(anchorRect: anchor, menuSize: menuSize, containerBounds: container)
        #expect(origin.x + menuSize.width <= container.maxX)
    }
}

@Suite("Editor hosting", .serialized)
@MainActor
struct EditorHostingTests {
    private func makeHosting(_ markdown: String, rules: [InlineContentRule] = []) -> (EditorHosting, EditorController) {
        let hosting = EditorHosting()
        hosting.trackedActions = SwiftProseEditor.Configuration.defaultToolbar.actions
        let controller = hosting.ensureController(
            markdown: markdown,
            theme: .default,
            inlineContentRules: rules,
            inlineContentProvider: nil,
            allowsCheckboxToggle: true
        )
        return (hosting, controller)
    }

    @Test func ensureControllerIsIdempotentAndKeepsTheSourceBytes() {
        let (hosting, controller) = makeHosting("* item\n\nSetext\n======")
        let again = hosting.ensureController(
            markdown: "different",
            theme: .default,
            inlineContentRules: [],
            inlineContentProvider: nil,
            allowsCheckboxToggle: false
        )
        #expect(again === controller)
        #expect(controller.allowsCheckboxToggle)
        #expect(controller.markdown() == "* item\n\nSetext\n======")
    }

    @Test func toolbarStateTracksTheSelection() {
        let (hosting, controller) = makeHosting("**bold** plain\n\n```\ncode\n```")
        controller.setSelection(NSRange(location: 1, length: 2))
        hosting.refreshToolbarState()
        #expect(hosting.isActive(.bold))
        #expect(!hosting.isActive(.italic))
        #expect(hosting.canPerform(.bold))

        let codeLocation = (controller.textStorage.string as NSString).range(of: "code").location
        controller.setSelection(NSRange(location: codeLocation + 1, length: 0))
        hosting.refreshToolbarState()
        #expect(hosting.isActive(.codeBlock))
        #expect(!hosting.isActive(.bold))
        #expect(!hosting.canPerform(.bold))
        #expect(!hosting.canPerform(.link))
        #expect(hosting.canPerform(.codeBlock))
    }

    @Test func readOnlyDisablesEveryTrackedAction() {
        let (hosting, controller) = makeHosting("text")
        controller.isEditable = false
        hosting.refreshToolbarState()
        for action in hosting.trackedActions {
            #expect(!hosting.canPerform(action))
        }
    }

    @Test func unchangedInlineContentDoesNotReload() {
        let rule = InlineContentRule(id: "label", pattern: #"\{nav[^}]*\}"#) { _ in .custom(kind: "k", label: "l", systemImage: "tag") }
        let (hosting, controller) = makeHosting("hello", rules: [rule])
        var loads = 0
        let token = controller.addOnDocumentChange { change in
            if change.origin == .load { loads += 1 }
        }
        hosting.applyInlineContent(rules: [rule], provider: nil)
        #expect(loads == 0)
        hosting.applyInlineContent(rules: [], provider: nil)
        #expect(loads == 0)
        #expect(controller.inlineContentRules.isEmpty)
        #expect(controller.markdown() == "hello")
        controller.removeObserver(token)
    }
}

#if canImport(AppKit) && os(macOS)
@Suite("SwiftProseEditor hosted (macOS, .serialized)")
@MainActor
struct SwiftProseEditorHostedTests {
    final class BindingBox: @unchecked Sendable {
        var value: String
        var writes: [String] = []
        init(_ value: String) { self.value = value }
        var binding: Binding<String> {
            Binding(get: { self.value }, set: { self.value = $0; self.writes.append($0) })
        }
    }

    final class ReadyBox {
        var controllers: [EditorController] = []
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func editor(
        _ box: BindingBox,
        ready: ReadyBox,
        isEditable: Bool = true,
        fontScale: CGFloat = 1
    ) -> some View {
        SwiftProseEditor(text: box.binding)
            .theme(.default(fontScale: fontScale))
            .configuration(SwiftProseEditor.Configuration(minHeight: 60, isEditable: isEditable))
            .onProseControllerReady { ready.controllers.append($0) }
            .frame(width: 400)
    }

    private func findTextView(in view: NSView) -> ProseNSTextView? {
        if let textView = view as? ProseNSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        spin()
        return (window, hostingView)
    }

    @Test func loadThemeAndEditableToggleNeverWriteTheBinding() throws {
        let original = "* item\n\nSetext\n======"
        let box = BindingBox(original)
        let ready = ReadyBox()
        let (window, hostingView) = host(editor(box, ready: ready))
        defer { window.close() }
        let textView = try #require(findTextView(in: hostingView))
        #expect(ready.controllers.count >= 1)
        let controller = try #require(ready.controllers.last)
        #expect(controller.hostTextView === textView)
        #expect(textView.isEditable)

        hostingView.rootView = editor(box, ready: ready, isEditable: false, fontScale: 1.4)
        hostingView.layoutSubtreeIfNeeded()
        spin()
        #expect(!textView.isEditable)
        #expect(!controller.isEditable)
        #expect(controller.theme == .default(fontScale: 1.4))

        hostingView.rootView = editor(box, ready: ready, isEditable: true)
        hostingView.layoutSubtreeIfNeeded()
        spin()
        #expect(textView.isEditable)
        #expect(box.writes.isEmpty)
        #expect(controller.markdown() == original)
    }

    @Test func typingWritesTheBindingOnceSynchronously() throws {
        let box = BindingBox("hello")
        let ready = ReadyBox()
        let (window, hostingView) = host(editor(box, ready: ready))
        defer { window.close() }
        let textView = try #require(findTextView(in: hostingView))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        #expect(box.writes == ["hello!"])
        hostingView.layoutSubtreeIfNeeded()
        spin()
        #expect(box.writes == ["hello!"])
        #expect(textView.string == "hello!")
    }

    @Test func externalTextReplacesTheDocumentWithoutWritingBack() throws {
        let box = BindingBox("hello")
        let ready = ReadyBox()
        let (window, hostingView) = host(editor(box, ready: ready))
        defer { window.close() }
        let textView = try #require(findTextView(in: hostingView))
        box.value = "# replaced"
        hostingView.rootView = editor(box, ready: ready)
        hostingView.layoutSubtreeIfNeeded()
        spin()
        #expect(textView.string == "replaced")
        #expect(box.writes.isEmpty)
        #expect(ready.controllers.last?.markdown() == "# replaced")
    }
}
#endif

#if canImport(UIKit) && os(iOS)
import UIKit

@Suite("SwiftProseEditor edit menu (iOS, .serialized)")
@MainActor
struct SwiftProseEditorEditMenuTests {
    @Test func toolbarMapsToTopLevelItemsAndAFormatMenu() throws {
        let controller = EditorController(markdown: "**bold**")
        controller.setSelection(NSRange(location: 1, length: 1))
        let toolbar: [SwiftProseEditor.ToolbarItem] = [
            .custom(id: "bug", label: "Insert Bug", systemImage: "ant", topLevel: true, action: {}),
            .menu(id: "label", label: "Label", systemImage: "tag", topLevel: true, entries: [
                SwiftProseEditor.MenuEntry(id: "note", title: "note:", action: {})
            ]),
            .divider
        ] + SwiftProseEditor.Configuration.defaultToolbar
        let suggested: [UIMenuElement] = [UIAction(title: "Copy") { _ in }]
        let menu = SwiftProseEditor.editMenu(toolbar: toolbar, suggested: suggested, controller: controller)
        #expect(menu.children.map(\.title) == ["Copy", "Insert Bug", "Label", "Format"])
        let format = try #require(menu.children.last as? UIMenu)
        #expect(format.children.count == 4)
        let firstSection = try #require(format.children.first as? UIMenu)
        let bold = try #require(firstSection.children.first as? UIAction)
        #expect(bold.title == "Bold")
        #expect(bold.state == .on)
    }
}
#endif

#if canImport(UIKit) && os(iOS)
@MainActor
@Suite("Source edit menu (iOS)")
struct SourceEditMenuTests {
    @Test func sourceEditMenuShowsTheToggleAndOnlyAvailableTableActions() throws {
        var toggles = 0
        let controller = SourceEditorController(text: "**bold**")
        controller.setSelection(NSRange(location: 3, length: 1))
        let menu = SwiftProseEditor.editMenu(
            toolbar: SwiftProseEditor.Configuration.defaultToolbar,
            suggested: [UIAction(title: "Copy") { _ in }],
            canPerform: { controller.canPerform($0) },
            isActive: { controller.isActive($0) },
            perform: { controller.perform($0) },
            mode: .source,
            onToggleMode: { toggles += 1 }
        )
        #expect(menu.children.map(\.title) == ["Copy", SwiftProseEditor.modeToggleTitle(for: .source), "Format"])
        let toggle = try #require(menu.children[1] as? UIAction)
        #expect(toggle.state == .off)
        let format = try #require(menu.children.last as? UIMenu)
        let table = format.children.compactMap { $0 as? UIMenu }.flatMap(\.children).compactMap { $0 as? UIMenu }.first { $0.title == "Table" }
        #expect(table?.children.map(\.title) == ["Insert Table"])
        let bold = try #require((format.children.first as? UIMenu)?.children.first as? UIAction)
        #expect(bold.state == .on)
    }
}
#endif
