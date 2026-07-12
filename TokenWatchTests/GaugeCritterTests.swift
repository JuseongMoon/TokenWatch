//
//  GaugeCritterTests.swift
//  TokenWatchTests
//
//  100% 게이지 슬라임 행진의 순수 로직 검증:
//  GaugeCritter.frameIndex/offsetX — 호핑 리듬·랩어라운드·경계, 그리고
//  PixelSprite.slime 비트맵 무결성(프레임 크기·팔레트 값)을 결정적으로 확인한다.
//

import Testing
import Foundation
@testable import TokenWatch

struct GaugeCritterTests {

    // MARK: 프레임 교대(착지 0 ↔ 도약 1)

    @Test func framesAlternatePerTick() {
        #expect(GaugeCritter.frameIndex(tick: 0) == 0)
        #expect(GaugeCritter.frameIndex(tick: 1) == 1)
        #expect(GaugeCritter.frameIndex(tick: 2) == 0)
        #expect(GaugeCritter.frameIndex(tick: 3) == 1)
    }

    // MARK: 호핑 이동 — 도약 틱에 전진, 착지 틱에 정지

    @Test func startsFullyHiddenAtLeftEdge() {
        let x = GaugeCritter.offsetX(tick: 0, hop: 10, spriteWidth: 20, barWidth: 100)
        #expect(x == -20)
    }

    @Test func advancesOnJumpTickAndRestsOnLandTick() {
        let jump = GaugeCritter.offsetX(tick: 1, hop: 10, spriteWidth: 20, barWidth: 100)
        let land = GaugeCritter.offsetX(tick: 2, hop: 10, spriteWidth: 20, barWidth: 100)
        let next = GaugeCritter.offsetX(tick: 3, hop: 10, spriteWidth: 20, barWidth: 100)
        #expect(jump == -10)          // 첫 도약: 한 걸음 전진
        #expect(land == jump)         // 착지: 같은 자리에서 눌림
        #expect(next == 0)            // 다음 도약: 또 한 걸음
    }

    @Test func wrapsAroundAfterCrossingBar() {
        // (barWidth + spriteWidth) / hop = 12 걸음이 한 바퀴.
        // 12번째 도약이 시작되는 틱(2 * 12 - 1 = 23)에서 다시 왼쪽 밖으로 돌아온다.
        let lastVisible = GaugeCritter.offsetX(tick: 22, hop: 10, spriteWidth: 20, barWidth: 100)
        let wrapped = GaugeCritter.offsetX(tick: 23, hop: 10, spriteWidth: 20, barWidth: 100)
        #expect(lastVisible == 90)    // 마지막 걸음: 바 오른끝에 살짝 걸침
        #expect(wrapped == -20)       // 랩어라운드: 완전히 숨은 왼쪽 밖
    }

    @Test func staysInsideBarForFullCycle() {
        // 어떤 틱에서도 스프라이트 왼끝이 바 오른끝을 넘지 않는다.
        for tick in 0...200 {
            let x = GaugeCritter.offsetX(tick: tick, hop: 7, spriteWidth: 15.4, barWidth: 250)
            #expect(x >= -15.4)
            #expect(x < 250)
        }
    }

    @Test func degenerateSizesFallBackToHidden() {
        #expect(GaugeCritter.offsetX(tick: 5, hop: 0, spriteWidth: 20, barWidth: 100) == -20)
        #expect(GaugeCritter.offsetX(tick: 5, hop: 10, spriteWidth: 20, barWidth: 0) == -20)
    }

    // MARK: 등장/소멸 8단계 페이드

    @Test func steppedOpacityQuantizesToEighths() {
        #expect(GaugeCritter.steppedOpacity(0) == 0)
        #expect(GaugeCritter.steppedOpacity(1) == 1)
        #expect(GaugeCritter.steppedOpacity(0.5) == 0.5)     // 4/8
        #expect(GaugeCritter.steppedOpacity(0.1) == 0.0)     // floor(0.8)/8 = 0
        #expect(GaugeCritter.steppedOpacity(0.2) == 0.125)   // floor(1.6)/8 = 1/8
        #expect(GaugeCritter.steppedOpacity(0.99) == 0.875)  // floor(7.92)/8 = 7/8
    }

    @Test func steppedOpacityWalksEightSteps() {
        // 0→1 진행 동안 나타나는 불투명도 값은 0,1/8,…,7/8,1 의 9개(=8단계)뿐.
        var levels = Set<Double>()
        for i in 0...100 { levels.insert(GaugeCritter.steppedOpacity(Double(i) / 100)) }
        #expect(levels.count == 9)
        #expect(levels.contains(0))
        #expect(levels.contains(1))
    }

    @Test func steppedOpacityClampsOutOfRange() {
        #expect(GaugeCritter.steppedOpacity(-0.5) == 0)
        #expect(GaugeCritter.steppedOpacity(1.5) == 1)
    }

    // MARK: 등장 조건

    @Test func thresholdMatchesDisplayRounding() {
        // 표시상 "100% used"로 반올림되는 지점(99.5%)과 같은 기준을 쓴다.
        #expect(GaugeCritter.threshold == 0.995)
        #expect(0.994 < GaugeCritter.threshold)
        #expect(1.0 >= GaugeCritter.threshold)
    }

    // MARK: 슬라임 비트맵 무결성

    @Test func slimeHasTwoFramesOfSameGridSize() {
        let s = PixelSprite.slime
        #expect(s.frames.count == 2)
        for frame in s.frames {
            #expect(frame.count == s.rows)
            for row in frame { #expect(row.count == s.cols) }
        }
    }

    @Test func slimeUsesOnlyPaletteValues() {
        let s = PixelSprite.slime
        let allowed = Set(s.palette.keys).union([0])
        for frame in s.frames {
            for row in frame {
                for v in row { #expect(allowed.contains(v)) }
            }
        }
    }

    @Test func slimeFramesAreBottomAligned() {
        // 두 프레임 모두 맨 아랫줄에 몸이 있어야 발 위치가 고정된다(착지 프레임의 빈 행은 위쪽).
        let s = PixelSprite.slime
        for frame in s.frames {
            #expect(frame[s.rows - 1].contains { $0 != 0 })
            #expect(!frame[0].isEmpty)
        }
    }
}
