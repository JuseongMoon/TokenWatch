//
//  BestiaryBox.swift
//  TokenWatch
//
//  계정 화면의 몬스터 도감(4열, 아바타 격자와 같은 폭). 종마다 지금까지 잡은 수를 보여 주고, 한 번도 잡지 않은 종은
//  실루엣 안에 물음표만 둔다(이름도 감춘다). 아직 없는 몬스터 자리는 회색 네모 + 물음표로 채워 최소 8칸(4×2)을 맞춘다.
//  처치 수는 열 때마다 서버 기록을 다시 읽는다.
//

import SwiftUI

struct BestiaryBox: View {
    @Environment(MonsterStore.self) private var monsters
    let loc: L10n

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    /// 도감 최소 칸 수. 새 몬스터가 나오면 빈 자리를 차례로 채운다.
    static let minimumSlots = 8

    var body: some View {
        TerminalBox(title: "BESTIARY") {
            VStack(alignment: .leading, spacing: 12) {
                if let rows = monsters.bestiaryRows {
                    Text(loc.bestiarySummary(found: rows.filter(\.discovered).count, total: rows.count,
                                             kills: rows.reduce(0) { $0 + $1.kills }))
                        .font(.term(11, weight: .semibold)).foregroundStyle(Term.fg)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(rows) { cell($0) }
                        ForEach(0..<max(0, Self.minimumSlots - rows.count), id: \.self) { _ in comingSoonCell }
                    }
                    Text(loc.bestiaryHint).font(.term(10)).foregroundStyle(Term.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else if monsters.bestiaryFailed {
                    Text(loc.bestiaryFailed).font(.term(11)).foregroundStyle(Term.red)
                    TerminalButton(title: "[ retry ]") { Task { await monsters.refreshBestiary() } }
                } else {
                    HStack(spacing: 8) {
                        TerminalSpinner(color: Term.cyan, size: 12)
                        Text(loc.bestiaryLoading).font(.term(11)).foregroundStyle(Term.dim)
                    }
                }
            }
        }
        .task { await monsters.refreshBestiary() }
    }

    private func cell(_ row: BestiaryRow) -> some View {
        let sprite = MonsterSprites.sprite(for: row.entry.id, entry: row.entry, sessionWindow: false)
        return VStack(spacing: 6) {
            Group {
                if row.discovered {
                    AnimatedPixelSpriteView(sprite: sprite, cell: 4, tick: 0.5)
                } else {
                    PixelSpriteView(sprite: sprite, frameIndex: 0, cell: 4, flatColor: Term.dim.opacity(0.45))
                        .overlay {
                            Text("?").font(.term(15, weight: .bold)).foregroundStyle(Term.fg)
                        }
                }
            }
            .frame(height: 40, alignment: .bottom)
            Text(row.discovered ? loc.monsterName(row.entry.id) : "???")
                .font(.term(11, weight: .semibold))
                .foregroundStyle(row.discovered ? Term.fg : Term.dim)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(row.discovered ? "×\(row.kills)" : "—")
                .font(.term(11)).monospacedDigit()
                .foregroundStyle(row.discovered ? Term.green : Term.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .overlay(Rectangle().stroke(Term.dim.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.discovered ? loc.bestiaryA11y(name: loc.monsterName(row.entry.id), kills: row.kills)
                                           : loc.bestiaryUnknown)
    }

    /// 아직 없는 몬스터 자리 — 몬스터 실루엣과 같은 크기의 회색 네모 + 물음표.
    private var comingSoonCell: some View {
        VStack(spacing: 6) {
            Rectangle().fill(Term.dim.opacity(0.45))
                .frame(width: 32, height: 32)
                .overlay { Text("?").font(.term(15, weight: .bold)).foregroundStyle(Term.fg) }
                .frame(height: 40, alignment: .bottom)
            Text("???").font(.term(11, weight: .semibold)).foregroundStyle(Term.dim).lineLimit(1)
            Text("—").font(.term(11)).foregroundStyle(Term.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .overlay(Rectangle().stroke(Term.dim.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.bestiaryComingSoon)
    }
}
