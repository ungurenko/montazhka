import XCTest

final class MontazhkaUITests: XCTestCase {
    @MainActor
    func testStartScreenExposesPrimaryActionsInOneWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["start.newProject"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["start.shorts"].exists)
        XCTAssertEqual(app.windows.count, 1)
    }
}
