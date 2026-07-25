//
//  TerminalGauge.swift
//  TokenWatch
//
//  Fake ASCII 게이지: 겉보기엔 `[▓▓▓░░░]` 블록바지만 실제로는 Canvas로 그린 그래픽이라
//  1~100% 어떤 비율도 "칸 수 제한 없이" 연속으로 정확히 표현한다.
//  - 트랙(░) = 도트 해치 패턴, 채움(█) = 상태색 solid 블록(연속), 둘 다 Canvas 렌더.
//  - 마커(╎, 현재 시각) = 그 위 오버레이 세로선으로 정확한 위치 표시.
//  - 양 끝 `[` `]`만 실제 문자로 둔다.
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
    /// usedFraction엔 두 경우 모두 "소비율"이 들어오므로, 슬라임 트리거(used≥0.995)는 동일하게 동작한다.
    var fillsRemaining: Bool = false
    /// 그래픽 바의 높이.
    var height: CGFloat = 14
    /// 양 끝 대괄호 폰트 크기.
    var bracketSize: CGFloat = 13
    /// 소진 게이지 위 슬라임 변종 — 창 종류에 따라 색·속도가 다르다. 기본은 weekly(기존 초록).
    var critterVariant: GaugeCritterVariant = .weekly

    @AppStorage(appLanguageStorageKey) private var appLanguage: AppLanguage = .system
    /// 소진 게이지 위 픽셀 슬라임 표시 여부(설정 DISPLAY). 기본 켜짐.
    @AppStorage("tokenwatch.gaugeCritter") private var gaugeCritter = true
    private var loc: L10n { L10n(lang: appLanguage.resolved) }

    private var used: Double { min(1, max(0, usedFraction)) }
    private var elapsed: Double? { elapsedFraction.map { min(1, max(0, $0)) } }
    /// 실제 채움 폭 비율 — 구독형은 사용량, 충전형은 남은 잔액.
    private var fill: Double { Self.fillFraction(used: used, fillsRemaining: fillsRemaining) }
    /// 슬라임 표시 조건 — 설정 on & 소진(≈100%). 이 값이 바뀔 때만 등장/소멸 페이드가 돈다.
    private var showCritter: Bool { gaugeCritter && used >= GaugeCritter.threshold }

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
                Group {                                              // 소진: 슬라임 행진
                    if showCritter {
                        GaugeCritter(barSize: geo.size, variant: critterVariant)
                            .transition(.steppedFade)                // 등장/소멸 8단계 페이드
                    }
                }
                // 스코프를 슬라임에만 한정 → 리셋 시 채움 바가 함께 애니메이션되지 않는다.
                .animation(GaugeCritter.fadeAnimation, value: showCritter)
            }
        }
        .frame(height: height)
    }
}

/// 게이지 위 슬라임 변종 — 창 종류에 따라 색과 애니메이션 속도가 다르다.
/// - weekly: 가장 긴 세션(주간). 기존 초록 슬라임, 약간 느리게.
/// - session: 일반 세션. 하늘색 슬라임, 약간 빠르게(초록의 약 1.3배 속도).
enum GaugeCritterVariant {
    case weekly
    case session

    /// 창 종류 매핑 — session만 하늘색(빠름), 나머지(주간/충전형 등)는 기존 초록.
    init(kind: WindowKind) { self = (kind == .session) ? .session : .weekly }

    var sprite: PixelSprite {
        switch self {
        case .weekly:  return .slime
        case .session: return .slimeSky
        }
    }

    /// 기본 프레임/전진 주기(초). 값이 작을수록 빠르다. 기존 0.25 기준을 기하평균으로 벌려
    /// session(하늘색)이 weekly(초록)보다 약 1.3배 빠르게: 0.285 / 0.219 ≈ 1.30.
    var baseTick: Double {
        switch self {
        case .weekly:  return 0.285   // 초록: 기준보다 살짝 느림
        case .session: return 0.219   // 하늘색: 기준보다 살짝 빠름
        }
    }
}

/// 100% 소진된 바를 무대 삼아 행진하는 픽셀 크리터(슬라임).
/// 도약 프레임에 한 걸음 전진하고 착지 프레임에 제자리에서 눌린다 — 통통 튀는 호핑.
/// TimelineView 기반 무상태: 시각에서 위치·프레임을 순수 계산한다(BlinkingCursor와 같은 패턴).
struct GaugeCritter: View {
    let barSize: CGSize
    var variant: GaugeCritterVariant = .weekly

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 등장(스폰) 시 1회 뽑는 개별 속도 배율(±5% → 슬라임 간 최대 ~10% 속도차). 무상태 뷰라
    /// @State 기본값이 슬라임이 새로 나타날 때마다 새로 추첨된다 → 제각각 통통 튄다.
    @State private var speedFactor = Double.random(in: 0.95...1.05)

