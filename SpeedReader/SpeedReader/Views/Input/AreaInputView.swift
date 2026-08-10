import SwiftUI

struct AreaInputView: View {
    @Binding var inputText: String
    @Binding var selectedStartIndex: Int?
    var readingEngine: RSVPEngine? = nil

    @State private var isCapturing: Bool = false
    @State private var isRecognizing: Bool = false
    @State private var capturedImage: NSImage? = nil
    @State private var errorMessage: String? = nil

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasText {
                // Show captured text — controls live in the unified top toolbar
                Group {
                    if let engine = readingEngine {
                        HighlightedTextView(text: inputText, engine: engine)
                    } else if #available(macOS 14.0, *) {
                        SearchableTextContainer(
                            text: inputText,
                            onStartFromHere: { idx in selectedStartIndex = idx },
                            toolbarTrailing: AnyView(captureControls),
                            alwaysShowsToolbar: true
                        ) { matches, active in
                            ClickableTextPreview(
                                text: inputText,
                                selectedWordIndex: $selectedStartIndex,
                                searchMatchIndices: matches,
                                activeSearchIndex: active
                            )
                        }
                    } else {
                        ClickableTextPreview(text: inputText, selectedWordIndex: $selectedStartIndex)
                    }
                }
                .previewCard()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // Word count
                if readingEngine == nil {
                    HStack {
                        Text("\(inputText.split(separator: " ").count) words")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
            } else {
                // Empty state with capture button
                VStack(spacing: 20) {
                    Spacer()

                    if isRecognizing {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Recognizing text...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 44, weight: .ultraLight))
                                .foregroundColor(.secondary.opacity(0.4))

                            VStack(spacing: 6) {
                                Text("Capture Screen Area")
                                    .font(.system(size: 16, weight: .semibold))

                                Text("Select an area on screen to extract text using OCR")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }

                            Button(action: captureArea) {
                                HStack(spacing: 8) {
                                    Image(systemName: "viewfinder")
                                        .font(.system(size: 14))
                                    Text("Select Area")
                                        .font(.system(size: 14, weight: .medium))
                                    Text("⌘⇧A")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.accentColor)
                                )
                                .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("a", modifiers: [.command, .shift])
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .padding(.top, 4)
                        }
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .captureScreenArea)) { _ in
            captureArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissDocument)) { _ in
            if hasText && readingEngine == nil {
                inputText = ""
                capturedImage = nil
            }
        }
    }

    // MARK: - Toolbar controls

    private var captureControls: some View {
        HStack(spacing: 8) {
            Button(action: captureArea) {
                ToolbarChipLabel(icon: "viewfinder", text: "Recapture")
            }
            .buttonStyle(.plain)

            Button(action: { inputText = ""; capturedImage = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func captureArea() {
        guard !isCapturing else { return }
        isCapturing = true
        errorMessage = nil

        // Minimize main window so it doesn't block the capture
        NSApp.mainWindow?.miniaturize(nil)

        // Small delay to let the window minimize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task {
                guard let cgImage = await ScreenAreaCapture.captureArea() else {
                    await MainActor.run {
                        isCapturing = false
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    return
                }

                await MainActor.run {
                    isRecognizing = true
                    isCapturing = false
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.title == "Speed Reader" }) {
                        window.deminiaturize(nil)
                    }
                }

                do {
                    let text = try await ScreenAreaCapture.recognizeText(from: cgImage)
                    await MainActor.run {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            errorMessage = "No text found in the selected area"
                        } else {
                            inputText = text
                        }
                        isRecognizing = false
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "OCR failed: \(error.localizedDescription)"
                        isRecognizing = false
                    }
                }
            }
        }
    }
}
