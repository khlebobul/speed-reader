import SwiftUI
import WebKit

/// Tab options for Markdown preview
enum MarkdownPreviewTab: String, CaseIterable, Identifiable {
    case preview = "Preview"
    case edit = "Edit"

    var id: String { rawValue }
}

/// Markdown preview with two tabs: rendered Preview and editable raw source.
/// Edits are session-only — never written back to the file.
@available(macOS 13.0, *)
struct MarkdownTabsPreviewView: View {
    var url: URL? = nil
    var markdownString: String? = nil
    var engine: RSVPEngine?
    var isSelectingStart: Bool = false
    var selectedWordIndex: Int?
    var onWordSelected: ((Int) -> Void)?
    var onTextExtracted: ((String) -> Void)?
    /// Emits raw Markdown edits for inline Text-tab sources. File previews keep
    /// edits session-local and do not pass this callback.
    var onMarkdownEdited: ((String) -> Void)?
    /// Receives the JS-computed `wordIndex → PauseableBlock` map after each render.
    /// The Swift `MarkdownReader.parseBlocks` cannot agree with the JS walker on
    /// word indices (inline `$…$`, images, typography all diverge), so this
    /// callback is the authoritative source for auto-pause positions in markdown.
    var onPauseableBlocksExtracted: (([Int: PauseableBlock]) -> Void)?
    /// Notifies the parent when the user is on the Edit tab — used to hide
    /// document-only controls (e.g. "Set start position") that don't apply to
    /// a plain TextEditor.
    var onEditTabActiveChanged: ((Bool) -> Void)?
    /// Leading content of the unified top toolbar (file chip). The tab picker
    /// is appended to this so it shares the one control row.
    var toolbarLeading: AnyView = AnyView(EmptyView())
    /// Trailing controls of the unified top toolbar (Set start position).
    var toolbarTrailing: AnyView = AnyView(EmptyView())

    @State private var selectedTab: MarkdownPreviewTab = .preview
    @State private var originalMarkdown: String = ""
    @State private var editedMarkdown: String = ""
    @State private var previewSnapshot: String = ""
    @State private var didLoad: Bool = false
    @State private var showingResetConfirmation = false
    @State private var previewWebView: WKWebView? = nil
    /// TOC populated from the DOM walker that also produces the engine's word
    /// list — so `entry.wordIndex` matches `engine.currentIndex` exactly even
    /// when the document has formulas, code blocks, images, or tables that the
    /// Swift block parser counts differently. `nil` until JS posts, or when
    /// the document has no headings.
    @State private var toc: TableOfContents? = nil

    /// While reading is active the tab UI is hidden and Preview is always shown,
    /// so highlighting stays visible regardless of which tab the user picked before.
    private var isReading: Bool { engine != nil }
    private var effectiveTab: MarkdownPreviewTab { isReading ? .preview : selectedTab }

