//
//  ColorSwatch.swift
//  SpeedReader
//
//  Created on 20.02.2026.
//

import SwiftUI

struct ColorSwatch: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)

                if isSelected {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 26, height: 26)

                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HStack(spacing: 12) {
        ColorSwatch(color: .red, isSelected: true) {}
        ColorSwatch(color: .orange, isSelected: false) {}
        ColorSwatch(color: .yellow, isSelected: false) {}
        ColorSwatch(color: .green, isSelected: false) {}
        ColorSwatch(color: .blue, isSelected: false) {}
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
