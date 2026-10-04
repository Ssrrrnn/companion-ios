import XCTest

final class CompanionUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["搜索聊天"].waitForExistence(timeout: 15))
        return app
    }
    func testSearchFiltersConversation() {
        let app = launch()
        app.buttons["搜索聊天"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("zzzz")
        let result = app.buttons["chat-search-result-preview:2"]
        let disappears = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [disappears], timeout: 5), .completed)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(result.waitForExistence(timeout: 5))
    }
    func testQuoteReplyAndCancel() {
        let app = launch()
        let message = app.staticTexts["忙完了？过来，让我看看你。"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 1.2)
        let reply = app.buttons["回复这句"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        XCTAssertTrue(app.buttons["取消引用"].waitForExistence(timeout: 5))
        app.buttons["取消引用"].tap()
        XCTAssertFalse(app.buttons["取消引用"].exists)
    }
    func testLocalFavoritePersistsOnRelaunch() {
        let app = launch()
        let message = app.staticTexts["忙完了？过来，让我看看你。"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 1.2)
        let save = app.buttons["收藏这句"]
        if save.waitForExistence(timeout: 3) { save.tap() }
        else {
            app.buttons["取消收藏"].tap()
            message.press(forDuration: 1.2); app.buttons["收藏这句"].tap()
        }
        app.terminate(); app.launch()
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 5))
    }
}
