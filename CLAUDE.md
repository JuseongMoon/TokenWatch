# TokenWatch — 에이전트 작업 지침

AI 서비스 사용량을 한 화면에 모아 보여주는 iOS 앱(SwiftUI, iOS 17+). 터미널/ASCII 블랙 단일 테마.

## 빌드와 검증

```bash
# 앱 + 테스트 타깃 컴파일 (기본 검증)
xcodebuild build-for-testing -project TokenWatch.xcodeproj -scheme TokenWatch \
  -destination 'generic/platform=iOS Simulator' -quiet
```

- **검증은 빌드(컴파일)까지만 한다.** 실기기·시뮬레이터 실행, `xcodebuild test`, 앱 설치는 하지 않는다. 동작 확인이 필요하면 "무엇을 / 어디서 / 어떻게 봐주세요"로 정리해 사용자에게 넘긴다.
- **테스트는 작성하되 실행하지 않으므로 검증된 것이 아니다.** 넘길 때 그 사실을 명시한다. 구현의 초기화 시점·호출 순서를 바꾸면 그에 의존하는 테스트를 반드시 다시 읽는다(과거에 이 누락으로 단언 205개가 한꺼번에 실패한 적이 있다).
- `TokenWatch/`·`TokenWatchTests/` 아래에 `.swift` 파일을 만들면 **자동으로 타깃에 포함**된다(PBXFileSystemSynchronizedRootGroup). pbxproj를 손댈 필요 없다. 새 파일 직후 SourceKit이 "Cannot find type" 진단을 쏟아내지만 인덱싱 지연일 뿐이니 **빌드 결과로 판정**한다.
- `Info.plist`는 **프로젝트 루트**에 둔다(synchronized 폴더 안에 두면 "Multiple commands produce" 충돌).
- 기본 격리가 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`다. 모델·파서처럼 격리가 필요 없는 타입은 `nonisolated`로 선언해야 Swift 6 모드 경고를 피한다.

## 자격증명·프라이버시 (강제 사항)

- **OAuth 토큰·API 키는 기기 Keychain에만** 저장한다(`Auth/Keychain.swift`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). UserDefaults·파일·로그에 절대 쓰지 않는다.
- **분석 이벤트 파라미터에는 provider rawValue·열거 문자열·정수만** 넣는다. 계정 라벨·이메일·토큰·API 키·원문 에러 메시지·사용률 수치는 어떤 경로로도 보내지 않는다. Firebase 접점은 `Analytics/AnalyticsService.swift` 한 파일뿐이다.
- 사용량은 기기에서 각 provider로 **직접** 조회한다. 개발자 서버를 경유하지 않는다(예외: 읽기 전용 공지 피드 조회(아래), 로그인 실패 진단 보고).
- **로그인 실패 진단 보고**(`Analytics/LoginFailureReporter.swift`) — `login_fail`이 기록될 때 개발자 서버(`bot02LoginFailureReport`, 텔레그램 알림)로 한 번 POST한다(보내고 잊기, 재시도 없음). 본문은 `platform`·`appVersion`·`build`·`provider`·`authKind`·`stage`·`code` 7개 키뿐이고(서버가 그 외 키를 400으로 거절), 기기·계정 식별자·이메일·토큰·원문 에러는 싣지 않는다. 게이트는 분석과 같다(PRIVACY 토글·데모 모드·DEBUG 빌드 차단). DEBUG에서는 `-TWReportLoginFailures` 실행 인자로만 켠다. `code` 값은 `Analytics/LoginFailureCode.swift`가 유일한 소스이며 서버 분류표와 맞춰야 한다.

## 공개 저장소 규칙

이 저장소는 **public**이다.

- 커밋 전 시크릿이 섞이지 않았는지 확인한다. **이미 올렸다면 되돌리는 것으로 끝내지 말고 키를 폐기·재발급한다.**

  **예외** — Firebase 클라이언트 설정(`GoogleService-Info.plist`, `google-services.json`, `AIzaSy…`)과
  OAuth public client ID는 Google이 앱 바이너리 내장을 전제로 문서화한 **식별자**이며 비밀이 아니다.
  커밋해도 되고 재발급 대상이 아니다. 접근 통제는 Firestore 보안 규칙과 API 키의 `apiTargets`·앱 제한이 담당한다.
  **단 서비스 계정 키·Admin SDK 자격증명·서명 키는 이 예외에 해당하지 않는다.**

- **`docs/`는 `.gitignore`로 제외돼 있다 — 되돌리지 말 것.** 스토어 메타데이터(가격 전략), 계측 설계, 미출시 기능 기획, 공지 서버 계약(관리자 계정·대시보드 경로·보안규칙 구조 포함)처럼 공개 목적이 없는 자료다. 작업 폴더에는 그대로 있으니 참조는 자유롭게 하되, 새 내부 문서도 `docs/`에 두면 자동으로 비공개가 된다. 코드 주석에서 이 문서들을 **경로로 링크하지 않는다**(방문자에겐 끊어진 링크가 된다).
- `main`이 공개 기본 브랜치다. 작업은 `dev`에서 하고, `main` 병합은 해당 버전이 **출시된 뒤**에 한다(미출시 기능을 먼저 노출하지 않기 위해).
- **작업 결과는 가능하면 빨리 push한다.** 여러 세션이 같은 저장소를 만지므로 미푸시 커밋은 다른 세션의 이력 재작성에 휩쓸릴 수 있다(실제로 한 번 발생, reflog로 복구).

## 구조 요점

- `Store/AgentStore.swift` — `@MainActor @Observable` 단일 스토어. 뷰는 `@Environment(AgentStore.self)`로 받는다. `ObservableObject`는 쓰지 않는다.
- `API/` — provider별 클라이언트. 자격증명이 실리는 요청은 `APISession.shared`(ephemeral), 공개 조회는 `URLSession.shared`. 실패는 던지지 않고 `nil`/에러 열거로 돌려 마지막 정상 스냅샷을 유지한다.
- `Theme/` — `Term` 팔레트와 `.term()` 모노스페이스 폰트가 유일한 소스. 시스템 `alert`/`confirmationDialog` 대신 `TerminalKit`의 커스텀 다이얼로그를 쓴다. `List`는 쓰지 않는다(`ScrollView` + `VStack`).
- `Localization/Localization.swift` — String Catalog가 아니라 수제 `L10n`(ko/en). **터미널 크롬(`[done]`, `SETTINGS` 같은 영어 라벨)은 번역하지 않고**, 자연어 문장만 번역한다.
- `Analytics/` — `ScreenName`에 화면을 추가하면 `screenClass`도 반드시 정의한다(생략하면 시트 화면에서 `screen_name`까지 유실된다). 새 이벤트는 enum·`name`·`parameters`·`isProviderScoped` 네 곳을 함께 고친다.
- 공지 기능(`Models/Announcement.swift`, `API/AnnouncementFeedClient.swift`, `Store/AnnouncementStore.swift`, `Views/Announcement*.swift`) — 서버 피드 문서 하나를 REST로 읽는다. 팝업과 공지함은 **규칙이 다르다**(목록은 `endAt`·앱 버전 범위·"다시 열지 않기"를 무시한다). 시각은 전부 epoch 밀리초 정수.
