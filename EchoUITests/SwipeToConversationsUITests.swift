import XCTest
import UIKit

/// The phone's conversation browser has native back navigation, including an edge swipe.
@MainActor
final class SwipeToConversationsUITests: XCTestCase {
    private func launch(phoneOnly: Bool = true) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-echo.demo", "-echo.demoLibrary", "-setupDone", "YES", "-openToVoiceScreen", "NO", "-listenOnOpen", "NO",
                               "-requireBiometrics", "NO", "-transport", "chatCompletions"]
        app.launch()
        try XCTSkipIf(phoneOnly && app.windows.firstMatch.frame.width > 600, "iPad keeps the list in the sidebar")
        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 15))
        return app
    }

    // iPad exposes both a floating tab cell and its label; hidden keyboard-shortcut
    // buttons can share the label too. Target the visible control on either platform.
    private func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", name))
        let ready = NSPredicate { _, _ in matches.allElementsBoundByIndex.contains { $0.isHittable } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
    }

    private func openSavedConversation(_ app: XCUIApplication) {
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Plan the weekend hike'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        XCTAssertTrue(app.navigationBars["Plan the weekend hike"].waitForExistence(timeout: 5))
    }

    func testChatStartsWithConversationList() throws {
        let app = try launch()
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Plan the weekend hike"].exists)
    }

    func testSwipeDeletesConversationFromList() throws {
        let app = try launch(phoneOnly: false)
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Plan the weekend hike'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 2) { delete.tap() }
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5))
    }

    func testSwipeBackReturnsToConversationList() throws {
        let app = try launch()
        openSavedConversation(app)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Plan the weekend hike"].exists)
        openSavedConversation(app) // Interactive pop must reset the navigation path, too.
    }

    func testBackButtonAndNewConversation() throws {
        let app = try launch()
        openSavedConversation(app)
        app.navigationBars["Plan the weekend hike"].buttons["Conversations"].tap()
        let list = app.navigationBars["Conversations"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.buttons["New conversation"].tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New conversation"].waitForExistence(timeout: 5))
        app.navigationBars["New conversation"].buttons["Conversations"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
    }

    func testListActionsAreGroupedAndSelectionCanBeCancelled() throws {
        let app = try launch()
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 5))
        app.navigationBars["Conversations"].buttons["More"].tap()
        app.buttons["Select conversations"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Conversations"].buttons["More"].exists)
    }

    func testTabsKeepChatSeparateFromToolsAndSettings() throws {
        let app = try launch(phoneOnly: false)
        defer { XCUIDevice.shared.orientation = .portrait }
        if app.windows.firstMatch.frame.width > 600 { XCUIDevice.shared.orientation = .landscapeLeft }
        openSavedConversation(app)
        for name in ["Chat", "Cron", "Kanban", "Settings"] {
            XCTAssertTrue(tabButton(app, name).exists, "Missing tab: \(name)")
        }
        tabButton(app, "Cron").tap()
        XCTAssertTrue(app.navigationBars["Cron"].waitForExistence(timeout: 5))
        tabButton(app, "Kanban").tap()
        XCTAssertTrue(app.navigationBars["Kanban"].waitForExistence(timeout: 5))
        tabButton(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Settings"].buttons["Done"].exists)
        tabButton(app, "Chat").tap()
        XCTAssertTrue(app.navigationBars["Plan the weekend hike"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["Section"].exists)
    }


    func testIPadStartsWithPlaceholderUntilConversationIsSelected() throws {
        let app = try launch(phoneOnly: false)
        try XCTSkipIf(app.windows.firstMatch.frame.width < 600, "iPad layout check")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Select a conversation"].waitForExistence(timeout: 5))
        openSavedConversation(app)
        XCTAssertTrue(app.staticTexts["Select a conversation"].waitForNonExistence(timeout: 5))
    }

    func testIPadTabsRemainReachableAcrossOrientations() throws {
        let app = try launch(phoneOnly: false)
        try XCTSkipIf(app.windows.firstMatch.frame.width < 600, "iPad layout check")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            for name in ["Cron", "Kanban", "Settings", "Chat"] {
                let tab = tabButton(app, name)
                XCTAssertTrue(tab.waitForExistence(timeout: 5))
                XCTAssertTrue(tab.isHittable, "Tab must remain reachable after resizing")
                tab.tap()
            }
        }
    }

}
