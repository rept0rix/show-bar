import XCTest

final class CompanionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
    }

    func testDemoIsClearlyLabeledAndCannotControlMac() {
        XCTAssertTrue(app.staticTexts["Show Bar Companion"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Connection: demo"].exists)
        XCTAssertTrue(app.staticTexts["XCODE"].exists)
        let snapLeft = app.buttons["Move selected Mac window: Left"]
        for _ in 0..<3 where !snapLeft.exists { app.swipeUp() }
        XCTAssertTrue(snapLeft.exists)
        XCTAssertFalse(snapLeft.isEnabled)
        attachScreenshot("Windows")
    }

    func testClipboardCanKeepAnExplicitLocalNote() {
        navigate("Clipboard")
        let draft = app.textViews["shelfDraft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        let note = "Companion UI test \(UUID().uuidString.prefix(6))"
        draft.typeText(note)
        let keep = app.buttons["Keep note"]
        if !keep.isHittable { app.swipeUp() }
        keep.tap()
        for _ in 0..<5 where !app.staticTexts[note].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts[note].exists)
        attachScreenshot("Clipboard")
    }

    func testShotEmptyStateAndPairingScreenAreReachable() {
        navigate("Shots")
        XCTAssertTrue(app.staticTexts["A clear space for your captures"].waitForExistence(timeout: 5))
        attachScreenshot("Shots")
        navigate("Connect")
        XCTAssertTrue(app.staticTexts["Sample workspace · remote actions disabled"].waitForExistence(timeout: 5))
        attachScreenshot("Connect")
    }

    func testSettingsPersistsPreferencesAndDoesNotInventPermissionGrants() {
        let gear = app.buttons["settingsAndPermissions"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        let confirmClose = app.switches["confirmWindowClose"]
        let previews = app.switches["showWindowPreviews"]
        XCTAssertTrue(confirmClose.waitForExistence(timeout: 5))
        XCTAssertTrue(previews.exists)
        let initial = confirmClose.value as? String
        confirmClose.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changedValue = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", initial ?? "1"), object: confirmClose)
        XCTAssertEqual(XCTWaiter.wait(for: [changedValue], timeout: 3), .completed)
        let changed = confirmClose.value as? String
        XCTAssertNotEqual(initial, changed)
        app.buttons["Done"].tap()
        gear.tap()
        XCTAssertTrue(confirmClose.waitForExistence(timeout: 5))
        XCTAssertEqual(confirmClose.value as? String, changed)
        confirmClose.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let restoredValue = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", initial ?? "1"), object: confirmClose)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredValue], timeout: 3), .completed)
        XCTAssertEqual(confirmClose.value as? String, initial)
        let disclaimer = app.staticTexts["Demo content cannot verify any system permission."]
        for _ in 0..<4 where !disclaimer.isHittable { app.swipeUp() }
        XCTAssertTrue(disclaimer.exists)
        attachScreenshot("Settings and permissions")
    }

    func testURLImportAddsNoteToShelf() {
        navigate("Clipboard")
        let note = "ImportedURL-\(UUID().uuidString.prefix(6))"
        guard let url = URL(string: "showbar://shelf/add?text=\(note)") else { return }
        app.open(url)
        for _ in 0..<5 where !app.staticTexts[note].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts[note].waitForExistence(timeout: 5))
        attachScreenshot("URL Import")
    }

    private func navigate(_ section: String) {
        if app.tabBars.buttons[section].exists { app.tabBars.buttons[section].tap() }
        else { app.buttons[section].firstMatch.tap() }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
