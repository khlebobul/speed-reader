import SwiftUI

struct URLInputView: View {
    @Binding var urlText: String
    @Binding var inputText: String
    @Binding var blocks: [TextBlock]?
    @Binding var toc: TableOfContents?
    @Binding var isLoadingURL: Bool
    @Binding var urlError: String?
    @Binding var selectedStartIndex: Int?
    var onLoadURL: () -> Void
    var readingEngine: RSVPEngine? = nil
    var onClose: (() -> Void)? = nil

    @ObservedObject private var recentURLs = RecentURLsManager.shared

    @State private var showBrowserTabList = false
    @State private var browserTabs: [BrowserURLReader.TabInfo] = []
    @State private var isDetectingTabs = false

    private var hasTOC: Bool { !(toc?.isEmpty ?? true) }

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasURL: Bool {
        URLValidator.looksValid(urlText)
    }

    private var urlValidationError: String? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch URLValidator.validate(urlText) {
        case .valid:
            return nil
        case .invalid(let error):
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content area — the URL field lives in the unified top toolbar
            if isLoadingURL {
                VStack(spacing: 0) {
                    PreviewToolbarRow(leading: AnyView(urlField)) { EmptyView() }
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading article...")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text("Pages behind a login may not load")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .previewCard()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                errorRow
            } else if hasText {
                Group {
                    if let engine = readingEngine {
                        ObservedURLReadingPreview(
                            text: inputText,
                            blocks: blocks,
                            toc: toc,
                            engine: engine,
                            toolbarLeading: AnyView(urlField),
                            toolbarTrailing: AnyView(contentsChip)
                        )
                    } else if #available(macOS 14.0, *) {
                        BookPreviewWithTOC(
                            toc: toc,
                            currentIndex: selectedStartIndex ?? -1,
                            onSelect: { entry in selectedStartIndex = entry.wordIndex },
                            topPadding: PreviewToolbarRow<EmptyView>.approximateHeight + 12
                        ) {
                            SearchableTextContainer(
                                text: inputText,
                                blocks: blocks,
                                onStartFromHere: { idx in selectedStartIndex = idx },
                                toolbarLeading: AnyView(urlField),
                                toolbarTrailing: AnyView(contentsChip),
                                alwaysShowsToolbar: true
                            ) { matches, active in
                                ClickableTextPreview(
                                    text: inputText,
                                    selectedWordIndex: $selectedStartIndex,
                                    blocks: blocks,
                                    searchMatchIndices: matches,
                                    activeSearchIndex: active
                                )
                            }
                        }
                    } else {
                        ClickableTextPreview(text: inputText, selectedWordIndex: $selectedStartIndex, blocks: blocks)
                    }
                }
                .previewCard()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                errorRow
            } else {
                PreviewToolbarRow(leading: AnyView(urlField)) { EmptyView() }
                    .previewCard()
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                errorRow

                browserButton
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                if showBrowserTabList || isDetectingTabs {
                    inlineBrowserTabList
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                }

                if recentURLs.entries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40, weight: .light))
                            .foregroundColor(.secondary.opacity(0.25))
                        Text("Enter a URL and click Load")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recent")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear All") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    recentURLs.clearAll()
                                }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(recentURLs.entries) { entry in
                                    RecentURLCard(entry: entry, onOpen: {
                                        urlText = entry.urlString
                                        onLoadURL()
                                    }, onRemove: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            recentURLs.remove(entry)
                                        }
                                    })
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 16)

                    Spacer(minLength: 16)
                }
            }

            // Word count (only in edit mode)
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
    }

    // MARK: - Toolbar leading: URL field

    private var urlField: some View {
        // During an active reading session the URL field is locked: typing /
        // submitting / Load are all disabled. Loading a different article while
        // the engine still holds the previous article's words would let the
        // user think they're reading the new article while the stream keeps
        // playing the old one (inputText / pauseableBlocks update in the
        // bindings, but engine state is frozen until the next `loadText`). The
        // close button is also hidden, so the only path forward is Stop in the
        // reader controls.
        let isReading = readingEngine != nil
        let inputDisabled = isLoadingURL || isReading
        return HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundColor(.secondary)
                .font(.system(size: 13))

            TextField("Enter article URL...", text: $urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .disabled(inputDisabled)
                .onSubmit {
                    if hasURL && urlValidationError == nil && !inputDisabled {
                        onLoadURL()
                    }
                }

            if isLoadingURL {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isLoadingURL ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isLoadingURL)
                    .frame(width: 18, height: 18)
            } else if isReading {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .help("Stop reading to load a different article")
            } else if hasText {
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else if hasURL && urlValidationError == nil {
                Button(action: onLoadURL) {
                    Text("Load")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 240)
        .background(Color(NSColor.textBackgroundColor).opacity(isReading ? 0.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Browser tab picker

    private func toggleBrowserTabList() {
        guard !isDetectingTabs else { return }

        if showBrowserTabList {
            withAnimation(.easeInOut(duration: 0.2)) {
                showBrowserTabList = false
            }
            return
        }

        if !browserTabs.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                showBrowserTabList = true
            }
            return
        }

        isDetectingTabs = true
        urlError = nil

        let result = BrowserURLReader.detectAllTabs()
        switch result {
        case .success(let (_, tabs)):
            browserTabs = tabs
            withAnimation(.easeInOut(duration: 0.2)) {
                showBrowserTabList = !tabs.isEmpty
            }
            if tabs.isEmpty {
                urlError = "No open tabs found"
            }
        case .failure(let error):
            urlError = error.message
        }

        isDetectingTabs = false
    }

    @ViewBuilder
    private var inlineBrowserTabList: some View {
        VStack(spacing: 0) {
            if isDetectingTabs {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Detecting browser tabs…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(browserTabs) { tab in
                            Button {
                                urlText = tab.url
                                showBrowserTabList = false
                                onLoadURL()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tab.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(domain(from: tab.url))
                                            .font(.system(size: 10, design: .monospaced))
                                            .lineLimit(1)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func domain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Browser button

    private var browserButton: some View {
        Button(action: toggleBrowserTabList) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("From Browser")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text("Choose an open browser tab")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: showBrowserTabList ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar trailing: TOC chip

    @ViewBuilder
    private var contentsChip: some View {
        if hasTOC {
            Button {
                NotificationCenter.default.post(name: .toggleTOC, object: nil)
            } label: {
                ToolbarChipLabel(icon: "list.bullet.indent", text: "Contents")
            }
            .buttonStyle(.plain)
            .help("Toggle table of contents (⌘⇧O)")
        }
    }

    // MARK: - Error row

    @ViewBuilder
    private var errorRow: some View {
        HStack(spacing: 6) {
            if let error = urlError ?? urlValidationError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .frame(height: 16)
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }
}

// MARK: - Reading-mode preview with TOC

/// Wraps the URL article's reading-mode preview in a `BookPreviewWithTOC`. Owns
/// the `@ObservedObject` engine so the sidebar's active-section highlight
/// updates as the RSVP stream advances, and tapping a TOC entry seeks the
/// engine — mirroring `ObservedBookPreviewWithTOC` for EPUB/FB2 and
/// `ObservedDOCXPreviewWithTOC` for DOCX.
@available(macOS 13.0, *)
private struct ObservedURLReadingPreview: View {
    let text: String
    let blocks: [TextBlock]?
    let toc: TableOfContents?
    @ObservedObject var engine: RSVPEngine
    let toolbarLeading: AnyView
    let toolbarTrailing: AnyView

    var body: some View {
        BookPreviewWithTOC(
            toc: toc,
            currentIndex: engine.currentIndex,
            onSelect: { entry in engine.seekTo(entry.wordIndex) },
            topPadding: PreviewToolbarRow<EmptyView>.approximateHeight + 12
        ) {
            VStack(spacing: 0) {
                PreviewToolbarRow(leading: toolbarLeading, trailing: toolbarTrailing) { EmptyView() }
                HighlightedTextView(text: text, engine: engine, blocks: blocks)
            }
        }
    }
}

// MARK: - Recent URL Card

private struct RecentURLCard: View {
    let entry: RecentURLEntry
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    private var domain: String {
        if let url = URL(string: entry.urlString), let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return entry.urlString
    }

    private var title: String {
        let t = entry.displayTitle
        return t.count > 28 ? String(t.prefix(26)) + "..." : t
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "globe")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)

                    if isHovered {
                        Button(action: onRemove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 2, y: -2)
                    }
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(domain)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 130)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.12 : 0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
}
