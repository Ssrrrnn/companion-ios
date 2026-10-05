import XCTest

final class CompanionUITests: XCTestCase {
    func testAvatarsAndActivityPlanAreVisible() {
        let app = launch()
        XCTAssertTrue(app.otherElements["我的头像"].firstMatch.exists || app.images["我的头像"].firstMatch.exists || app.staticTexts["我"].firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()
        let activity = app.buttons["home-activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5)); activity.tap()
        XCTAssertTrue(app.staticTexts["今天想做的事"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "今天想做的事")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["继续读一页书"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout: 5))
    }
    func testBookCanBeDeletedFromShelf() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-preview", "--books", "--reset-draft"]; app.launch()
        let book = app.staticTexts["共读示例"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.press(forDuration: 1.2)
        let delete = app.buttons["删除书籍"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["把第一本书放到这里"].waitForExistence(timeout: 5))
    }
    func testSharedCalendarShowsBothPeopleAndSavesWithoutChat() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--calendar", "--reset-draft"]
        app.launch()
        let add = app.buttons["记录我的心情"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["我们的日历"].firstMatch.exists)
        app.buttons["mood-selected-day"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["今天想慢一点，把心情留在这里。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["翻到一页喜欢的话"].exists)
        app.buttons["关闭"].tap()
        add.tap()
        // SwiftUI's vertical TextField is exposed as either TextField or TextView across iOS versions.
        let input = app.descendants(matching: .any).matching(identifier: "mood-note").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap()
        // A tap may place the caret before the existing note. Test editing without
        // assuming a caret position or deleting text that should be preserved.
        let originalNote = input.value as? String ?? ""
        input.typeText("My calendar record")
        let editedNote = input.value as? String ?? ""
        XCTAssertTrue(editedNote.contains("My calendar record"))
        XCTAssertTrue(editedNote.contains(originalNote))
        app.swipeUp()
        app.buttons["save-shared-mood"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts[editedNote].waitForExistence(timeout: 5))
        app.buttons["edit-shared-mood"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, editedNote)
        app.buttons["取消"].tap()
        app.buttons["mood-selected-day"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["聊天"].tap()
        let composer = app.textViews["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertFalse(app.staticTexts[editedNote].exists)
    }
    func testLongHistoryHomeChatNavigationPerformance() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--home", "--long-chat", "--reset-draft"]
        app.launch()
        XCTAssertTrue(app.buttons["聊天"].waitForExistence(timeout: 15))
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            app.buttons["聊天"].tap()
            XCTAssertTrue(app.textViews["chat-composer"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["我把旁边的位置留给你，什么都不用想。"].exists)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["聊天"].waitForExistence(timeout: 5))
        }
    }
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
    func testSidebarPermissionsAndListeningEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--home"]
        app.launch()
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(app.buttons["通知与健康"].waitForExistence(timeout: 3))
        app.buttons["通知与健康"].tap()
        XCTAssertTrue(app.staticTexts["消息通知"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["允许 Morrow 通知"].exists)
        app.terminate()
        app.launch()
        let listening = app.buttons["home-listening"]
        for _ in 0..<4 { if listening.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(listening.isHittable)
        listening.tap()
        XCTAssertTrue(app.staticTexts["我们的播放单"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["添加音乐或播客"].exists)
    }

    func testListeningRoomHasAccountConnectionAndDoesNotPretendPartnerOnline() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--listening", "--reset-draft"]
        app.launch()
        XCTAssertTrue(app.staticTexts["这一首，想和你一起听"].waitForExistence(timeout: 5))
        let connect = app.buttons["qq-connect"]
        for _ in 0..<3 { if connect.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(connect.isHittable)
        XCTAssertFalse(app.staticTexts["对方正在听"].exists)
        XCTAssertFalse(app.staticTexts["对方在线"].exists)
        XCTAssertTrue(app.buttons["添加音乐或播客"].exists)
    }

}
