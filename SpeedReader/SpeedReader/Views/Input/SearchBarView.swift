import SwiftUI

/// Compact search field that mounts above preview content. Drives any `SearchTarget`.
/// ⌘F focuses it, Esc clears the query/highlights, Enter / Shift+Enter walks matches.
@available(macOS 13.0, *)
struct SearchBarView: View {
    let target: any SearchTarget
    var focusRequest: Int = 0
    var onClose: () -> Void = {}
    /// If provided, an extra "Read from here" button appears when there's an active match.
    /// The Int passed back is the RSVP word index of the active match.
    var onStartFromHere: ((Int) -> Void)? = nil

    @State private var query: String = ""
    @State private var matchCount: Int = 0
    @State private var currentMatch: Int = 0
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13))

            TextField("Search…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .frame(width: query.isEmpty ? 170 : 220)
                .onSubmit { Task { await stepNext() } }
                .onChange(of: query) { _, newValue in scheduleFind(newValue) }

            if !query.isEmpty {
                Text(matchCount > 0 ? "\(currentMatch + 1) / \(matchCount)" : "No matches")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(matchCount > 0 ? .secondary : .red)
                    .frame(minWidth: 64, alignment: .trailing)
                    .help(matchCount > 0 ? "Match \(currentMatch + 1) of \(matchCount)" : "")

                HStack(spacing: 2) {
                    Button(action: { Task { await stepPrev() } }) {
                        Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .help("Previous match (⇧⏎)")

                    Button(action: { Task { await stepNext() } }) {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .help("Next match (⏎)")
                }

                if let onStartFromHere, matchCount > 0 {
                    Button("Read from here") {
                        Task {
                            let idx = await target.activeWordIndex()
                            if idx >= 0 {
                                clear()
                                onStartFromHere(idx)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Start RSVP from the active match")
                }
            }

            if !query.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Clear search (Esc)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .onAppear {
            if focusRequest > 0 {
                focused = true
            }
        }
        .onChange(of: focusRequest) { _, _ in
            focused = true
        }
        .onDisappear {
            searchTask?.cancel()
            target.clear()
        }
        .onKeyPress(.escape, phases: .down) { _ in
            clear()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { event in
            if event.modifiers.contains(.shift) {
                Task { await stepPrev() }
            } else {
                Task { await stepNext() }
            }
            return .handled
        }
    }

    // MARK: - Actions

    private func scheduleFind(_ q: String) {
        searchTask?.cancel()
        searchTask = Task {
            // Debounce live typing so a long query doesn't stall the WKWebView.
            try? await Task.sleep(nanoseconds: 80_000_000)
            if Task.isCancelled { return }
            let count = await target.find(query: q)
            if Task.isCancelled { return }
            matchCount = count
            currentMatch = count > 0 ? 0 : 0
        }
    }

    private func stepNext() async {
        guard matchCount > 0 else { return }
        let idx = await target.next()
        if idx >= 0 { currentMatch = idx }
    }

    private func stepPrev() async {
        guard matchCount > 0 else { return }
        let idx = await target.prev()
        if idx >= 0 { currentMatch = idx }
    }

    private func clear() {
        searchTask?.cancel()
        query = ""
        matchCount = 0
        currentMatch = 0
        target.clear()
        onClose()
    }
}
