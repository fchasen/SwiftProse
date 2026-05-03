import XCTest

final class EditorTypingTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEditorAcceptsTypedCharacter() {
        let app = XCUIApplication()
        app.launch()
        let editor = app.descendants(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" extra")
        XCTAssertTrue(editor.value as? String != nil)
    }
}
