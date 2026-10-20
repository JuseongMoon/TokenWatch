//
//  MonsterSprites.swift
//  TokenWatch
//
//  게이지 몬스터·효과 스프라이트. 번들 정본 `monsters-v1.json`(Android와 바이트 동일, SHA-256 parity)과
//  카탈로그의 원격 inline 스프라이트(V3)를 같은 디코더로 읽는다. 실행 코드가 아니라 픽셀 데이터다.
//  슬라임은 기존 앱 스프라이트(PixelSprite.slime·slimeSky)를 그대로 쓴다.
//
//  처치 상태는 원래 색을 흑백톤으로(밝기 Y = 0.299R + 0.587G + 0.114B, ×0.8 — Android와 같은 공식).
//

import SwiftUI

/// 디코딩된 스프라이트(색은 0xRRGGBB). 0은 투명.
nonisolated struct MonsterSpriteData: Equatable, Sendable {
    let cols: Int
    let rows: Int
    let frames: [[[Int]]]
    let palette: [Int: UInt32]
}

nonisolated enum MonsterSpriteDecoder {
    /// 원격 inline 스프라이트 상한(계약 §8-2).
    static let maxSide = 24
    static let maxFrames = 4
    static let maxPaletteIndex = 16

    /// 번들 파일 `{schemaVersion, sprites: [{id, palette, frames}]}` → id별 스프라이트. 잘못된 항목은 버린다.
    static func decodeFile(_ data: Data) -> [String: MonsterSpriteData] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["sprites"] as? [[String: Any]] else { return [:] }
        var out: [String: MonsterSpriteData] = [:]
        for item in list {
            guard let id = item["id"] as? String, !id.isEmpty, out[id] == nil,
                  let sprite = decode(frames: item["frames"], palette: item["palette"]) else { continue }
            out[id] = sprite
        }
        return out
    }

    /// 카탈로그 `sprite.inline` — `{cols, rows, frames, palette}`. 선언한 크기와 실제 격자가 같아야 한다.
    static func decodeInline(_ json: [String: Any]) -> MonsterSpriteData? {
        guard let sprite = decode(frames: json["frames"], palette: json["palette"]),
              (json["cols"] as? Int) == sprite.cols, (json["rows"] as? Int) == sprite.rows else { return nil }
        return sprite
    }

    private static func decode(frames rawFrames: Any?, palette rawPalette: Any?) -> MonsterSpriteData? {
        guard let frames = rawFrames as? [[[Int]]], (1...maxFrames).contains(frames.count),
              let first = frames.first, let cols = first.first?.count else { return nil }
        let rows = first.count
        guard (1...maxSide).contains(rows), (1...maxSide).contains(cols),
              frames.allSatisfy({ $0.count == rows && $0.allSatisfy { $0.count == cols } }),
              let paletteJSON = rawPalette as? [String: String] else { return nil }
        var palette: [Int: UInt32] = [:]
        for (key, hex) in paletteJSON {
            guard let index = Int(key), (1...maxPaletteIndex).contains(index),
                  let rgb = AvatarDecoder.parseHex(hex) else { return nil }
            palette[index] = rgb
        }
        for frame in frames {
            for row in frame {
                for v in row where v != 0 {
                    guard palette[v] != nil else { return nil }
                }
            }
        }
        return MonsterSpriteData(cols: cols, rows: rows, frames: frames, palette: palette)
    }

    /// 처치 상태 흑백톤(양 플랫폼 같은 공식).
    static func grayTone(_ rgb: UInt32) -> UInt32 {
        let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
        let y = UInt32(((0.299 * r + 0.587 * g + 0.114 * b) * 0.8).rounded())
        return (y << 16) | (y << 8) | y
    }
}

enum MonsterSprites {
    /// 번들 파일 이름(확장자 제외).
    static let bundledFile = "monsters-v1"
    static let swordID = "fx-sword"
    static let haloID = "fx-halo"

    /// 번들 스프라이트(id → 데이터). 앱 실행 중 한 번 읽는다.
    static let bundled: [String: MonsterSpriteData] = {
        guard let url = Bundle.main.url(forResource: bundledFile, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return MonsterSpriteDecoder.decodeFile(data)
    }()

    /// 몬스터 그림. 카탈로그 inline → 번들(카탈로그가 가리키는 이름 또는 id) → 슬라임 순서.
    /// 세션 창(5시간 등)의 슬라임은 기존 게이지 크리터처럼 하늘색이다.
    static func sprite(for monsterID: String, entry: MonsterCatalogEntry?, sessionWindow: Bool,
                       defeated: Bool = false) -> PixelSprite {
        if monsterID == "slime" || (entry == nil && bundled[monsterID] == nil) {
            let slime: PixelSprite = sessionWindow ? .slimeSky : .slime
            return defeated ? grayscale(slime) : slime
        }
        let data = entry?.inlineSprite ?? bundled[entry?.bundledSprite ?? monsterID] ?? bundled[monsterID]
        guard let data else { return defeated ? grayscale(.slime) : .slime }
        return pixelSprite(data, defeated: defeated)
    }

    static var sword: PixelSprite? { bundled[swordID].map { pixelSprite($0, defeated: false) } }
    static var halo: PixelSprite? { bundled[haloID].map { pixelSprite($0, defeated: false) } }

    static func pixelSprite(_ data: MonsterSpriteData, defeated: Bool) -> PixelSprite {
        PixelSprite(frames: data.frames, palette: data.palette.mapValues { rgb in
            color(defeated ? MonsterSpriteDecoder.grayTone(rgb) : rgb)
        })
    }

    /// 앱 내장 스프라이트(슬라임)의 흑백톤.
    static func grayscale(_ sprite: PixelSprite) -> PixelSprite {
        PixelSprite(frames: sprite.frames, palette: sprite.palette.mapValues { c in
            let ui = UIColor(c)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            let rgb = (UInt32((r * 255).rounded()) << 16) | (UInt32((g * 255).rounded()) << 8) | UInt32((b * 255).rounded())
            return color(MonsterSpriteDecoder.grayTone(rgb))
        })
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}
