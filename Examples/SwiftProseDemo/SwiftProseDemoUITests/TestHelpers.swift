import XCTest

extension XCUIApplication {
    /// Launches the app straight into the harness window. The demo is a
    /// document-based app, so without `--harness` the editor is not visible
    /// until a document exists — which used to mean a Cmd-N and a
    /// restoration race in every test.
    func launchHarness() {
        launchArguments += ["--harness", "ui"]
        launch()
    }

    /// The pre-harness path, kept for a test that deliberately exercises
    /// the real `DocumentGroup`.
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
