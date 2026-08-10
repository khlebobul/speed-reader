//
//  AboutView.swift
//  SpeedReader
//

import SwiftUI

struct AboutView: View {
    private let websiteURL = "https://speed-reader.pro"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Text("Speed Reader")
                .font(.system(size: 18, weight: .bold))

            Text("Version \(Bundle.main.appVersionString) (\(Bundle.main.appBuildString))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Free and open source · MIT")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 20)

            Button {
                if let url = URL(string: websiteURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text("Website")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.link)

            Text("\u{00A9} 2026 Gleb Shalimov")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 40)
        .frame(width: 300)
        .background(.ultraThinMaterial)
    }
}
