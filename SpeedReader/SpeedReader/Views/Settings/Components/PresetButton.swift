//
//  PresetButton.swift
//  SpeedReader
//
//  Created on 20.02.2026.
//

import SwiftUI

struct PresetButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HStack {
        PresetButton(label: "SM", isSelected: false) {}
        PresetButton(label: "MD", isSelected: true) {}
        PresetButton(label: "LG", isSelected: false) {}
    }
    .padding()
}
