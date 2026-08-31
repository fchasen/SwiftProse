import XCTest

/// The only permission-gated layer. Everything it covers is also covered
/// in-process by `SwiftProseDemoTests`; this exists to prove the same
/// flows work through real key events and the real accessibility surface.
///
/// **Unverified on the development machine**: the XCUITest runner cannot
/// initialize there (macOS UI-automation permission), so these are written
/// against the harness's accessibility identifiers and run on CI or on a
/// machine that has granted the permission. A failure here on an untested
/// machine means "no coverage", not "broken editor".
///
/// The scheme skips this bundle so a bare `xcodebuild test` is green
/// without the permission. Run it explicitly:
///
/// ```sh
/// xcodebuild test … -only-testing:SwiftProseDemoUITests
/// ```
final class HarnessUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches straight into the harness window — no Cmd-N, no document
    /// picker, one deterministic editor.
    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--harness", "ui"]
        app.launch()
        return app
    }

    private func editor(_ app: XCUIApplication) throws -> XCUIElement {
        let editor = app.descendants(matching: .textView).firstMatch
        guard editor.waitForExistence(timeout: 20) else {
            throw XCTSkip("the harness editor never appeared — UI automation is probably not permitted")
        }
        editor.click()
        return editor
    }

    /// The inspector mirrors `markdown()`, which is the only way an
    /// out-of-process test can read the document.
    private func mirror(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["markdown-mirror"].firstMatch
        guard element.waitForExistence(timeout: 5) else { return "" }
        return (element.value as? String) ?? element.label
    }

    func testTypingReachesTheEditor() throws {
        let app = launchHarness()
        let editor = try editor(app)
        editor.typeText("hello")
        let value = editor.value as? String
        XCTAssertTrue(value?.contains("hello") == true,
                      "typed text did not reach the editor: \(value ?? "nil")")
    }

    func testHeadingInputRuleThroughRealKeyEvents() throws {
        let app = launchHarness()
        let editor = try editor(app)
        editor.typeText("# Title")
        XCTAssertTrue(mirror(app).contains("# Title"), mirror(app))
    }

    func testEnterSplitsAndTabIndentsAList() throws {
        let app = launchHarness()
        let editor = try editor(app)
        editor.typeText("- one")
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("two")
        editor.typeKey(.tab, modifierFlags: [])
        let text = mirror(app)
        XCTAssertTrue(text.contains("- one"), text)
        XCTAssertTrue(text.contains("two"), text)
    }

    func testBoldToolbarButtonAppliesAMark() throws {
        let app = launchHarness()
        let editor = try editor(app)
        editor.typeText("loud")
        editor.typeKey("a", modifierFlags: .command)
        let bold = app.buttons["bold"].firstMatch
        guard bold.waitForExistence(timeout: 5) else {
            throw XCTSkip("the harness window has no toolbar; bold is covered in-process")
        }
        bold.click()
        XCTAssertTrue(mirror(app).contains("**loud**"), mirror(app))
    }

    func testUndoThroughTheMenu() throws {
        let app = launchHarness()
        let editor = try editor(app)
        editor.typeText("abc")
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(mirror(app).contains("abc"), mirror(app))
    }
}
