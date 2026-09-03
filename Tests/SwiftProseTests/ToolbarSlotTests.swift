import Testing
import Foundation
@testable import SwiftProse

@Suite struct ToolbarSlotTests {

    @Test func readOnlyKeepsTheToolbarSlot() {
        let cfg = SwiftProseEditor.Configuration(isEditable: false)
        #expect(SwiftProseEditor.showsToolbar(for: cfg))
        #expect(SwiftProseEditor.showsHeaderRow(for: cfg))
    }

    @Test func readOnlyWithoutStatusItemsStillRendersTheHeaderRow() {
        let editable = SwiftProseEditor.Configuration(statusItems: [], isEditable: true)
        let readOnly = SwiftProseEditor.Configuration(statusItems: [], isEditable: false)
        #expect(SwiftProseEditor.showsHeaderRow(for: editable)
                == SwiftProseEditor.showsHeaderRow(for: readOnly))
    }

    @Test func emptyToolbarHidesOnlyTheToolbar() {
        let cfg = SwiftProseEditor.Configuration(toolbar: [], statusItems: [.words])
        #expect(!SwiftProseEditor.showsToolbar(for: cfg))
        #expect(SwiftProseEditor.showsHeaderRow(for: cfg))
    }

    @Test func environmentDisabledOverridesAnEditableConfiguration() {
        let cfg = SwiftProseEditor.Configuration(isEditable: true)
        #expect(SwiftProseEditor.effectiveIsEditable(for: cfg, isEnabled: true))
        #expect(!SwiftProseEditor.effectiveIsEditable(for: cfg, isEnabled: false))
    }

    @Test func environmentEnabledDoesNotReEnableAReadOnlyConfiguration() {
        let cfg = SwiftProseEditor.Configuration(isEditable: false)
        #expect(!SwiftProseEditor.effectiveIsEditable(for: cfg, isEnabled: true))
        #expect(!SwiftProseEditor.effectiveIsEditable(for: cfg, isEnabled: false))
    }

    @Test func emptyToolbarAndNoStatusItemsDropsTheHeaderRow() {
        let cfg = SwiftProseEditor.Configuration(toolbar: [], statusItems: [])
        #expect(!SwiftProseEditor.showsToolbar(for: cfg))
        #expect(!SwiftProseEditor.showsHeaderRow(for: cfg))
    }

    @Test func aMenuItemFillsTheToolbarSlot() {
        let cfg = SwiftProseEditor.Configuration(toolbar: [
            .menu(
                id: "labels",
                label: "Label",
                systemImage: "tag",
                topLevel: true,
                entries: [
                    SwiftProseEditor.MenuEntry(id: "note", title: "note:", systemImage: "note.text", action: {}),
                    SwiftProseEditor.MenuEntry(id: "issue", title: "issue:", action: {})
                ]
            )
        ])
        #expect(SwiftProseEditor.showsToolbar(for: cfg))
        guard case let .menu(id, label, systemImage, topLevel, entries) = cfg.toolbar[0] else {
            Issue.record("expected a menu item")
            return
        }
        #expect(id == "labels")
        #expect(label == "Label")
        #expect(systemImage == "tag")
        #expect(topLevel)
        #expect(entries.map(\.id) == ["note", "issue"])
        #expect(entries[1].systemImage == nil)
    }

    @Test func aMenuEntryRunsItsAction() {
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()
        let entry = SwiftProseEditor.MenuEntry(id: "note", title: "note:") { box.fired = true }
        entry.action()
        #expect(box.fired)
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
}
