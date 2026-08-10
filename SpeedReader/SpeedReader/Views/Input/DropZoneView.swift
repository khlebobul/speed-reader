import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let supportedExtensions: [String]
    let isLoading: Bool
    let onDrop: (URL) -> Void
    let onChooseFile: () -> Void

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [10, 6])
                )
                .foregroundStyle(isTargeted ? Color.accentColor : Color.primary.opacity(0.12))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.02))
                )

            VStack(spacing: 18) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary.opacity(0.4))

                Text("Drop file here")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

                // Choose file button inside drop zone
                Button(action: onChooseFile) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                        Text("Choose File...")
                            .font(.system(size: 14, weight: .medium))
                        Text("⌘O")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(isLoading)

                let imageExts: Set<String> = ["jpg", "png", "tiff", "heic", "bmp"]
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(supportedExtensions.filter { !imageExts.contains($0) }, id: \.self) { ext in
                            extensionBadge(ext)
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(supportedExtensions.filter { imageExts.contains($0) }, id: \.self) { ext in
                            extensionBadge(ext)
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }

            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, DocumentReaderFactory.isSupported(url: url) {
                    DispatchQueue.main.async {
                        onDrop(url)
                    }
                }
            }
            return true
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    @ViewBuilder
    private func extensionBadge(_ ext: String) -> some View {
        HStack(spacing: 5) {
            Text(".\(ext)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if ext == "pdf" {
                Text("Beta")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
