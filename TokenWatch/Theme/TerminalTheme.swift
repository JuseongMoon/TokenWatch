//
//  TerminalTheme.swift
//  TokenWatch
//
//  터미널/ANSI 스타일 디자인 토큰: 팔레트 · 모노스페이스 폰트 · 텍스트 글로우 ·
//  깜빡이는 커서 · ASCII 스피너. 앱 전역이 이 파일 하나를 단일 소스로 삼는다.
//

import SwiftUI

/// ANSI 16색 감성의 터미널 팔레트. 배경은 순수 검정 고정.
enum Term {
    static let bg     = Color.black                                   // #000000
    static let fg     = Color(red: 0.84, green: 0.86, blue: 0.82)     // #D6DBD1 본문
    static let dim    = Color(red: 0.42, green: 0.48, blue: 0.42)     // #6B7A6B 보조/트랙
    static let cyan   = Color(red: 0.34, green: 0.84, blue: 0.84)     // #56D6D6 라벨/헤더/키
    static let green  = Color(red: 0.30, green: 0.82, blue: 0.48)     // #4CD07A 정상/프롬프트/커서
    static let yellow = Color(red: 0.90, green: 0.76, blue: 0.30)     // #E6C34D 주의/현재시각 마커
    static let red    = Color(red: 0.94, green: 0.34, blue: 0.30)     // #F0574C 위험/에러
    static let orange = Color(red: 0.95, green: 0.58, blue: 0.30)     // #F2944D provider 구분색
    static let magenta = Color(red: 0.80, green: 0.52, blue: 0.90)    // #CC85E6 provider 구분색
    static let blue   = Color(red: 0.40, green: 0.62, blue: 0.95)     // #669EF2 provider 구분색
    static let pink   = Color(red: 0.95, green: 0.45, blue: 0.65)     // #F273A6 provider 구분색
    static let teal   = Color(red: 0.30, green: 0.78, blue: 0.70)     // #4CC7B3 provider 구분색
    static let track  = Color(red: 0.14, green: 0.17, blue: 0.13)     // 게이지 빈 칸 배경(거의 안 씀)

    /// 잔여율(0...100) 기준 상태색. 게이지 채움·수치 색을 통일한다.
    static func statusColor(remainingPercent: Double) -> Color {
        switch remainingPercent {
        case ..<10: return red
        case ..<25: return yellow
        default:    return green
        }
    }

    /// 서비스 운영 상태(ServiceHealth) 표시색 — 라벨 텍스트에 쓴다(검은 배경 가독성 유지).
    static func serviceHealthColor(_ health: ServiceHealth) -> Color {
        switch health {
        case .operational: return green
        case .degraded:    return yellow
        case .major:       return red
        case .maintenance: return blue
        case .unknown:     return dim
        }
    }

    /// 상태 배지 점(●) 전용 색. 조회 불가/미상(unknown) 회색은 투명도를 크게 낮춰
    /// 검은 배경에 묻히는 "꺼진 점"처럼 표시한다. 정상(초록)·장애(노랑/빨강) 점이 밝게
    /// 켜져 있는 카드들 사이에서 문제 있는 카드를 한눈에 구분하기 위함(라벨엔 쓰지 않음).
    static func serviceHealthDotColor(_ health: ServiceHealth) -> Color {
        health == .unknown ? dim.opacity(0.4) : serviceHealthColor(health)
    }
}

extension Font {
    /// 터미널 모노스페이스 폰트(SF Mono). 앱 전체 텍스트가 이걸 쓴다.
    static func term(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// 은은한 텍스트 글로우 — 같은 색의 약한 shadow. 과하면 스크롤 렉이라 radius를 작게.
    func terminalGlow(_ color: Color, radius: CGFloat = 2.5) -> some View {
        shadow(color: color.opacity(0.5), radius: radius)
    }
}

/// 1초 주기로 딱딱 켜졌다 꺼지는 블록/언더바 커서. 터미널 캐럿 느낌.
/// TimelineView 기반이라 상태 없이 어디서든 여러 개 배치해도 가볍다.
struct BlinkingCursor: View {
    var symbol: String = "█"
    var color: Color = Term.green
    var size: CGFloat = 14
    /// 전체 깜빡임 주기(초).
    var period: Double = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: period / 2)) { context in
            let half = period / 2
            let phase = Int(context.date.timeIntervalSinceReferenceDate / half) % 2
            Text(symbol)
                .font(.term(size))
                .foregroundStyle(color)
                .opacity(phase == 0 ? 1 : 0)
                .accessibilityHidden(true)
        }
    }
}

