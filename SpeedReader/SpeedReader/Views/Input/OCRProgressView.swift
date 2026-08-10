import SwiftUI

/// Shown during OCR processing with a progress indicator.
struct OCRProgressView: View {
    let currentPage: Int
    let totalPages: Int
    var fileName: String?

    /// Single-page mode (images, single-page scans) — show indeterminate spinner
    private var isSinglePage: Bool { totalPages <= 1 }

    private var isImage: Bool {
        guard let ext = fileName?.components(separatedBy: ".").last?.lowercased() else { return false }
        return ImageReader.supportedExtensions.contains(ext)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isImage ? "photo.badge.magnifyingglass" : "text.viewfinder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)

            Text(isImage ? "Recognizing text from image..." : "Recognizing text...")
                .font(.system(size: 14, weight: .medium))

            if let fileName = fileName {
                Text(fileName)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if isSinglePage {
                ProgressView()
                    .controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    ProgressView(value: Double(currentPage), total: Double(totalPages))
                        .progressViewStyle(.linear)
                        .frame(width: 260)

                    Text("Page \(currentPage) of \(totalPages)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text("Using on-device OCR")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(24)
    }
}
