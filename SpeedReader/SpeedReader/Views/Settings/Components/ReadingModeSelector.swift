//
//  ReadingModeSelector.swift
//  SpeedReader
//
//  Created on 20.02.2026.
//

import SwiftUI

struct ReadingModeSelector: View {
    @Binding var selectedMode: ReadingMode

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ReadingMode.allCases) { mode in
                ReadingModeCard(
                    mode: mode,
                    isSelected: selectedMode == mode
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedMode = mode
                    }
                }
            }
        }
    }
}

struct ReadingModeCard: View {
    let mode: ReadingMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .primary)

                Text(mode.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(isHovered ? 0.05 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isSelected ? 0.06 : 0.03), radius: isSelected ? 6 : 3, y: isSelected ? 3 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

#Preview {
    ReadingModeSelector(
        selectedMode: .constant(.mainWindow)
    )
    .padding()
    .frame(width: 400)
}