/// 하트를 세로로 나눈 조각. 반쪽 잔여 표기·부분(오른쪽 반) 깜빡임에 쓴다.
/// left(가운데 열 포함) + right 를 겹치면 full 하트와 정확히 같다.
enum HeartPart { case full, left, right }

/// 픽셀 격자 하트. 11×10 비트맵을 작은 사각형으로 그린다. 세 톤(기본·하이라이트·그림자)으로
/// 위-왼쪽에서 빛을 받는 반사광을 픽셀 음영으로 표현한다. 모노스페이스 텍스트 옆 커서 대체용.
struct PixelHeart: View {
    /// 하트 전용 선명한 레드. ANSI 위험색(Term.red, 코랄톤)보다 채도가 높은 별도 색.
    static let heartRed       = Color(red: 1.0,  green: 0.20, blue: 0.27)    // #FF3345 기본
    static let heartHighlight = Color(red: 1.0,  green: 0.82, blue: 0.86)    // #FFD1DB 반사광
    static let heartShadow    = Color(red: 0.76, green: 0.09, blue: 0.19)    // #C21830 그림자

    /// nil이면 3톤 광택 렌더. 값이 있으면 실루엣 전체를 그 색 하나로(설정 off 미리보기 등).
    var flatColor: Color? = nil
    /// 하트 조각(전체 / 왼쪽 반 / 오른쪽 반). 반쪽은 잔여율 10% 단위·부분 깜빡임에 쓴다.
    var part: HeartPart = .full
    /// 채움 없이 흰 외곽선만 그린다(사용량 소진 표시).
    var outline: Bool = false
    /// 하트 높이(대략 폰트 cap-height에 맞춘다). 픽셀 한 칸 = size / 행 수.
    var size: CGFloat = 11

    // 0=빈칸 1=기본 2=하이라이트 3=그림자. 위 두 돌기→아래 한 점, 왼쪽 위 반사광·오른쪽 아래 그림자.
    private static let bitmap: [[Int]] = [
        [0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0],
        [0, 1, 2, 2, 1, 0, 1, 1, 1, 1, 0],
        [1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1],
        [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3],
        [1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3],
        [0, 1, 1, 1, 1, 1, 1, 1, 3, 3, 0],
        [0, 0, 1, 1, 1, 1, 1, 3, 3, 0, 0],
        [0, 0, 0, 1, 1, 1, 3, 3, 0, 0, 0],
        [0, 0, 0, 0, 1, 1, 3, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0],
    ]

    var body: some View {
        let rows = Self.bitmap.count
        let cols = Self.bitmap[0].count
        let cell = size / CGFloat(rows)
        let centerCol = cols / 2                              // 세로 반쪽 컷 경계(가운데 열 포함)
        Canvas { ctx, _ in
            for (r, row) in Self.bitmap.enumerated() {
                for (c, v) in row.enumerated() where v != 0 {
                    switch part {                                     // 세로 반쪽 컷(가운데 열은 왼쪽에 포함)
                    case .full:  break
                    case .left:  if c > centerCol { continue }
                    case .right: if c <= centerCol { continue }
                    }
                    if outline && !Self.isEdge(r, c) { continue }     // 가장자리 칸만
                    let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                      width: cell, height: cell)
                    let color = outline ? Color.white : (flatColor ?? Self.tone(v))
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: cell * CGFloat(cols), height: cell * CGFloat(rows))
        .accessibilityHidden(true)
    }

    private static func tone(_ v: Int) -> Color {
        switch v {
        case 2:  return heartHighlight
        case 3:  return heartShadow
        default: return heartRed
        }
    }

    /// 채워진 칸 중 상하좌우 이웃에 빈칸(또는 격자 밖)이 있는 가장자리 칸인지 — 외곽선 렌더용.
    private static func isEdge(_ r: Int, _ c: Int) -> Bool {
        let rows = bitmap.count, cols = bitmap[0].count
        for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nr = r + dr, nc = c + dc
            if nr < 0 || nr >= rows || nc < 0 || nc >= cols { return true }
            if bitmap[nr][nc] == 0 { return true }
        }
        return false
    }
}

