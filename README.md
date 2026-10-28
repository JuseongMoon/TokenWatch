# TokenWatch

여러 AI 서비스에 흩어진 **사용량과 잔여 크레딧을 한 화면에서 확인**하는 iOS 앱입니다.
Claude의 5시간 세션 창이 언제 초기화되는지, ElevenLabs 크레딧이 얼마나 남았는지를
각 서비스 대시보드를 돌아다니지 않고 봅니다.
2.0.0부터는 사용량 게이지에 나타나는 몬스터를 잡아 주간·전체 순위에 오르는
선택형 게임 레이어가 있습니다.

- 플랫폼: iOS 17.0+ (SwiftUI)
- 언어: 한국어 / 영어
- Android 구현: [TokenWatchAndroid](https://github.com/JuseongMoon/TokenWatchAndroid)

## 지원 서비스 10종

| 인증 방식 | 서비스 |
| --- | --- |
| OAuth (PKCE) | Claude, Codex, Grok |
| 승인 페이지 + 토큰 폴링 | Copilot, Cursor |
| API 키 | Kimi, OpenRouter, DeepSeek, Poe, ElevenLabs |

서비스마다 사용량의 **성격이 다릅니다.** 구독형은 "기간 내 몇 % 소진"이고,
충전형은 "잔액이 얼마"입니다. `AgentProvider`가 `authKind`와 `usageCategory`를
메타데이터로 들고 있어, 새 서비스는 클라이언트 하나만 추가하면 UI가 그대로 동작합니다.

## 기술적으로 다룬 것

**1. 업무시간만 흐르는 주간 게이지**
주간 사용량 창은 7일이지만, 실제로 토큰을 쓰는 건 업무시간뿐입니다.
벽시계 기준 "현재 위치" 마커는 밤새 혼자 전진해 아침에 보면 이미 한참 가 있습니다.

그래서 마커 위치를 **업무시간 기준으로 재정의**했습니다.

```
마커 위치 = (창시작~현재 사이 업무시간) / (창시작~창끝 사이 총 업무시간)
```

스케줄은 7일 × 24시간 = 168개 on/off 슬롯이고, `@AppStorage`에 168자 "0/1"
문자열로 저장합니다. 업무시간이 아닌 구간에서는 분자가 늘지 않아 마커가 멈춥니다.
→ [`Models/WorkHoursSchedule.swift`](TokenWatch/Models/WorkHoursSchedule.swift)

**2. 부수효과 없는 순수 정책 모듈 — 앱과 테스트가 같은 코드를 공유**
"리셋을 감지했다"와 "알림을 보낸다"를 분리했습니다.
`ResetDetector`는 직전 관측(baseline)과 현재 관측만 받아 이벤트를 반환하는 순수 함수이고,
발송은 `AgentStore`가 합니다. 덕분에 시간·네트워크·알림 권한 없이 단위 테스트가 됩니다.

판정도 단순 비교가 아닙니다. **정시 리셋은 예약형 로컬 알림이 이미 담당**하므로
중복 알림을 막기 위해 억제하고, **예정보다 이른 "서프라이즈 리셋"만** 즉시 발화합니다.
→ [`Notifications/ResetDetector.swift`](TokenWatch/Notifications/ResetDetector.swift),
[`Notifications/ResetSchedulePolicy.swift`](TokenWatch/Notifications/ResetSchedulePolicy.swift)

**3. actor 기반 rate limit 게이트**
Claude의 사용량 엔드포인트는 429를 공격적으로 돌려줍니다.
429를 만나면 `Retry-After`(없으면 5분)만큼 **해당 에이전트만** 차단하고,
그동안 마지막 성공 스냅샷을 계속 표시합니다. 화면이 비거나 에러로 덮이지 않습니다.
동시 갱신이 상태를 깨지 않도록 `actor`로 격리했습니다.
→ [`API/RateLimitGate.swift`](TokenWatch/API/RateLimitGate.swift)

**4. 자격증명이 디스크에 남지 않게**
토큰과 API 키가 실리는 요청은 **ephemeral `URLSession`** 전용으로 분리했습니다.
응답 캐시·쿠키·자격증명이 전부 메모리에만 있다가 사라집니다.
민감하지 않은 공개 상태 페이지 조회는 공유 세션을 그대로 씁니다.
토큰 자체는 Keychain에만 저장하고, 사용량 조회를 중계하는 서버는 두지 않았습니다 — 앱이
각 서비스의 엔드포인트를 직접 호출합니다. 개발자 서버와 오가는 것은 읽기 전용 공지 피드 조회,
설정에서 끌 수 있는 로그인 실패 진단 보고(오류 코드만 전송), 그리고 선택 사항인 앱 계정과
몬스터 기록뿐입니다. 몬스터 서버에는 서비스 종류·창 이름·리셋 구간 같은 출현 판정 값만 보내고,
사용률 수치와 연결한 AI 계정 정보는 보내지 않습니다.
→ [`API/APISession.swift`](TokenWatch/API/APISession.swift), [`Auth/Keychain.swift`](TokenWatch/Auth/Keychain.swift)

**5. 선택형 몬스터 사냥 — 판정은 서버, 추첨은 결정적으로**
게이지를 탭해 몬스터를 잡고, 점수로 주간·전체 상위 10 순위에 오릅니다. 로그인(Apple·Google)은
선택이며, 로그인한 사용자의 출현·처치·점수는 서버(Cloud Functions)가 판정합니다.
앱 계정 인증에만 Firebase Auth SDK를 쓰고, 프로필·몬스터 호출과 순위 조회는 REST로 직접 합니다.
로그인하지 않은 사용자는 같은 규칙을 기기에서 적용하고, 추첨은 키의 해시에서 뽑아
새로고침을 반복해도 결과가 같습니다.
→ [`Monster/MonsterDraw.swift`](TokenWatch/Monster/MonsterDraw.swift), [`Monster/MonsterAPIClient.swift`](TokenWatch/Monster/MonsterAPIClient.swift)

**6. 터미널 감성 UI**
사용량을 막대가 아니라 문자 게이지로 그립니다.
`TerminalKit`, `PixelSprite`로 모노스페이스 기반 렌더링을 직접 구성했습니다.

## 구조

```
TokenWatch/
├── API/            서비스별 사용량 클라이언트 · 디스패처 · rate limit 게이트 · 전용 세션
├── Auth/           OAuth(PKCE · device flow) · Keychain · JWT · 토큰 저장소
├── Account/        선택형 앱 계정(Apple · Google 로그인) · 프로필
├── Monster/        몬스터 출현 · 처치 · 도감 · 순위 클라이언트
├── Models/         Agent 메타데이터 · 사용량 창 · 업무시간 스케줄 · 데모 데이터
├── Notifications/  리셋 감지 · 예약 정책 · 백그라운드 새로고침
├── Analytics/      이벤트 정의와 전송
├── Store/          AgentStore (상태 조합과 부수효과)
├── Views/          카드 · 상세 · 게이지 · 설정 · 업무시간 편집기
└── Theme/          터미널 테마 · 픽셀 스프라이트
```

정책은 순수 모듈로, 부수효과는 `AgentStore`로 몰아둔 구조입니다.

## 기술 스택

SwiftUI · Swift Concurrency(actor, async/await) · Keychain Services ·
ASWebAuthenticationSession · UserNotifications · BackgroundTasks ·
Firebase Auth(앱 계정) · Cloud Functions · Firestore REST
OAuth와 JWT 파싱은 직접 구현했습니다.

## 실행 방법

```bash
git clone https://github.com/JuseongMoon/TokenWatch.git
cd TokenWatch
open TokenWatch.xcodeproj
```

별도 설정 없이 빌드됩니다. 로그인 없이 전체 UI를 둘러보는 **데모 모드**가 있고,
실제 사용량을 보려면 앱 안에서 각 서비스에 로그인하거나 API 키를 입력합니다.
입력한 자격증명은 기기 Keychain에만 저장됩니다.

## 라이선스

MIT License. 자세한 내용은 [LICENSE](LICENSE)를 참고하세요.
