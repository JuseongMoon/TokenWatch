//
//  AddAgentFlowUITests.swift
//  TokenWatchUITests
//
//  실제 앱을 구동해 add-agent 플로우를 end-to-end로 검증한다:
//  메인 → 추가 → 7개 provider 목록 → apiKey 화면 → 가짜 키로 실제 네트워크 호출 → 카드 등장.
//  (성공 값 매핑은 실제 유효 키가 필요하므로, 여기서는 플로우와 에러 경로까지 확인한다.)
//

import XCTest

final class AddAgentFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddAgentFlowShowsProvidersAndApiKeyScreen() throws {
        let app = XCUIApplication()
        app.launch()

        // 1) 메인 화면 → [ + ADD AGENT ] 탭
        let addButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'ADD AGENT'")).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "메인 화면에 추가 버튼이 보여야 함")
        addButton.tap()

        // 2) provider 선택 목록이 뜬다
        XCTAssertTrue(app.staticTexts["select a service to login"].waitForExistence(timeout: 5),
                      "provider 선택 화면이 떠야 함")

        // 3) 지원 provider 7개가 전부 목록에 존재
        for name in ["claude", "codex", "copilot", "openrouter",
                     "deepseek", "poe", "elevenlabs"] {
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 3),
                          "\(name) 행이 목록에 있어야 함")
        }
        attach(app, "01-provider-list")

        // 4) elevenlabs(apiKey) 탭 → 키 입력 화면 + 필드
        app.staticTexts["elevenlabs"].tap()
        let keyField = app.textFields.firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 5), "apiKey 입력 필드가 나와야 함")
        keyField.tap()
        keyField.typeText("invalid_test_key_for_ui")
        attach(app, "02-apikey-screen")

        // 5) [ ADD ] → 시트 닫힘 + 실제 네트워크 호출 → ElevenLabs 카드 등장
        app.buttons["[ ADD ]"].tap()
        let card = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'ELEVENLABS'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "메인에 ElevenLabs 카드가 나타나야 함")

        // 네트워크(401) 결과가 카드에 반영될 시간을 준 뒤 최종 상태 캡처.
        _ = app.staticTexts["no usage data"].waitForExistence(timeout: 8)
        attach(app, "03-card-after-network")
    }

    @MainActor
    func testDeviceFlowScreenOpens() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'ADD AGENT'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["select a service to login"].waitForExistence(timeout: 5))

        // copilot(device flow) → user code 요청 화면
        app.staticTexts["copilot"].tap()
        let requesting = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'requesting' OR label CONTAINS[c] '코드'")).firstMatch
        XCTAssertTrue(requesting.waitForExistence(timeout: 8), "device flow 화면이 떠야 함")
        attach(app, "04-device-flow")
    }

    // MARK: 스크린샷 첨부

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