/// content를 BlinkingCursor와 같은 주기로 딱딱 깜빡인다(심장박동 리듬). 상태 없이 가볍다.
struct TerminalBlink<Content: View>: View {
    var period: Double = 1.0
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: period / 2)) { context in
            let half = period / 2
            let phase = Int(context.date.timeIntervalSinceReferenceDate / half) % 2
            content.opacity(phase == 0 ? 1 : 0)
        }
    }
}

/// 하트 커서(단일). 심장박동처럼 켜졌다 꺼진다. 상태 프롬프트의 언더바 커서를 대체한다.
struct BlinkingHeart: View {
    var size: CGFloat = 11
    var period: Double = 1.0

    var body: some View {
        TerminalBlink(period: period) {
            PixelHeart(size: size).accessibilityHidden(true)
        }
    }
}

/// 사용량 추적 하트 바. 선택한 그래프의 잔여율을 최대 5개 하트로 표현한다(10%당 반 칸).
/// 잔여의 "마지막 반 칸"만 깜빡인다 — 맨 오른쪽이 꽉 찬 하트면 그 오른쪽 반만, 반쪽 하트면
/// 그 반쪽이 통째로. 소진(100%)되면 흰 외곽선 하트가 깜빡인다.
struct HeartHealthBar: View {
    /// 추적 대상 창의 사용률(0...100).
    var usedPercent: Double
    var size: CGFloat = 11
    var spacing: CGFloat = 2

    var body: some View {
        let h = Self.remainingHalfHearts(usedPercent)
        HStack(spacing: spacing) {
            if h == 0 {
                // 소진: 흰 외곽선 하트가 깜빡.
                TerminalBlink { PixelHeart(outline: true, size: size) }
            } else {
                let slots = (h + 1) / 2                        // 표시할 하트 칸 수(1...5, ceil)
                ForEach(0..<slots, id: \.self) { i in
                    if i < slots - 1 {
                        PixelHeart(size: size)                // 앞쪽: 꽉 찬 하트(정지)
                    } else if h % 2 == 0 {
                        // 맨 오른쪽이 꽉 찬 하트 → 왼쪽 반 정지 + 오른쪽 반만 깜빡.
                        ZStack {
                            PixelHeart(part: .left, size: size)
                            TerminalBlink { PixelHeart(part: .right, size: size) }
                        }
                    } else {
                        // 맨 오른쪽이 반쪽 하트 → 그 반쪽(왼쪽 반)이 통째로 깜빡.
                        TerminalBlink { PixelHeart(part: .left, size: size) }
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int(usedPercent.rounded()))% used")
    }

    /// 사용률(0...100) → 남은 반쪽 하트 수(0...10). 10%당 반 칸, 100%면 0.
    static func remainingHalfHearts(_ usedPercent: Double) -> Int {
        let used = min(100, max(0, usedPercent))
        return max(0, 10 - Int(used / 10))
    }
}

/// 브라유 점 회전 ASCII 스피너. 로딩/조회 중 표시.
struct TerminalSpinner: View {
    var color: Color = Term.green
    var size: CGFloat = 14
    private let frames = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let i = Int(context.date.timeIntervalSinceReferenceDate * 10) % frames.count
            Text(frames[abs(i)])
                .font(.term(size))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
    }
}
