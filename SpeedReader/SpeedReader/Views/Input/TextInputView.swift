import SwiftUI
import AppKit

enum TextInputFormat: String, CaseIterable, Identifiable {
    case plain = "Plain"
    case markdown = "Markdown"

    var id: String { rawValue }
}

struct TextInputView: View {
    @Binding var inputText: String
    @Binding var inputFormat: TextInputFormat
    @Binding var selectedStartIndex: Int?
    var readingEngine: RSVPEngine? = nil

    @State private var isSelectingStart: Bool = false
    /// Local ⌘F monitor for the .text tab. ContentView's global monitor skips `.text`
    /// (so raw editing doesn't steal shortcuts globally), so we install our own while the
    /// plain-text input owns a searchable editor/preview.
    @State private var localCommandFMonitor: Any? = nil

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func pasteFromClipboard() {
        if let clipboardString = NSPasteboard.general.string(forType: .string),
           !clipboardString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = clipboardString
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Preview/editor area — controls live in the unified top toolbar
            contentArea
                .previewCard()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // Word count outside
            if readingEngine == nil && hasText {
                HStack {
                    Text("\(inputText.split(separator: " ").count) words")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: inputText) { _, _ in
            // Clear start position if text changes while editing
            if !isSelectingStart {
                selectedStartIndex = nil
            }
        }
        .onChange(of: isSelectingStart) { _, _ in
            if hasText && readingEngine == nil {
                installLocalCommandFMonitor()
            } else {
                removeLocalCommandFMonitor()
            }
        }
        .onChange(of: hasText) { _, newValue in
            if newValue && readingEngine == nil {
                installLocalCommandFMonitor()
            } else {
                removeLocalCommandFMonitor()
            }
        }
        .onChange(of: readingEngine == nil) { _, canSearch in
            if canSearch && hasText {
                installLocalCommandFMonitor()
            } else {
                removeLocalCommandFMonitor()
            }
        }
        .onAppear {
            if hasText && readingEngine == nil {
                installLocalCommandFMonitor()
            }
        }
        .onDisappear {
            removeLocalCommandFMonitor()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if let engine = readingEngine {
            if inputFormat == .markdown {
                MarkdownTabsPreviewView(
                    markdownString: inputText,
                    engine: engine
                )
            } else {
                HighlightedTextView(text: inputText, engine: engine)
            }
        } else if isSelectingStart && hasText {
            if inputFormat == .markdown {
                MarkdownTabsPreviewView(
                    markdownString: inputText,
                    isSelectingStart: true,
                    selectedWordIndex: selectedStartIndex,
                    onWordSelected: { idx in selectedStartIndex = idx },
                    onMarkdownEdited: { inputText = $0 },
                    toolbarLeading: AnyView(formatPicker),
                    toolbarTrailing: AnyView(setStartButton)
                )
            } else if #available(macOS 14.0, *) {
                SearchableTextContainer(
                    text: inputText,
                    onStartFromHere: { idx in selectedStartIndex = idx },
                    toolbarLeading: AnyView(formatPicker),
                    toolbarTrailing: AnyView(setStartButton),
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
        } else {
            if inputFormat == .markdown {
                MarkdownTabsPreviewView(
                    markdownString: inputText,
                    selectedWordIndex: selectedStartIndex,
                    onWordSelected: { idx in selectedStartIndex = idx },
                    onMarkdownEdited: { inputText = $0 },
                    toolbarLeading: AnyView(formatPicker),
                    toolbarTrailing: AnyView(
                        HStack(spacing: 8) {
                            if hasText { setStartButton }
                            pasteButton
                        }
                    )
                )
            } else if #available(macOS 14.0, *) {
                SearchableEditableTextContainer(
                    text: $inputText,
                    selectedStartIndex: $selectedStartIndex,
                    onStartFromHere: { idx in selectedStartIndex = idx },
                    toolbarLeading: AnyView(formatPicker),
                    toolbarTrailing: AnyView(
                        HStack(spacing: 8) {
                            if hasText { setStartButton }
                            pasteButton
                        }
                    ),
                    alwaysShowsToolbar: true
                )
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $inputText)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .padding(14)

                    if inputText.isEmpty {
                        Text("Paste or type your text here...")
                            .font(.system(size: 15))
                            .foregroundColor(Color(NSColor.placeholderTextColor))
                            .padding(.leading, 19)
                            .padding(.top, 15)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar controls

    private var setStartButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSelectingStart.toggle()
                if !isSelectingStart {
                    selectedStartIndex = nil
                }
            }
        } label: {
            ToolbarChipLabel(
                icon: isSelectingStart ? "pencil" : "hand.point.up.left",
                text: isSelectingStart ? "Edit" : "Set start position",
                active: isSelectingStart
            )
        }
        .buttonStyle(.plain)
    }

    private var formatPicker: some View {
        Picker("Input format", selection: $inputFormat) {
            ForEach(TextInputFormat.allCases) { format in
                Text(format.rawValue).tag(format)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .labelsHidden()
        .help("Choose how pasted text should be interpreted")
    }

    private var pasteButton: some View {
        Button(action: pasteFromClipboard) {
            ToolbarChipLabel(icon: "doc.on.clipboard", text: "Paste", shortcut: "⌘⇧C")
        }
        .buttonStyle(.plain)
        .keyboardShortcut("c", modifiers: [.command, .shift])
    }

    // MARK: - Local ⌘F monitor

    private func installLocalCommandFMonitor() {
        guard localCommandFMonitor == nil else { return }
        localCommandFMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // keyCode 3 = "f" on US layout. Same gate ContentView uses.
            guard event.keyCode == 3,
                  event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.option),
                  readingEngine == nil
            else { return event }
            NotificationCenter.default.post(name: .openSearch, object: nil)
            return nil
        }
    }

    private func removeLocalCommandFMonitor() {
        if let monitor = localCommandFMonitor {
            NSEvent.removeMonitor(monitor)
            localCommandFMonitor = nil
        }
    }
}
