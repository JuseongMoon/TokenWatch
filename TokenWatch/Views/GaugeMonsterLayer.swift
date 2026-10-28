//
//  GaugeMonsterLayer.swift
//  TokenWatch
//
//  게이지 바 위 몬스터(V2). 슬라임 크리터처럼 바를 가로질러 행진한다 — 완료 출현은 바 왼쪽 밖에서,
//  확률 출현은 나타난 자리에서 출발한다. 타격하면 위에서 검이 꽂히고, 처치되면 원래 그림이 흑백톤이 되고 머리 위에 엔젤링이 뜬다.
//  터치는 이 레이어가 아니라 게이지 줄 전체(UsageBar·DetailUsageRow)가 받는다 — 스프라이트 위치로 판정하지 않는다.
//

import SwiftUI
import UIKit

struct GaugeMonsterLayer: View {
    let barSize: CGSize
    let encounters: [MonsterEncounter]
    /// 세션 창 여부 — 그림을 못 찾은 몬스터를 하늘색 슬라임으로 그릴 때만 쓴다(파랑 슬라임은 종 자체가 다르다).
    let sessionWindow: Bool
    let config: MonsterConfig
    let lastHitAt: [String: Date]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 타격 뒤 검이 보이는 시간(초). 마지막 타격은 이 시간 동안 원래 색으로 멈춘 뒤 사망 애니메이션이 이어진다.
    static let swordSeconds = 0.3
    /// 사망 애니메이션 한 프레임(초).
    static let deathFrameSeconds = 0.15
    /// 처치 뒤 엔젤링 몬스터는 살아 있을 때의 절반 속도로 걷는다.
    static let ghostSpeedFactor = 0.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            ZStack(alignment: .topLeading) {
                ForEach(encounters) { encounter in
                    if let pose = pose(encounter, now: context.date) {
                        draw(pose, now: context.date)
                    }
                }
            }
            .frame(width: barSize.width, height: barSize.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 한 순간에 그릴 모습.
    struct Pose {
        let sprite: PixelSprite
        let frame: Int
        let x: CGFloat
        let sword: Bool
        let halo: Bool
    }

    private var tickPeriod: Double {
        sessionWindow ? GaugeCritterVariant.session.baseTick : GaugeCritterVariant.weekly.baseTick
    }

    /// 행진 주기. 확률 출현은 키마다 속도가 조금씩 다르다.
    private func period(for e: MonsterEncounter) -> Double {
        e.source == .completion ? tickPeriod : tickPeriod / MonsterDraw.marchSpeed(key: e.key)
    }

    /// 그 순간의 행진 위치. 완료 출현은 슬라임 행진 그대로, 확률 출현은 출현 시각에 제자리(`restX`)에서 출발한다.
    private func marchX(_ e: MonsterEncounter, at date: Date, period: Double, restX: CGFloat,
                        hop: CGFloat, width: CGFloat) -> CGFloat {
        let tick = Int(date.timeIntervalSinceReferenceDate / period)
        guard e.source != .completion else {
            return GaugeCritter.offsetX(tick: tick, hop: hop, spriteWidth: width, barWidth: barSize.width)
        }
        let spawned = Date(timeIntervalSince1970: Double(e.spawnedAtMs) / 1000)
        return GaugeCritter.offsetX(tick: tick, startTick: Int(spawned.timeIntervalSinceReferenceDate / period),
                                    startX: restX, hop: hop, spriteWidth: width, barWidth: barSize.width)
    }

    private func cell(for sprite: PixelSprite) -> CGFloat { max(0, barSize.height - 2) / CGFloat(sprite.rows) }

    /// 살아 있음 → 행진(완료는 바 왼쪽 밖에서, 확률은 나타난 자리에서 출발 — 사용자 확정 2026-10-24).
    /// 처치 → 멈춘 채 검 → 몬스터별 사망 애니메이션 → 엔젤링 몬스터:
    /// 완료 출현은 바 왼쪽 끝에서 나와 절반 속도로 계속 행진하고, 확률 출현은 사망 자리에서 절반 속도로 출발해
    /// 오른쪽 끝을 지나면 왼쪽에서 다시 나온다 — 처치 뒤 1시간 동안(사용자 확정 2026-10-26, 목록은 MonsterStore가 거른다).
    /// 모션 줄이기면 `restX`에 멈춰 있다.
    func pose(_ e: MonsterEncounter, now: Date) -> Pose? {
        let entry = config.entry(e.monsterID)
        let living = MonsterSprites.sprite(for: e.monsterID, entry: entry, sessionWindow: sessionWindow)
        let c = cell(for: living)
        let width = c * CGFloat(living.cols)
        let hop = c * CGFloat(GaugeCritter.hopCells)
        let period = self.period(for: e)
        let restX = CGFloat(e.source == .completion ? 0.72 : e.position) * max(0, barSize.width - width)

        if e.isAlive {
            let tick = Int(now.timeIntervalSinceReferenceDate / period)
            let x = reduceMotion ? restX : marchX(e, at: now, period: period, restX: restX, hop: hop, width: width)
            let sinceHit = lastHitAt[e.key].map { now.timeIntervalSince($0) }
            return Pose(sprite: living, frame: reduceMotion ? 0 : GaugeCritter.frameIndex(tick: tick), x: x,
                        sword: sinceHit.map { $0 < Self.swordSeconds } ?? false, halo: false)
        }
        guard e.state == .defeated else { return nil }
        let ghost = MonsterSprites.sprite(for: e.monsterID, entry: entry, sessionWindow: sessionWindow, defeated: true)
        if reduceMotion { return Pose(sprite: ghost, frame: 0, x: restX, sword: false, halo: true) }
        let deathDate = e.defeatedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .distantPast
        // 처치 순간의 자리 — 행진은 시각만으로 정해지므로 그 순간의 위치를 그대로 다시 구한다.
        let deathX = marchX(e, at: deathDate, period: period, restX: restX, hop: hop, width: width)

        let t = now.timeIntervalSince(deathDate)
        if t < Self.swordSeconds {
            return Pose(sprite: living, frame: 0, x: deathX, sword: true, halo: false)
        }
        let death = MonsterSprites.deathSprite(for: e.monsterID)
        let deathDuration = Double(death?.frames.count ?? 0) * Self.deathFrameSeconds
        if let death, t < Self.swordSeconds + deathDuration {
            let frame = min(death.frames.count - 1, Int((t - Self.swordSeconds) / Self.deathFrameSeconds))
            return Pose(sprite: death, frame: frame, x: deathX, sword: false, halo: false)
        }
        let ghostPeriod = period / Self.ghostSpeedFactor
        let tick = Int((t - Self.swordSeconds - deathDuration) / ghostPeriod)
        let x: CGFloat
        if e.source == .completion {
            x = GaugeCritter.offsetX(tick: tick, hop: hop, spriteWidth: width, barWidth: barSize.width)
        } else {
            x = GaugeCritter.offsetX(tick: tick, startTick: 0, startX: deathX, hop: hop, spriteWidth: width,
                                     barWidth: barSize.width)
        }
        return Pose(sprite: ghost, frame: GaugeCritter.frameIndex(tick: tick), x: x, sword: false, halo: true)
    }

    @ViewBuilder
    private func draw(_ pose: Pose, now: Date) -> some View {
        let c = cell(for: pose.sprite)
        let width = c * CGFloat(pose.sprite.cols)
        let top = barSize.height - 1 - c * CGFloat(pose.sprite.rows)
        // 몸은 바 가로 범위로 자르고(양끝 출입), 검·엔젤링은 바 위로 조금 넘쳐도 그린다.
        PixelSpriteView(sprite: pose.sprite, frameIndex: pose.frame, cell: c)
            .offset(x: pose.x, y: top)
            .frame(width: barSize.width, height: barSize.height, alignment: .topLeading)
            .clipped()
        if pose.halo, let halo = MonsterSprites.halo {
            let bob: CGFloat = reduceMotion ? 0 : CGFloat(Int(now.timeIntervalSinceReferenceDate / 0.5) % 2) * c
            overBar(halo, cell: c, x: pose.x + (width - c * CGFloat(halo.cols)) / 2,
                    y: top - c * CGFloat(halo.rows) + c - bob)
        }
        if pose.sword, let sword = MonsterSprites.sword {
            overBar(sword, cell: c, x: pose.x + (width - c * CGFloat(sword.cols)) / 2,
                    y: top - c * CGFloat(sword.rows) * 0.55)
        }
    }

    /// 바 위로 넘치는 검·엔젤링. 세로로는 넘쳐도 그리되 가로는 몸과 같은 바 범위로 잘라, 양끝에서 몸과 함께 벽 뒤로 사라진다.
    private func overBar(_ sprite: PixelSprite, cell c: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        let pad = c * CGFloat(sprite.rows)
        return PixelSpriteView(sprite: sprite, frameIndex: 0, cell: c)
            .offset(x: x, y: y + pad)
            .frame(width: barSize.width, height: barSize.height + pad * 2, alignment: .topLeading)
            .clipped()
            .offset(y: -pad)
    }
}

/// 남은 HP 하트(첫 타격 뒤에만, HP 2 이상인 몬스터). 다섯 개를 넘으면 `+n`.
struct MonsterHPHearts: View {
    let hp: Int
    let maxHP: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<min(hp, 5), id: \.self) { _ in PixelHeart(size: 8) }
            if hp > 5 {
                Text("+\(hp - 5)").font(.term(9)).foregroundStyle(Term.fg)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 게이지 줄 전체를 몬스터 타격 영역으로 만든다. 살아 있는 몬스터가 있을 때만 탭을 가로채고(카드의 상세 이동보다 우선),
/// 없으면 아무것도 하지 않는다. 접근성: "공격" 커스텀 액션과 남은 HP.
struct MonsterHitTarget: ViewModifier {
    let encounter: MonsterEncounter?
    let loc: L10n
    let onHit: (MonsterEncounter) -> Void

    func body(content: Content) -> some View {
        if let encounter {
            content
                .overlay {
                    Color.clear
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { onHit(encounter) }
                }
                .accessibilityAction(named: Text(loc.monsterAttack)) { onHit(encounter) }
                .accessibilityValue(Text(loc.monsterA11yValue(name: loc.monsterName(encounter.monsterID),
                                                              hp: encounter.hp, maxHP: encounter.maxHP)))
        } else {
            content
        }
    }
}

extension MonsterStore {
    /// 타격 + 촉각 피드백. 처치는 성공 진동, 피해는 가벼운 진동.
    func attack(_ encounter: MonsterEncounter) {
        switch hit(key: encounter.key) {
        case .damaged: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .defeated: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .ignored: break
        }
    }
}
