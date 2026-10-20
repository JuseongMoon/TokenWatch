//
//  GaugeMonsterLayer.swift
//  TokenWatch
//
//  게이지 바 위 몬스터(V2). 완료 출현은 슬라임 크리터처럼 바를 가로질러 행진하고, 확률 출현은 정해진
//  자리에서 통통 뛴다. 타격하면 위에서 검이 꽂히고, 처치되면 원래 그림이 흑백톤이 되고 머리 위에 엔젤링이 뜬다.
//  터치는 이 레이어가 아니라 게이지 줄 전체(UsageBar·DetailUsageRow)가 받는다 — 스프라이트 위치로 판정하지 않는다.
//

import SwiftUI
import UIKit

struct GaugeMonsterLayer: View {
    let barSize: CGSize
    let encounters: [MonsterEncounter]
    /// 세션 창이면 슬라임을 하늘색으로(게이지 크리터와 같은 규칙).
    let sessionWindow: Bool
    let config: MonsterConfig
    let lastHitAt: [String: Date]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 검이 꽂혀 보이는 시간(초). 마지막 타격은 조금 더 오래 보인 뒤 흑백으로 바뀐다.
    static let swordSeconds = 0.25
    static let finalBlowSeconds = 0.45

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion && lastHitAt.isEmpty)) { context in
            ZStack(alignment: .topLeading) {
                ForEach(encounters) { encounter in
                    monster(encounter, now: context.date)
                }
            }
            .frame(width: barSize.width, height: barSize.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func monster(_ e: MonsterEncounter, now: Date) -> some View {
        let sinceHit = lastHitAt[e.key].map { now.timeIntervalSince($0) }
        // 마지막 타격 직후에는 아직 원래 색으로, 검과 함께 잠깐 보여 준다.
        let dying = e.state == .defeated && (sinceHit.map { $0 < Self.finalBlowSeconds } ?? false)
        let gray = e.state == .defeated && !dying
        let sprite = MonsterSprites.sprite(for: e.monsterID, entry: config.entry(e.monsterID),
                                           sessionWindow: sessionWindow, defeated: gray)
        let cell = max(0, barSize.height - 2) / CGFloat(sprite.rows)
        let width = cell * CGFloat(sprite.cols)
        let top = barSize.height - 1 - cell * CGFloat(sprite.rows)
        let period = sessionWindow ? GaugeCritterVariant.session.baseTick : GaugeCritterVariant.weekly.baseTick
        let tick = Int(now.timeIntervalSinceReferenceDate / period)
        let marching = e.source == .completion && e.isAlive && !reduceMotion
        let x: CGFloat = marching
            ? GaugeCritter.offsetX(tick: tick, hop: cell * CGFloat(GaugeCritter.hopCells), spriteWidth: width,
                                   barWidth: barSize.width)
            : CGFloat(e.source == .completion ? 0.72 : e.position) * max(0, barSize.width - width)
        let frame = (e.isAlive && !reduceMotion) ? GaugeCritter.frameIndex(tick: tick) : 0

        // 몸은 바 가로 범위로 자르고(행진 중 양끝 출입), 검·엔젤링은 바 위로 조금 넘쳐도 그린다.
        PixelSpriteView(sprite: sprite, frameIndex: frame, cell: cell)
            .offset(x: x, y: top)
            .frame(width: barSize.width, height: barSize.height, alignment: .topLeading)
            .clipped()
        if gray, let halo = MonsterSprites.halo {
            let bob: CGFloat = reduceMotion ? 0 : CGFloat(Int(now.timeIntervalSinceReferenceDate / 0.5) % 2) * cell
            PixelSpriteView(sprite: halo, frameIndex: 0, cell: cell)
                .offset(x: x + (width - cell * CGFloat(halo.cols)) / 2,
                        y: top - cell * CGFloat(halo.rows) + cell - bob)
        }
        if let sinceHit, sinceHit < (dying ? Self.finalBlowSeconds : Self.swordSeconds), let sword = MonsterSprites.sword {
            PixelSpriteView(sprite: sword, frameIndex: 0, cell: cell)
                .offset(x: x + (width - cell * CGFloat(sword.cols)) / 2,
                        y: top - cell * CGFloat(sword.rows) * 0.55)
        }
    }
}

/// 남은 HP 하트(첫 타격 뒤에만, 특수 몬스터). 다섯 개를 넘으면 `+n`.
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