    /// The tab picker — hidden during reading (Preview is forced then).
    private var tabPicker: some View {
        Picker("View", selection: $selectedTab) {
            ForEach(MarkdownPreviewTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .labelsHidden()
    }

    /// File chip + tab picker — leading content of the one unified control row.
    private var effectiveLeading: AnyView {
        AnyView(
            HStack(spacing: 10) {
                toolbarLeading
                if !isReading { tabPicker }
            }
        )
    }

    /// Reset (Edit tab only) + the parent's trailing controls.
    private var effectiveTrailing: AnyView {
        AnyView(
            HStack(spacing: 8) {
                if !isReading && selectedTab == .edit && editedMarkdown != originalMarkdown {
                    Button(action: { showingResetConfirmation = true }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help("Reset to original file content")
                }
                toolbarTrailing
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content based on effective tab (Preview is forced during reading).
            // The tab picker lives in each tab's unified toolbar.
            Group {
                switch effectiveTab {
                case .preview:
                    markdownPreviewView
                case .edit:
                    VStack(spacing: 0) {
                        PreviewToolbarRow(leading: effectiveLeading, trailing: effectiveTrailing) { EmptyView() }
                        markdownEditorView
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            loadIfNeeded()
            onEditTabActiveChanged?(effectiveTab == .edit)
        }
        .onChange(of: url) { reloadSource() }
        .onChange(of: markdownString) { _, newValue in
            guard let newValue, newValue != editedMarkdown else { return }
            loadInlineMarkdown(newValue)
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .preview && editedMarkdown != previewSnapshot {
                previewSnapshot = editedMarkdown
            }
            onEditTabActiveChanged?(isReading ? false : newTab == .edit)
        }
        .onChange(of: isReading) { _, reading in
            // Reading forces Preview — propagate that to the parent so any
            // edit-only chrome (start-position toggle) appears/disappears.
            onEditTabActiveChanged?(reading ? false : selectedTab == .edit)
            // Reading is forced into Preview — make sure the snapshot reflects
            // any pending edits the user made before pressing play.
            if reading && editedMarkdown != previewSnapshot {
                previewSnapshot = editedMarkdown
            }
        }
        .confirmationDialog(
            "Reset to Original?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetToOriginal()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits will be lost. This cannot be undone.")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var markdownPreviewView: some View {
        SearchablePreviewContainer(
            webViewRef: $previewWebView,
            isEnabled: !isReading,
            onStartFromHere: onWordSelected,
            toolbarLeading: effectiveLeading,
            toolbarTrailing: effectiveTrailing,
            alwaysShowsToolbar: true
        ) {
            // TOC sidebar wraps the WKWebView. The same generic container used by
            // Book/EPUB — clicks here either seek the engine (reading) or set the
            // parent's `selectedWordIndex` (non-reading), which propagates back as
            // `wordIndex` and triggers `highlightWordAt` + `scrollIntoView` in JS.
            BookPreviewWithTOC(
                toc: toc,
                currentIndex: engine?.currentIndex ?? selectedWordIndex ?? 0,
                onSelect: { entry in
                    if let engine {
                        engine.seekTo(entry.wordIndex)
                    } else {
                        onWordSelected?(entry.wordIndex)
                    }
                }
            ) {
                markdownPreviewContent
            }
        }
        .onChange(of: previewSnapshot) { _, _ in
            // The WKWebView re-renders via `.id(previewSnapshot)` and JS will
            // post a fresh `tocExtracted`. Clear the stale TOC immediately so
            // the sidebar doesn't briefly show indices for the old document.
            toc = nil
        }
    }

    @ViewBuilder
    private var markdownPreviewContent: some View {
        if previewSnapshot.isEmpty && !didLoad {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let engine = engine {
            ObservedMarkdownPreviewView(
                markdownString: previewSnapshot,
                engine: engine,
                onTextExtracted: onTextExtracted,
                onTOCExtracted: applyDOMTOC,
                onPauseableBlocksExtracted: onPauseableBlocksExtracted,
                webViewRef: $previewWebView
            )
            .id(previewSnapshot)
        } else {
            MarkdownPreviewView(
                markdownString: previewSnapshot,
                wordIndex: selectedWordIndex ?? -1,
                isSelectingStart: isSelectingStart,
                highlightRole: .startMarker,
                onWordSelected: onWordSelected,
                onTextExtracted: onTextExtracted,
                onTOCExtracted: applyDOMTOC,
                onPauseableBlocksExtracted: onPauseableBlocksExtracted,
                webViewRef: $previewWebView
            )
            .id(previewSnapshot)
        }
    }

    /// Converts DOM-extracted heading entries (whose `wordIndex` already lines
    /// up with `RSVPEngine.currentIndex`) into a nested `TableOfContents`.
    private func applyDOMTOC(_ entries: [MarkdownDOMTOCEntry]) {
        guard !entries.isEmpty else { toc = nil; return }
        let flat = entries.map {
            FlatTOCItem(title: $0.title, level: $0.level, wordIndex: $0.wordIndex)
        }
        toc = TableOfContents(entries: TableOfContents.nest(flat))
    }

    private var markdownEditorView: some View {
        VStack(spacing: 0) {
            TextEditor(text: $editedMarkdown)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: editedMarkdown) {
                    syncEditedTextToEngine()
                }

            Divider()

            HStack {
                Text("\(wordCount) words")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()

                if editedMarkdown != originalMarkdown {
                    Text("Edited")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    // MARK: - Helpers

    private var wordCount: Int {
        let text = MarkdownReader.plainText(fromMarkdown: editedMarkdown)
        return text.split(separator: " ").count
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        reloadSource()
    }

    private func reloadSource() {
        if let markdownString {
            loadInlineMarkdown(markdownString)
            return
        }

        reloadFromDisk()
    }

    private func loadInlineMarkdown(_ raw: String) {
        originalMarkdown = raw
        editedMarkdown = raw
        previewSnapshot = raw
        didLoad = true
    }

    private func reloadFromDisk() {
        let raw: String
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
            raw = text
        } else if let url, let text = try? String(contentsOf: url, encoding: .ascii) {
            raw = text
        } else {
            raw = ""
        }
        originalMarkdown = raw
        editedMarkdown = raw
        previewSnapshot = raw
        didLoad = true
    }

    private func resetToOriginal() {
        editedMarkdown = originalMarkdown
        previewSnapshot = originalMarkdown
        onMarkdownEdited?(originalMarkdown)
        // Explicit sync: engine may currently hold edited text — restore original.
        let plainText = MarkdownReader.plainText(fromMarkdown: originalMarkdown)
        onTextExtracted?(plainText)
    }

    private func syncEditedTextToEngine() {
        onMarkdownEdited?(editedMarkdown)
        // Skip when not actually edited — initial load and reverts use the
        // engine state already established by FileInputView / DOM extraction.
        guard didLoad, editedMarkdown != originalMarkdown else { return }
        let plainText = MarkdownReader.plainText(fromMarkdown: editedMarkdown)
        onTextExtracted?(plainText)
    }
}