    /// 슬라임 등장 사용률(0...1). 표시 반올림상 100%가 되는 지점과 맞춘다.
    static let threshold = 0.995
    /// 도약 한 번에 전진하는 스프라이트 픽셀 칸 수.
    static let hopCells = 4

    private var sprite: PixelSprite { variant.sprite }
    /// 이 슬라임의 프레임/전진 주기(초) — 변종 기본값에 스폰 시 속도 지터를 적용(빠를수록 짧다).
    private var period: Double { variant.baseTick / speedFactor }

    /// 픽셀 한 칸 pt — 스프라이트가 바 안에서 위아래 1pt씩 여유를 갖는 크기.
    private var cell: CGFloat { max(0, barSize.height - 2) / CGFloat(sprite.rows) }

    var body: some View {
        if reduceMotion {
            place(frameIndex: 0, x: barSize.width * 0.6)     // 모션 최소화: 제자리 슬라임
        } else {
            TimelineView(.periodic(from: .now, by: period)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / period)
                let x = Self.offsetX(tick: tick,
                                     hop: cell * CGFloat(Self.hopCells),
                                     spriteWidth: cell * CGFloat(sprite.cols),
                                     barWidth: barSize.width)
                place(frameIndex: Self.frameIndex(tick: tick), x: x)
            }
        }
    }

    /// 스프라이트를 바 안 왼끝 기준 x 위치에 바닥 정렬로 놓고, 바 밖으로 나가는 부분은 자른다.
    private func place(frameIndex: Int, x: CGFloat) -> some View {
        PixelSpriteView(sprite: sprite, frameIndex: frameIndex, cell: cell)
            .offset(x: x, y: barSize.height - 1 - cell * CGFloat(sprite.rows))
            .frame(width: barSize.width, height: barSize.height, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: 행진 산수(순수 함수 — 단위 테스트 대상)

    /// 짝수 틱 = 착지(0), 홀수 틱 = 도약(1).
    static func frameIndex(tick: Int) -> Int { abs(tick) % 2 }

    // MARK: 등장/소멸 페이드(맨 처음 생길 때·리셋으로 사라질 때)

    /// 페이드 단계 수. 불투명도를 이 칸 수만큼 계단식으로만 밟는다.
    static let opacitySteps = 8
    /// 등장/소멸 페이드 시간. 8단계가 고르게 밟히도록 리니어로 재생한다.
    static let fadeAnimation: Animation = .linear(duration: 0.6)

    /// 진행도 t(0...1)를 opacitySteps단계로 양자화한 불투명도.
    /// 리니어가 아니라 뚝뚝 끊기는 계단(0, 1/8, …, 7/8, 1)만 나타난다.
    static func steppedOpacity(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        return (clamped * Double(opacitySteps)).rounded(.down) / Double(opacitySteps)
    }

    /// 도약 틱에만 한 걸음 나아간 x(스프라이트 왼끝). 완전히 숨은 왼쪽 밖(-spriteWidth)에서
    /// 출발해 오른끝을 다 지나면 다시 왼쪽 밖에서 재등장(랩어라운드).
    static func offsetX(tick: Int, hop: CGFloat, spriteWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
        guard hop > 0, barWidth > 0 else { return -spriteWidth }
        let hopsPerCross = Int(((barWidth + spriteWidth) / hop).rounded(.up))
        let hopIndex = (abs(tick) + 1) / 2 % max(1, hopsPerCross)
        return CGFloat(hopIndex) * hop - spriteWidth
    }
}

/// 불투명도를 8단계로 양자화해 적용하는 애니메이터블 모디파이어.
/// 진행도(animatableData)는 SwiftUI가 연속 보간하지만, 화면 불투명도는 계단만 밟는다.
private struct SteppedOpacityModifier: ViewModifier, Animatable {
    var progress: Double     // 0...1 — 애니메이션이 연속 보간
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content.opacity(GaugeCritter.steppedOpacity(progress))
    }
}

private extension AnyTransition {
    /// 등장(0→1)·소멸(1→0) 시 불투명도가 8단계로 뚝뚝 끊겨 나타나고 사라지는 페이드.
    static var steppedFade: AnyTransition {
        .modifier(active: SteppedOpacityModifier(progress: 0),
                  identity: SteppedOpacityModifier(progress: 1))
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
