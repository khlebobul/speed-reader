import SwiftUI

/// Shown when a document requires OCR (scanned PDF or image).
/// Lets the user choose quality and confirm text recognition.
struct OCRPromptView: View {
    let pageCount: Int
    let onConfirm: (OCREngine.Options) -> Void
    let onCancel: () -> Void

    @State private var quality: OCREngine.Options.Quality = ReaderSettings.shared.ocrQuality

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("This document contains scanned pages")
                .font(.system(size: 14, weight: .medium))

            Text("\(pageCount) page\(pageCount == 1 ? "" : "s") \u{00B7} On-device recognition \u{00B7} Private")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Picker("Quality", selection: $quality) {
                Text("Fast").tag(OCREngine.Options.Quality.fast)
                Text("Accurate").tag(OCREngine.Options.Quality.accurate)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                Button("Recognize Text") {
                    var opts = OCREngine.Options()
                    opts.quality = quality
                    onConfirm(opts)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}
