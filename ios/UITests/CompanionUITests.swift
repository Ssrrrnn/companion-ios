import XCTest

final class CompanionUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--reset-draft"]
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
        let message = app.staticTexts["过来，让我看看你。"]
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
        let message = app.staticTexts["过来，让我看看你。"]
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
    func testSentenceBubblesAndReturnSend() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["忙完了？"].exists)
        XCTAssertTrue(app.staticTexts["过来，让我看看你。"].exists)
        XCTAssertTrue(app.staticTexts["那就赖着。"].exists)
        XCTAssertFalse(app.staticTexts["忙完了？过来，让我看看你。"].exists)
        XCTAssertFalse(app.buttons["发送信息"].exists)
        let input = app.textViews["chat-composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Return sends this once\n")
        XCTAssertTrue(app.staticTexts["Return sends this once"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "")
        XCTAssertFalse(app.staticTexts["Return sends this once\n"].exists)
    }
    func testEdgeBackReturnsToPreviousScreen() {
        let app = launch()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        let chat = app.buttons["聊天"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        app.buttons["珍藏"].tap()
        chat.tap()
        XCTAssertTrue(app.buttons["搜索聊天"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.45)))
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["留给我们的"].exists)
    }
    func testHomeReaderPreparesDraftWithoutSending() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--home", "--reset-draft"]
        app.launch()
        let reading = app.buttons["home-reading"]
        XCTAssertTrue(reading.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["接着聊 →"].exists)
        reading.tap()
        let example = app.buttons["add-preview-book"]
        XCTAssertTrue(example.waitForExistence(timeout: 5)); example.tap()
        let book = app.staticTexts["共读示例"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        let share = app.buttons["share-reading"]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        let toDraft = app.buttons["reading-to-draft"]
        XCTAssertTrue(toDraft.waitForExistence(timeout: 5)); toDraft.tap()
        let input = app.textViews["chat-composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue((input.value as? String ?? "").contains("一起读《共读示例》"))
        XCTAssertFalse(app.staticTexts["发送中"].exists)
    }
}
