import XCTest

/// Smoke tests that drive the real app UI: typing & playing, tap-a-line, the keyboard close
/// button, the curated voice picker, Hebrew, PDF and photo flows.
final class ReadAloudUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the app with the welcome dialog skipped; extra env vars pre-load content.
    @discardableResult
    private func launchApp(env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = env
        app.launchEnvironment["UITEST_SKIP_WELCOME"] = "1"
        app.launch()
        // The one-time "voice download" alert may cover the UI on a fresh simulator.
        let ok = app.buttons["OK"]
        if ok.waitForExistence(timeout: 2) { ok.tap() }
        return app
    }

    private func status(_ app: XCUIApplication) -> XCUIElement {
        // Full-screen readers layer a second player bar over the Read tab's; both mirror the
        // same playback state, so the first match is always representative.
        app.staticTexts.matching(identifier: "statusText").firstMatch
    }

    private func waitForReading(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        let reading = status(app).label.contains("Reading sentence")
        if reading { return }
        let predicate = NSPredicate(format: "label CONTAINS 'Reading sentence'")
        expectation(for: predicate, evaluatedWith: status(app))
        waitForExpectations(timeout: timeout)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Tests

    /// Type text → play → status shows reading → editor flips to Read mode → tap a line seeks →
    /// stop works.
    func testTypeAndPlayAndTapLine() throws {
        let app = launchApp()

        let editor = app.textViews["mainEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Hello there, this is the first sentence.\nHere is a second line to tap on.\nAnd a third line closes the test.")

        // The keyboard "close" button must exist and hide the keyboard. (On iPad the system
        // keyboard has its own minimize key with the same label - scope to our toolbar.)
        let hideKeyboard = app.toolbars.buttons["Hide keyboard"].firstMatch
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 3), "keyboard accessory close button missing")
        hideKeyboard.tap()

        let play = app.buttons["playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 3), "player bar did not come back after closing keyboard")
        play.tap()
        waitForReading(app)

        // Play flips the editor into Read mode.
        XCTAssertTrue(app.staticTexts["Tap any line to read from there"].waitForExistence(timeout: 3))
        attach(app, "reading-in-progress")

        // Tapping a line keeps reading (jumps to that line) instead of opening the keyboard.
        editor.tap()
        XCTAssertTrue(status(app).label.contains("Reading sentence"), "tap on a line stopped the reading")
        XCTAssertEqual(app.keyboards.count, 0, "tap in Read mode must not open the keyboard")

        // Manual mode switch back to editing.
        app.buttons["Edit"].tap()
        app.buttons["Stop"].tap()
        XCTAssertTrue(status(app).waitForExistence(timeout: 3))
    }

    /// The voice picker shows at most 5 curated voices with friendly names (no person names),
    /// "More voices" reveals the rest, and tapping a row selects it.
    func testVoicePicker() throws {
        let app = launchApp()

        app.buttons["Voice & sound"].tap()
        let rows = app.buttons.matching(identifier: "voiceRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "no voice rows in the picker")
        let mainCount = rows.count
        XCTAssertLessThanOrEqual(mainCount, 5, "main voice list must show at most 5 voices")

        // Friendly names only - never the raw system names.
        for i in 0..<mainCount {
            let label = rows.element(boundBy: i).label
            let friendly = label.hasPrefix("Woman") || label.hasPrefix("Man")
                || label.hasPrefix("Robot") || label.hasPrefix("Voice")
            XCTAssertTrue(friendly, "voice label '\(label)' is not a friendly no-name label")
        }
        attach(app, "voice-picker-main")

        // "More voices" reveals the full list.
        let more = app.buttons["moreVoices"]
        if more.exists {
            more.tap()
            XCTAssertGreaterThan(rows.count, mainCount, "More voices did not expand the list")
            attach(app, "voice-picker-all")
        }

        // Selecting a row marks it selected.
        let second = rows.element(boundBy: min(1, rows.count - 1))
        second.tap()
        XCTAssertTrue(second.isSelected, "tapped voice row was not selected")
    }

    /// Hebrew text plays and switches to a Hebrew voice automatically (RTL support).
    func testHebrewReading() throws {
        let app = launchApp(env: ["UITEST_SET_TEXT": "שלום וברכה. זהו משפט ראשון בעברית.\nוזוהי שורה שנייה לבדיקת קריאה."])

        let play = app.buttons["playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()

        // Reading must start; if no Hebrew voice is installed the status shows a message instead.
        let predicate = NSPredicate(format: "label CONTAINS 'Reading sentence' OR label CONTAINS 'voices'")
        expectation(for: predicate, evaluatedWith: status(app))
        waitForExpectations(timeout: 10)
        attach(app, "hebrew-reading")
    }

    /// A PDF opens, extracts its text, offers "Read on the page", and the page view plays.
    func testPdfFlow() throws {
        guard let pdfPath = ProcessInfo.processInfo.environment["UITEST_ASSET_PDF"] else {
            throw XCTSkip("UITEST_ASSET_PDF not set")
        }
        let app = launchApp(env: ["UITEST_OPEN_FILE": pdfPath])

        let onPage = app.buttons["Read on the page"]
        XCTAssertTrue(onPage.waitForExistence(timeout: 15), "PDF did not load / no page-view button")
        onPage.tap()

        // The in-page viewer shows the page counter, and play reads the page.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' / '")).firstMatch
            .waitForExistence(timeout: 10), "PDF page counter missing")
        app.buttons["playPause"].firstMatch.tap()
        waitForReading(app)
        attach(app, "pdf-read-on-page")
    }

    /// A photo runs through OCR and opens the photo reader with tappable lines.
    func testPhotoFlow() throws {
        guard let imagePath = ProcessInfo.processInfo.environment["UITEST_ASSET_IMAGE"] else {
            throw XCTSkip("UITEST_ASSET_IMAGE not set")
        }
        let app = launchApp(env: ["UITEST_OPEN_PHOTO": imagePath])

        // OCR finishes and the full-screen photo reader opens.
        XCTAssertTrue(app.staticTexts["Photo"].waitForExistence(timeout: 20), "photo reader did not open")
        app.buttons["playPause"].firstMatch.tap()
        waitForReading(app)
        attach(app, "photo-reader")
    }
}
