//
//  AvatarCatalog.swift
//  TokenWatch
//
//  앱 계정 프로필 아바타(픽셀아트 프리셋). 정본 JSON(`Resources/avatars-v1.json`)을 바이트 그대로
//  번들하고 런타임에 PixelSprite로 디코딩한다 — 코드로 옮겨 적지 않는다(Android와 같은 파일·같은 해시).
//  V3 원격 inline 스프라이트도 같은 형식이라 이 디코더를 그대로 쓴다.
//
//  번들 파일 목록을 순서대로 읽어 합친다. 나중에 아바타를 추가 공개하면 새 파일을 목록 끝에 붙이고,
//  기존 파일의 바이트(해시)는 바꾸지 않는다. ID가 겹치면 먼저 읽은 쪽을 유지한다.
//

import SwiftUI

/// 디코딩 결과(색은 0xRRGGBB 정수). 격리가 필요 없는 순수 데이터라 테스트에서 바로 검사한다.
nonisolated struct DecodedAvatar: Equatable, Sendable {
    let id: String
    let nameKo: String
    let nameEn: String
    let bitmap: [[Int]]
    let palette: [Int: UInt32]
}

/// 아바타 JSON 디코더. 형식이 어긋나는 항목은 버리고 모르는 필드는 무시한다(V3 형식 확장 대비).
nonisolated enum AvatarDecoder {
    static let grid = 16
    /// 팔레트 인덱스 상한(0 = 투명). 색 수 자체에는 상한을 두지 않는다.
    static let maxPaletteIndex = 16

    private struct File: Decodable {
        let grid: Int
        let avatars: [Entry]
    }

    private struct Entry: Decodable {
        struct Name: Decodable { let ko: String; let en: String }
        let id: String
        let name: Name
        let palette: [String: String]
        let frames: [[[Int]]]
    }

    static func decode(_ data: Data) -> [DecodedAvatar] {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.grid == grid else { return [] }
        return file.avatars.compactMap(validate)
    }

    private static func validate(_ e: Entry) -> DecodedAvatar? {
        guard !e.id.isEmpty, e.frames.count == 1, let bitmap = e.frames.first,
              bitmap.count == grid, bitmap.allSatisfy({ $0.count == grid }) else { return nil }
        var palette: [Int: UInt32] = [:]
        for (key, hex) in e.palette {
            guard let index = Int(key), (1...maxPaletteIndex).contains(index),
                  let rgb = parseHex(hex) else { return nil }
            palette[index] = rgb
        }
        for row in bitmap {
            for v in row where v != 0 {
                guard (1...maxPaletteIndex).contains(v), palette[v] != nil else { return nil }
            }
        }
        return DecodedAvatar(id: e.id, nameKo: e.name.ko, nameEn: e.name.en, bitmap: bitmap, palette: palette)
    }

    /// `#RRGGBB`만 받는다.
    static func parseHex(_ s: String) -> UInt32? {
        guard s.count == 7, s.first == "#" else { return nil }
        let digits = s.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }
}

/// 화면에서 쓰는 아바타 한 종.
struct AvatarPreset: Identifiable {
    let id: String
    let nameKo: String
    let nameEn: String
    let sprite: PixelSprite

    func name(_ lang: Lang) -> String { lang == .ko ? nameKo : nameEn }
}

enum AvatarCatalog {
    /// 번들에 넣은 정본 파일(확장자 제외). 공개 순서대로 읽는다.
    static let bundledFiles = ["avatars-v1"]
    /// 모르는 ID(다른 버전·V2 사진 등)를 대신 그릴 기본 아바타. 서버 응답 디코딩(nonisolated)에서도 쓴다.
    nonisolated static let fallbackID = "slime"

    /// 공개된 전체 목록(번들 순서 유지).
    static let all: [AvatarPreset] = load()

    static var ids: [String] { all.map(\.id) }

    /// ID로 찾되 모르면 기본 아바타.
    static func resolve(_ id: String) -> AvatarPreset {
        all.first { $0.id == id } ?? all.first { $0.id == fallbackID } ?? all[0]
    }

    /// 가입 화면에서 미리 골라 둘 무작위 1종(저장 전까지는 서버에 쓰지 않는다).
    static func random() -> AvatarPreset {
        all.randomElement() ?? resolve(fallbackID)
    }

    static func bundledFileURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "json")
    }

    private static func load() -> [AvatarPreset] {
        var seen = Set<String>()
        var result: [AvatarPreset] = []
        for name in bundledFiles {
            guard let url = bundledFileURL(name), let data = try? Data(contentsOf: url) else { continue }
            for a in AvatarDecoder.decode(data) where seen.insert(a.id).inserted {
                result.append(AvatarPreset(id: a.id, nameKo: a.nameKo, nameEn: a.nameEn,
                                           sprite: sprite(from: a)))
            }
        }
        // 번들 파일이 깨졌을 때도 화면이 비지 않게 앱 내장 슬라임으로 대신한다(테스트가 잡는다).
        if result.isEmpty {
            result = [AvatarPreset(id: fallbackID, nameKo: "슬라임", nameEn: "Slime", sprite: .slime)]
        }
        return result
    }

    private static func sprite(from a: DecodedAvatar) -> PixelSprite {
        PixelSprite(frames: [a.bitmap], palette: a.palette.mapValues { rgb in
            Color(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
        })
    }
}

/// 아바타 한 장(정지 프레임). cell = 픽셀 한 칸 pt — 64pt(4) / 48pt(3) / 32pt(2)처럼 정수로 둔다.
struct AvatarView: View {
    let avatarID: String
    var cell: CGFloat = 3

    var body: some View {
        PixelSpriteView(sprite: AvatarCatalog.resolve(avatarID).sprite, frameIndex: 0, cell: cell)
    }
}

#Preview("avatars") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 8) {
        ForEach(AvatarCatalog.all) { a in
            AvatarView(avatarID: a.id, cell: 4)
        }
    }
    .padding(16)
    .background(Term.bg)
}
