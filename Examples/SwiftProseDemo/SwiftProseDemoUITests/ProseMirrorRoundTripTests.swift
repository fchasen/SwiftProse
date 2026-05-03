import XCTest

final class ProseMirrorRoundTripTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLoadAndExportProducesDocJSON() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["load-pm"].tap()
        app.buttons["export-pm"].tap()
        let output = app.textViews["export-output"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        let value = (output.value as? String) ?? ""
        XCTAssertTrue(value.contains("\"type\":\"doc\""), "expected doc JSON, got: \(value)")
        XCTAssertTrue(value.contains("Loaded title"))
    }
}
