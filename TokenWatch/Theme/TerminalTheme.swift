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

/// 픽셀 격자 하트. 11×10 비트맵을 작은 사각형으로 그린다. 세 톤(기본·하이라이트·그림자)으로
/// 위-왼쪽에서 빛을 받는 반사광을 픽셀 음영으로 표현한다. 모노스페이스 텍스트 옆 커서 대체용.
struct PixelHeart: View {
    /// 하트 전용 선명한 레드. ANSI 위험색(Term.red, 코랄톤)보다 채도가 높은 별도 색.
    static let heartRed       = Color(red: 1.0,  green: 0.20, blue: 0.27)    // #FF3345 기본
    static let heartHighlight = Color(red: 1.0,  green: 0.82, blue: 0.86)    // #FFD1DB 반사광
    static let heartShadow    = Color(red: 0.76, green: 0.09, blue: 0.19)    // #C21830 그림자

    /// nil이면 3톤 광택 렌더. 값이 있으면 실루엣 전체를 그 색 하나로(설정 off 미리보기 등).
    var flatColor: Color? = nil
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
        Canvas { ctx, _ in
            for (r, row) in Self.bitmap.enumerated() {
                for (c, v) in row.enumerated() where v != 0 {
                    let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                      width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(flatColor ?? Self.tone(v)))
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
}

/// 하트 커서. BlinkingCursor와 같은 주기로 심장박동처럼 켜졌다 꺼진다.
/// 상태 프롬프트의 언더바 커서를 대체한다.
struct BlinkingHeart: View {
    var size: CGFloat = 11
    /// 전체 깜빡임 주기(초).
    var period: Double = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: period / 2)) { context in
            let half = period / 2
            let phase = Int(context.date.timeIntervalSinceReferenceDate / half) % 2
            PixelHeart(size: size)
                .opacity(phase == 0 ? 1 : 0)
                .accessibilityHidden(true)
        }
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
