//
//  AddAgentCell.swift
//  TokenWatch
//
//  리스트 맨 하단의 "에이전트 추가" 프롬프트 버튼(점선 테두리).
//

import SwiftUI

struct AddAgentCell: View {
    let action: () -> Void

    var body: some View {
        TerminalButton(title: "[ + ADD AGENT ]",
                       color: Term.green,
                       dashedBorder: true,
                       action: action)
    }
}

#Preview {
    AddAgentCell(action: {})
        .padding()
        .background(Term.bg)
}
