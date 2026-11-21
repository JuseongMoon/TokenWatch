//
//  TerminalGauge.swift
//  TokenWatch
//
//  Fake ASCII 게이지: 겉보기엔 `[▓▓▓░░░]` 블록바지만 실제로는 Canvas로 그린 그래픽이라
//  1~100% 어떤 비율도 "칸 수 제한 없이" 연속으로 정확히 표현한다.
//  - 트랙(░) = 도트 해치 패턴, 채움(█) = 상태색 solid 블록(연속), 둘 다 Canvas 렌더.
//  - 마커(╎, 현재 시각) = 그 위 오버레이 세로선으로 정확한 위치 표시.
//  - 양 끝 `[` `]`만 실제 문자로 둔다.
//  - 몬스터(V2) = 맨 위 오버레이(`GaugeMonsterLayer`). 바 위에는 넘겨받은 몬스터(잡을 수 있는 것)만 그리고,
//    장식용 크리터는 두지 않는다 — 100%여도 몬스터가 없으면 아무것도 그리지 않는다.
//

import SwiftUI

struct TerminalGauge: View {
    /// 0...1 사용 비율.
    let usedFraction: Double
    /// 채움(█) 색 — 잔여율 상태색.
    let fillColor: Color
    /// 0...1, 창 안에서 현재 시각의 위치. nil이면 마커 미표시.
    let elapsedFraction: Double?
    /// 마커가 "멈춤"(업무시간 밖) 상태인지 — true면 흐릿하게(꺼진 듯) 그려 정지 느낌을 준다.
    var markerPaused: Bool = false
    /// 채움 방향. false(기본)=구독형(채움=사용량). true=충전형(채움=남은 잔액, 역방향).
    /// usedFraction엔 두 경우 모두 "소비율"이 들어오고, 채움 폭만 뒤집힌다.
    var fillsRemaining: Bool = false
    /// 그래픽 바의 높이.
    var height: CGFloat = 14
    /// 양 끝 대괄호 폰트 크기.
    var bracketSize: CGFloat = 13
    /// 창 종류(세션/그 밖) — 몬스터 행진 속도와, 그림을 못 찾은 몬스터의 대체 슬라임 색에 쓴다.
    var critterVariant: GaugeCritterVariant = .weekly
    /// 이 창의 몬스터(V2). 바 위에는 이 목록만 그린다 — 비어 있으면 아무것도 그리지 않는다.
    var monsters: [MonsterEncounter] = []
    var monsterHits: [String: Date] = [:]
    var monsterConfig: MonsterConfig = .bundledDefault

    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    /// 게이지 위 몬스터 표시 여부(설정 DISPLAY). 기본 켜짐.
    @AppStorage("tokenwatch.gaugeCritter") private var gaugeCritter = true
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    private var used: Double { min(1, max(0, usedFraction)) }
    private var elapsed: Double? { elapsedFraction.map { min(1, max(0, $0)) } }
    /// 실제 채움 폭 비율 — 구독형은 사용량, 충전형은 남은 잔액.
    private var fill: Double { Self.fillFraction(used: used, fillsRemaining: fillsRemaining) }

    /// 채움 비율(0...1). 구독형은 사용량(used), 충전형(fillsRemaining)은 남은 잔액(1−used)을 그린다.
    /// (뷰 밖 순수 함수 — 방향 반전 로직을 단위 테스트로 고정한다.)
    static func fillFraction(used: Double, fillsRemaining: Bool) -> Double {
        let u = min(1, max(0, used))
        return fillsRemaining ? 1 - u : u
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("[").font(.term(bracketSize)).foregroundStyle(Term.dim)
            bar
            Text("]").font(.term(bracketSize)).foregroundStyle(Term.dim)
        }
        .accessibilityElement()
        .accessibilityLabel(fillsRemaining
            ? loc.a11yRemaining(Int(((1 - used) * 100).rounded()))
            : loc.a11yUsed(Int((used * 100).rounded())))
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                DottedTrack(color: Term.dim)                         // 트랙 ░
                BlockFill(color: fillColor)                          // 채움 █ (연속 폭)
                    .frame(width: max(0, w * fill))
                    .clipped()
                if let elapsed {                                     // 마커 ╎ (정확 위치)
                    // 흐름: 흰색 + 검은 테두리 + glow — 어디서든 뚜렷하게.
                    // 멈춤(업무시간 밖): dim 회색 + glow 제거 + 낮은 투명도 — "꺼진 듯" 정지 느낌.
                    Rectangle()
                        .fill(markerPaused ? Term.dim : Color.white)
                        .overlay(Rectangle().stroke(Color.black.opacity(markerPaused ? 0.2 : 0.45), lineWidth: 0.5))
                        .frame(width: 2)
                        .opacity(markerPaused ? 0.5 : 1)
                        .position(x: min(w - 1, max(1, w * elapsed)), y: geo.size.height / 2)
                        .shadow(color: .black.opacity(markerPaused ? 0 : 0.5), radius: markerPaused ? 0 : 1.5)
                }
                if gaugeCritter, !monsters.isEmpty {                 // 몬스터(V2)
                    GaugeMonsterLayer(barSize: geo.size, encounters: monsters,
                                      sessionWindow: critterVariant == .session,
                                      config: monsterConfig, lastHitAt: monsterHits)
                }
            }
        }
        .frame(height: height)
    }
}

