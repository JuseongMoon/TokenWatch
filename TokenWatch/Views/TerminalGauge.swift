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
    /// 그래픽 바의 높이.
    var height: CGFloat = 14
    /// 양 끝 대괄호 폰트 크기.
    var bracketSize: CGFloat = 13

    private var used: Double { min(1, max(0, usedFraction)) }
    private var elapsed: Double? { elapsedFraction.map { min(1, max(0, $0)) } }

    var body: some View {
        HStack(spacing: 3) {
            Text("[").font(.term(bracketSize)).foregroundStyle(Term.dim)
            bar
            Text("]").font(.term(bracketSize)).foregroundStyle(Term.dim)
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int((used * 100).rounded()))% 사용")
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                DottedTrack(color: Term.dim)                         // 트랙 ░
                BlockFill(color: fillColor)                          // 채움 █ (연속 폭)
                    .frame(width: max(0, w * used))
                    .clipped()
                if let elapsed {                                     // 마커 ╎ (정확 위치)
                    // 흰색 + 검은 테두리 — green/yellow/red 채움과 도트 트랙 어디서든 뚜렷하게.
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
                        .frame(width: 2)
                        .position(x: min(w - 1, max(1, w * elapsed)), y: geo.size.height / 2)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                }
            }
        }
        .frame(height: height)
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
