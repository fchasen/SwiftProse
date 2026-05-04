import XCTest

final class ToolbarTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testToolbarHasBoldButton() {
        let app = XCUIApplication()
        app.launchAndOpenNewDocument()
        let bold = app.buttons["bold"].firstMatch
        XCTAssertTrue(bold.waitForExistence(timeout: 10))
    }

}
