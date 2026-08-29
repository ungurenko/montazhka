import XCTest

final class MontazhkaUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-ui-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    override func tearDown() async throws {
        app?.terminate()
        if let dataDirectory {
            try? FileManager.default.removeItem(at: dataDirectory)
        }
    }

    @MainActor
    func testStartScreenExposesPrimaryActionsInOneWindow() throws {
        launch()

        XCTAssertTrue(app.buttons["start.newProject"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["start.shorts"].exists)
        XCTAssertEqual(app.windows.count, 1)

        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(frame.width, 1_079)
        XCTAssertGreaterThanOrEqual(frame.height, 659)
    }

    @MainActor
    func testEmptyProjectSupportsRenameAndExposesImportAndExportStates() throws {
        launch(extraArguments: ["--ui-test-open-empty-project"])

        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 10))
        let name = app.textFields["editor.projectName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Тестовый монтаж")
        name.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(name.value as? String, "Тестовый монтаж")

        XCTAssertTrue(app.buttons["editor.addVideo"].isEnabled)
        XCTAssertTrue(app.buttons["editor.export"].exists)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled)

        app.buttons["editor.addVideo"].click()
        let panelAppeared =
            app.dialogs.firstMatch.waitForExistence(timeout: 5)
            || app.sheets.firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(panelAppeared)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testLocalFixtureProjectOpensCompactExportWithoutNetwork() throws {
        launch(extraArguments: ["--ui-test-open-fixture-project"])

        let export = app.buttons["editor.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 15))
        XCTAssertTrue(export.isEnabled)
        export.click()

        let compact = app.buttons["export.quality.compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.click()
        app.buttons["export.start"].click()

        let savePanelAppeared =
            app.dialogs.firstMatch.waitForExistence(timeout: 5)
            || app.sheets.firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(savePanelAppeared)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testEditorMenusOpenEveryUnifiedInspector() throws {
        launch(extraArguments: ["--ui-test-open-empty-project"])

        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 10))
        assertInspector(
            menuIdentifier: "editor.cleanupMenu",
            itemTitle: "Найти паузы",
            inspectorIdentifier: "editor.inspector.pauses")
        assertInspector(
            menuIdentifier: "editor.cleanupMenu",
            itemTitle: "Умный монтаж",
            inspectorIdentifier: "editor.inspector.smartEdit")
        assertInspector(
            menuIdentifier: "editor.soundMenu",
            itemTitle: "Улучшить голос",
            inspectorIdentifier: "editor.inspector.voice")
        assertInspector(
            menuIdentifier: "editor.soundMenu",
            itemTitle: "Фоновая музыка",
            inspectorIdentifier: "editor.inspector.music")
    }

    @MainActor
    func testShortsSettingsWorkWithoutNetworkOrUserData() throws {
        launch(extraArguments: ["--ui-test-open-shorts"])

        XCTAssertTrue(app.buttons["shorts.back"].waitForExistence(timeout: 10))
        // macOS 15 не возвращает accessibilityIdentifier для кнопок внутри ScrollView,
        // поэтому сценарий нажимает на её явную accessibilityLabel.
        let appearance = app.buttons["Оформление"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.click()
        let subtitles = app.switches["shorts.subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        subtitles.click()
        XCTAssertTrue(app.descendants(matching: .any)["shorts.subtitleStyle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["shorts.subtitleSize"].exists)

        let frameMode = app.descendants(matching: .any)["shorts.frameMode"]
        XCTAssertTrue(frameMode.exists)
        frameMode.click()
        XCTAssertTrue(app.menuItems["Целиком 9:16"].waitForExistence(timeout: 3))
        app.menuItems["Целиком 9:16"].click()
        XCTAssertTrue(app.descendants(matching: .any)["shorts.canvasColor"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func assertInspector(
        menuIdentifier: String,
        itemTitle: String,
        inspectorIdentifier: String
    ) {
        let menu = app.descendants(matching: .any)[menuIdentifier]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let item = app.menuItems[itemTitle]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()

        let inspector = app.descendants(matching: .any)[inspectorIdentifier]
        XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    }

    @MainActor
    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments =
            [
                "-ApplePersistenceIgnoreState", "YES",
                "--ui-testing",
            ] + extraArguments
        app.launchEnvironment["MONTAZHKA_UI_TEST_DATA_DIR"] = dataDirectory.path
        app.launchEnvironment["MONTAZHKA_UI_TEST_MODE"] = "1"
        app.launch()
    }

}
