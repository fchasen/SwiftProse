import XCTest

extension XCUIApplication {
    /// Launches the app and opens a fresh untitled document. The demo is a
    /// document-based app, so the editor is not visible until a document is
    /// created — every test driving the editor has to pass through this.
    func launchAndOpenNewDocument() {
        launch()
        #if os(macOS)
        typeKey("n", modifierFlags: .command)
        #else
        let candidates = [
            buttons["Create Document"],
            buttons["New Document"],
            buttons["Create"],
            otherElements["Create Document"],
            collectionViews.cells["Create Document"]
        ]
        for candidate in candidates {
            if candidate.waitForExistence(timeout: 3) {
                candidate.tap()
                return
            }
        }
        #endif
    }
}
