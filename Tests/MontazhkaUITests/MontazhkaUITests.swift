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
        replaceProjectName(with: "Тестовый монтаж")
        app.typeKey(.return, modifierFlags: [])
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
    func testProjectNameCommitsOnSubmitBlurAndBackAndCancelsDraft() throws {
        launch(extraArguments: ["--ui-test-open-empty-project"])
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 10))
        let original = try waitForSavedProject { $0.clips.isEmpty }.name
        let name = app.textFields["editor.projectName"]

        replaceProjectName(with: "После Enter")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        _ = try waitForSavedProject { $0.name == "После Enter" }
        performEditMenuAction("Отменить")
        _ = try waitForSavedProject { $0.name == original }
        XCTAssertEqual(name.value as? String, original)

        replaceProjectName(with: "После ухода из поля")
        // Tab navigation depends on the user's macOS keyboard settings.
        assertInspector(
            menuIdentifier: "editor.soundMenu", itemTitle: "Улучшить голос",
            inspectorIdentifier: "editor.inspector.voice")
        _ = try waitForSavedProject { $0.name == "После ухода из поля" }

        replaceProjectName(with: "Отменённый черновик")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(name.value as? String, "После ухода из поля")
        performEditMenuAction("Отменить")
        _ = try waitForSavedProject { $0.name == original }
        XCTAssertEqual(name.value as? String, original)
        performEditMenuAction("Повторить")
        _ = try waitForSavedProject { $0.name == "После ухода из поля" }
        XCTAssertEqual(name.value as? String, "После ухода из поля")

        replaceProjectName(with: "   ")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(name.value as? String, "После ухода из поля")

        replaceProjectName(with: "Устаревший черновик")
        try renameSavedProjectExternally(to: "Внешнее название")
        let synchronized = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Внешнее название"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [synchronized], timeout: 10), .completed)
        app.typeKey(.return, modifierFlags: [])
        _ = try waitForSavedProject { $0.name == "Внешнее название" }

        replaceProjectName(with: "Сохранено при возврате")
        app.buttons["editor.back"].click()
        XCTAssertTrue(app.buttons["start.newProject"].waitForExistence(timeout: 10))
        _ = try waitForSavedProject { $0.name == "Сохранено при возврате" }
    }

    @MainActor
    func testInspectorSlidersExposeUnitsAndPreserveUndoSettings() throws {
        launch(extraArguments: ["--ui-test-open-empty-project"])
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 10))
        let original = try waitForSavedProject { $0.clips.isEmpty }
        assertInspector(
            menuIdentifier: "editor.cleanupMenu", itemTitle: "Найти паузы",
            inspectorIdentifier: "editor.inspector.pauses")
        let sensitivity = accessibleSlider("Чувствительность", unit: "дБ")
        _ = accessibleSlider("Минимальная пауза", unit: "сек")
        let padding = accessibleSlider("Воздух по краям", unit: "мс")
        sensitivity.adjust(toNormalizedSliderPosition: 0.8)
        _ = try waitForSavedProject { $0.detection.thresholdDB != original.detection.thresholdDB }
        performEditMenuAction("Отменить")
        _ = try waitForSavedProject { $0.detection.thresholdDB == original.detection.thresholdDB }
        XCTAssertEqual(sensitivity.value as? String, "\(Int(original.detection.thresholdDB)) дБ")

        padding.adjust(toNormalizedSliderPosition: 0.8)
        let changed = try waitForSavedProject { $0.detection.paddingMS != original.detection.paddingMS }
        XCTAssertEqual(changed.detection.thresholdDB, original.detection.thresholdDB)
        XCTAssertEqual(changed.detection.minPauseDuration, original.detection.minPauseDuration)

        assertInspector(
            menuIdentifier: "editor.soundMenu", itemTitle: "Улучшить голос",
            inspectorIdentifier: "editor.inspector.voice")
        let voice = app.switches["Улучшить голос"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.click()
        _ = accessibleSlider("Выравнивание громкости", unit: "%")
        _ = accessibleSlider("Чистка шума", unit: "%")
        let presence = accessibleSlider("Звонкость", unit: "%")
        presence.adjust(toNormalizedSliderPosition: 0.8)
        _ = try waitForSavedProject { $0.voiceEnhance.presence != original.voiceEnhance.presence }

        assertInspector(
            menuIdentifier: "editor.soundMenu", itemTitle: "Фоновая музыка",
            inspectorIdentifier: "editor.inspector.music")
        let music = app.switches["Добавить музыку"]
        XCTAssertTrue(music.waitForExistence(timeout: 5))
        music.click()
        let volume = accessibleSlider("Громкость музыки", unit: "%")
        volume.adjust(toNormalizedSliderPosition: 0.8)
        _ = try waitForSavedProject { $0.music.volume != original.music.volume }
    }

    @MainActor
    func testClipReorderCommitsOnceAndOutsideDropKeepsSavedOrder() throws {
        launch(extraArguments: ["--ui-test-open-fixture-project", "--ui-test-reorder-fixture"])
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 15))
        let original = try waitForSavedProject { $0.clips.count == 3 }
        let ids = original.clips.map(\.id)
        assertClipOrder(ids)

        let start = clip(ids[0]).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = clip(ids[2]).coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: target)
        let reordered = [ids[1], ids[2], ids[0]]
        _ = try waitForSavedProject { $0.clips.map(\.id) == reordered }
        assertClipOrder(reordered)
        performEditMenuAction("Отменить")
        _ = try waitForSavedProject { $0.clips.map(\.id) == ids }
        assertClipOrder(ids)

        let window = app.windows.firstMatch
        let dragStart = clip(ids[0]).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // A horizontal path crosses both neighbours before it leaves the window.
        let outside = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: 20, dy: dragStart.screenPoint.y - window.frame.minY))
        dragStart.press(forDuration: 0.2, thenDragTo: outside)
        assertClipOrder(ids)
        // Force a subsequent save: an uncommitted mutation must not surface later.
        replaceProjectName(with: "После отменённого перетаскивания")
        app.typeKey(.return, modifierFlags: [])
        let saved = try waitForSavedProject { $0.name == "После отменённого перетаскивания" }
        XCTAssertEqual(saved.clips, original.clips)
    }

    @MainActor
    func testEditorResizesAndEnforcesMinimumWindowSize() throws {
        launch(extraArguments: ["--ui-test-open-empty-project"])
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let initial = window.frame
        resizeWindow(window, by: CGVector(dx: 160, dy: 100))
        XCTAssertGreaterThan(window.frame.width, initial.width + 100)
        XCTAssertGreaterThan(window.frame.height, initial.height + 60)
        XCTAssertTrue(app.buttons["editor.back"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["editor.timeline"].exists)
        attachWindowScreenshot(window, name: "Editor at larger size")

        resizeWindow(window, by: CGVector(dx: 800 - window.frame.width, dy: 400 - window.frame.height))
        XCTAssertGreaterThanOrEqual(window.frame.width, 1_079)
        XCTAssertGreaterThanOrEqual(window.frame.height, 659)
        XCTAssertLessThanOrEqual(window.frame.width, 1_100)
        XCTAssertLessThanOrEqual(window.frame.height, 710)
        XCTAssertTrue(app.buttons["editor.back"].isHittable)
        XCTAssertTrue(app.buttons["editor.addVideo"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["editor.timeline"].exists)
        attachWindowScreenshot(window, name: "Editor at minimum size")
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
        // The fixture starts with subtitles enabled. Exercise both transitions.
        let presets = app.buttons["Образ субтитров: Классика"]
        XCTAssertTrue(presets.waitForExistence(timeout: 5))
        subtitles.click()
        XCTAssertFalse(presets.exists)
        subtitles.click()
        XCTAssertTrue(presets.waitForExistence(timeout: 5))
        // Тонкая настройка спрятана за «Настроить» — раскрываем её так же,
        // как «Оформление»: нажатием на кнопку по её accessibilityLabel.
        let settings = app.buttons["Настроить"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        XCTAssertTrue(app.descendants(matching: .any)["shorts.subtitleSize"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["shorts.subtitlePosition"].exists)

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

    @MainActor
    private func replaceProjectName(with value: String) {
        let name = app.textFields["editor.projectName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        // Synthesized Command-A can lose the selection on macOS.
        performEditMenuAction("selectAll:")
        app.typeText(value)
    }

    @MainActor
    private func performEditMenuAction(_ identifier: String) {
        let edit = app.menuBars.menuBarItems.element(
            matching: NSPredicate(format: "title IN %@", ["Правка", "Edit"]))
        XCTAssertTrue(edit.exists)
        edit.click()
        let item = app.menuItems[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        XCTAssertTrue(item.isEnabled)
        item.click()
    }

    @MainActor
    private func accessibleSlider(_ title: String, unit: String) -> XCUIElement {
        let slider = app.sliders[title]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.label, title)
        XCTAssertTrue((slider.value as? String)?.contains(unit) == true)
        return slider
    }

    @MainActor
    private func clip(_ id: UUID) -> XCUIElement {
        app.descendants(matching: .any)["timeline.clip.\(id.uuidString)"].firstMatch
    }

    @MainActor
    private func assertClipOrder(_ ids: [UUID]) {
        var previousX = -CGFloat.infinity
        for id in ids {
            let element = clip(id)
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(element.frame.midX, previousX)
            previousX = element.frame.midX
        }
    }

    @MainActor
    private func resizeWindow(_ window: XCUIElement, by offset: CGVector) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(offset))
    }

    @MainActor
    private func attachWindowScreenshot(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct SavedProject: Decodable, Sendable {
        let name: String
        let clips: [SavedClip]
        let detection: Detection
        let voiceEnhance: Voice
        let music: Music

        struct SavedClip: Decodable, Equatable, Sendable {
            let id: UUID
            let start: Double
            let end: Double
        }

        struct Detection: Decodable, Sendable {
            let thresholdDB: Double
            let minPauseDuration: Double
            let paddingMS: Double
        }

        struct Voice: Decodable, Sendable {
            let presence: Double
        }

        struct Music: Decodable, Sendable {
            let volume: Double
        }
    }

    @MainActor
    private func waitForSavedProject(
        _ condition: @escaping @Sendable (SavedProject) -> Bool
    ) throws -> SavedProject {
        let directory = try XCTUnwrap(dataDirectory)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let project = try? Self.savedProject(in: directory) else { return false }
                return condition(project)
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        return try Self.savedProject(in: directory)
    }

    private static func savedProject(in directory: URL) throws -> SavedProject {
        try JSONDecoder().decode(SavedProject.self, from: Data(contentsOf: savedProjectFile(in: directory)))
    }

    private static func savedProjectFile(in directory: URL) throws -> URL {
        let projects = directory.appendingPathComponent("Projects", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".meta.json") }
        let latest = files.max {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) < (right ?? .distantPast)
        }
        guard let file = latest else { throw CocoaError(.fileNoSuchFile) }
        return file
    }

    @MainActor
    private func renameSavedProjectExternally(to name: String) throws {
        let directory = try XCTUnwrap(dataDirectory)
        let file = try Self.savedProjectFile(in: directory)
        var project = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        project["name"] = name
        project["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

}
