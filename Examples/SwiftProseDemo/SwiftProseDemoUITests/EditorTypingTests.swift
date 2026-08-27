import XCTest

final class EditorTypingTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEditorAcceptsTypedCharacter() {
        let app = XCUIApplication()
        app.launchAndOpenNewDocument()
        let editor = app.descendants(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(" extra")
        // The value is the rendered text; a keystroke that AppKit dropped
        // (an exception in the input path) leaves it unchanged.
        let value = editor.value as? String
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("extra") == true, "typed text did not reach the editor: \(value ?? "nil")")
    }
}