/// 게이지 창 종류 — 몬스터 행진 속도가 다르다.
/// - weekly: 가장 긴 세션(주간)과 그 밖의 창. 약간 느리게.
/// - session: 일반 세션. 약간 빠르게(weekly의 약 1.3배 속도).
enum GaugeCritterVariant {
    case weekly
    case session

    /// 창 종류 매핑 — session만 빠르게, 나머지(주간/충전형 등)는 weekly.
    init(kind: WindowKind) { self = (kind == .session) ? .session : .weekly }

    /// 기본 프레임/전진 주기(초). 값이 작을수록 빠르다. 0.25 기준을 기하평균으로 벌려
    /// session이 weekly보다 약 1.3배 빠르게: 0.285 / 0.219 ≈ 1.30.
    var baseTick: Double {
        switch self {
        case .weekly:  return 0.285   // 기준보다 살짝 느림
        case .session: return 0.219   // 기준보다 살짝 빠름
        }
    }
}

/// 게이지 위 몬스터 행진의 산수(순수 함수 — 단위 테스트 대상). 그리기는 `GaugeMonsterLayer`가 한다.
/// 도약 프레임에 한 걸음 전진하고 착지 프레임에 제자리에서 눌린다 — 통통 튀는 호핑.
enum GaugeCritter {
    /// 도약 한 번에 전진하는 스프라이트 픽셀 칸 수.
    static let hopCells = 4

    /// 짝수 틱 = 착지(0), 홀수 틱 = 도약(1).
    static func frameIndex(tick: Int) -> Int { abs(tick) % 2 }

    /// 완료 출현 몬스터(와 그 엔젤링)의 행진: 도약 틱에만 한 걸음 나아간 x(스프라이트 왼끝).
    /// 완전히 숨은 왼쪽 밖(-spriteWidth)에서 출발해 오른끝을 다 지나면 다시 왼쪽 밖에서 재등장(랩어라운드).
    static func offsetX(tick: Int, hop: CGFloat, spriteWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
        guard hop > 0, barWidth > 0 else { return -spriteWidth }
        let hopsPerCross = Int(((barWidth + spriteWidth) / hop).rounded(.up))
        let hopIndex = (abs(tick) + 1) / 2 % max(1, hopsPerCross)
        return CGFloat(hopIndex) * hop - spriteWidth
    }

    /// 중간에 나온 몬스터(확률 출현)의 행진: `startTick`에 `startX`(hop 격자로 맞춤)에서 출발해
    /// 위와 같은 리듬(홀수 틱에 전진)으로 걷고, 오른끝을 지나면 왼쪽 밖에서 재등장한다.
    /// 출발 틱보다 이른 틱(시계 차)은 출발점에 둔다. 출발 틱 기준이라 시계 기준점과 무관하다.
    static func offsetX(tick: Int, startTick: Int, startX: CGFloat, hop: CGFloat,
                        spriteWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
        guard hop > 0, barWidth > 0 else { return -spriteWidth }
        let hopsPerCross = max(1, Int(((barWidth + spriteWidth) / hop).rounded(.up)))
        let startHop = Int(((startX + spriteWidth) / hop).rounded())
        let hops = (max(tick, startTick) + 1) / 2 - (startTick + 1) / 2
        let hopIndex = ((startHop + hops) % hopsPerCross + hopsPerCross) % hopsPerCross
        return CGFloat(hopIndex) * hop - spriteWidth
    }
}

/// 트랙(░) — 살짝 어긋난 도트 격자로 아스키 해치 질감을 낸다.
private struct DottedTrack: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let dot: CGFloat = 1.2
            let step: CGFloat = 2
            var row = 0
            var y: CGFloat = 1
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 1 : 1 + step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)),
                             with: .color(color.opacity(0.7)))
                    x += step
                }
                y += step
                row += 1
            }
        }
    }
}

/// 채움(█) — 상태색 solid 블록. 세로 구분선 없이 연속으로 채워, 값이 오를 때
/// 칸 단위로 "끊겨" 보이지 않고 매끄럽게 이어진다.
private struct BlockFill: View {
    let color: Color
    var body: some View {
        Rectangle().fill(color)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        // 1~100% 연속 표현 확인 (칸 수 제한 없음).
        ForEach([1, 2, 27, 50, 88, 100], id: \.self) { pct in
            TerminalGauge(usedFraction: Double(pct) / 100,
                          fillColor: Term.statusColor(remainingPercent: Double(100 - pct)),
                          elapsedFraction: 0.5, height: 14, bracketSize: 13)
        }
        // 상세용 큰 바 + 마커가 채움보다 앞.
        TerminalGauge(usedFraction: 0.52, fillColor: Term.green, elapsedFraction: 0.7,
                      height: 20, bracketSize: 15)
    }
    .padding()
    .background(Term.bg)
}
