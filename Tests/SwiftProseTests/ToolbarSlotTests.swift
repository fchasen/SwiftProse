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
}
