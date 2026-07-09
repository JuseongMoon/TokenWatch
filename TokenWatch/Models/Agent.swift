//
//  Agent.swift
//  TokenWatch
//
//  로그인된 AI 에이전트 1개를 나타내는 모델.
//

import Foundation
import SwiftUI

/// 지원하는 AI 에이전트 제공자. 지금은 Claude만 있지만, 추후 Codex/Gemini 등을
/// 같은 방식으로 추가할 수 있도록 enum + 프로토콜 조합으로 확장 여지를 둔다.
enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    /// 리스트/시트에 표시할 사람이 읽는 이름.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// 카드 배지/링 색상에 쓰는 SF Symbol 이름.
    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 브랜드 색상.
    var accentColor: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        }
    }

    /// 터미널 카드에서 provider를 나타내는 짧은 텍스트 태그.
    var terminalTag: String {
        switch self {
        case .claude: return "[C]"
        case .codex:  return "[X]"
        }
    }

    /// 터미널 팔레트 기준 provider 구분색(태그/타이틀 강조용).
    var terminalColor: Color {
        switch self {
        case .claude: return Term.yellow
        case .codex:  return Term.cyan
        }
    }
}

/// 사용자가 추가한 에이전트 항목. 리스트의 한 행에 대응한다.
/// 토큰 자체는 Keychain에 저장하고, 여기에는 식별 정보만 보관한다.
struct Agent: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let provider: AgentProvider
    /// 로그인 계정 표시용 (플랜명/이메일 등). 없을 수 있다.
    var accountLabel: String?

    init(id: UUID = UUID(), provider: AgentProvider, accountLabel: String? = nil) {
        self.id = id
        self.provider = provider
        self.accountLabel = accountLabel
    }
}
