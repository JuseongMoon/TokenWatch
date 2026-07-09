//
//  AddAgentCell.swift
//  TokenWatch
//
//  리스트 맨 하단의 낮은 높이 "에이전트 추가" 셀.
//

import SwiftUI

struct AddAgentCell: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                Text("에이전트 추가")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.tint.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AddAgentCell(action: {})
        .padding()
}
