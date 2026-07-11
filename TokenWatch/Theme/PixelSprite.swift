//
//  PixelSprite.swift
//  TokenWatch
//
//  2프레임 픽셀아트 스프라이트: 정수 격자 비트맵 + 값→색 팔레트, 그리고 Canvas 렌더러.
//  100% 소진 게이지 위를 행진하는 크리터(슬라임 등)의 그림 리소스.
//  PixelHeart와 같은 방식으로 격자 한 칸을 작은 사각형으로 그린다.
//

import SwiftUI

/// 같은 크기 격자 프레임 여러 장 + 팔레트로 정의하는 픽셀 스프라이트.
/// 0은 항상 투명. 바닥 정렬(착지 프레임이 짧아도 발 위치 고정)은 비트맵 위쪽 빈 행으로 표현한다.
struct PixelSprite {
    let frames: [[[Int]]]
    let palette: [Int: Color]

    var rows: Int { frames[0].count }
    var cols: Int { frames[0][0].count }
}

extension PixelSprite {
    /// 슬라임 — 초록 젤리. 프레임0: 착지(납작·넓게 퍼짐), 프레임1: 도약(길쭉·좁게).
    /// 1=몸통 2=반사광 3=그림자 4=눈. 눌리는 프레임에서는 눈도 옆으로 벌어진다.
    static let slime = PixelSprite(
        frames: [
            [   // 착지(squash) — 키 5칸, 폭 9칸
                [0, 0, 0, 0, 0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0, 0, 0, 0, 0],
                [0, 0, 1, 2, 1, 1, 1, 0, 0],
                [0, 1, 2, 1, 1, 1, 1, 1, 0],
                [1, 1, 4, 1, 1, 1, 4, 1, 1],
                [1, 1, 1, 1, 1, 1, 1, 3, 3],
                [0, 1, 1, 1, 1, 1, 3, 3, 0],
            ],
            [   // 도약(stretch) — 키 7칸, 폭 7칸
                [0, 0, 0, 1, 1, 1, 0, 0, 0],
                [0, 0, 1, 2, 1, 1, 1, 0, 0],
                [0, 1, 2, 1, 1, 1, 1, 1, 0],
                [0, 1, 1, 4, 1, 4, 1, 1, 0],
                [0, 1, 1, 1, 1, 1, 1, 3, 0],
                [0, 1, 1, 1, 1, 1, 3, 3, 0],
                [0, 0, 1, 1, 1, 3, 3, 0, 0],
            ],
        ],
        palette: [
            1: Color(red: 0.28, green: 0.85, blue: 0.40),   // #47D966 젤리 몸통
            2: Color(red: 0.75, green: 0.97, blue: 0.78),   // #BFF8C7 반사광
            3: Color(red: 0.10, green: 0.55, blue: 0.24),   // #1A8C3D 그림자
            4: Color(red: 0.02, green: 0.15, blue: 0.08),   // #052614 눈
        ]
    )
}

/// 스프라이트 한 프레임을 그리는 뷰. cell = 픽셀 한 칸의 pt 크기.
struct PixelSpriteView: View {
    let sprite: PixelSprite
    let frameIndex: Int
    let cell: CGFloat

    var body: some View {
        let bitmap = sprite.frames[frameIndex % sprite.frames.count]
        Canvas { ctx, _ in
            for (r, row) in bitmap.enumerated() {
                for (c, v) in row.enumerated() where v != 0 {
                    guard let color = sprite.palette[v] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                         width: cell, height: cell)),
                             with: .color(color))
                }
            }
        }
        .frame(width: cell * CGFloat(sprite.cols), height: cell * CGFloat(sprite.rows))
        .accessibilityHidden(true)
    }
}

#Preview("slime frames") {
    HStack(spacing: 24) {
        PixelSpriteView(sprite: .slime, frameIndex: 0, cell: 6)
        PixelSpriteView(sprite: .slime, frameIndex: 1, cell: 6)
    }
    .padding(24)
    .background(Term.red)   // 100% 게이지(빨강) 위에 올라갈 색 조합 확인용
}
