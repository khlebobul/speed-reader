import SwiftUI
import PDFKit
import WebKit

/// Tab options for PDF preview
enum PDFPreviewTab: String, CaseIterable, Identifiable {
    case original = "Original"
    case preview = "Preview"
    case edit = "Edit"

    var id: String { rawValue }
}

/// PDF preview with tabs: Original PDF, Rendered Markdown, and Editable Markdown
@available(macOS 13.0, *)
struct PDFTabsPreviewView: View {
    let url: URL
    let originalMarkdown: String?
    var engine: RSVPEngine?
    var documentContent: DocumentContent?
    var usedOCR: Bool = false
    var ocrWordLocations: [OCRWordLocation?]?
    var isSelectingStart: Bool = false
    var selectedWordIndex: Int?
    var onWordSelected: ((Int) -> Void)?
    var onTextExtracted: ((String) -> Void)?
    /// Receives the JS-computed `wordIndex → PauseableBlock` map after each
    /// markdown render. The Swift-side `pauseableBlocks` from
    /// `PDFDocumentReader` are indexed against the PDF reader's plainText,
    /// which does not agree with the JS DOM walker's word stream after
    /// PDF→md conversion (the engine reloads to the JS text via
    /// `onTextExtracted`). This callback is the authoritative source for
    /// auto-pause positions while the Preview tab is the active view.
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

    @State private var selectedTab: PDFPreviewTab
    @State private var editedMarkdown: String
    @State private var showingResetConfirmation = false
    @State private var pdfViewRef: PDFView? = nil
    @State private var markdownWebViewRef: WKWebView? = nil

    init(
        url: URL,
        originalMarkdown: String?,
        engine: RSVPEngine? = nil,
        documentContent: DocumentContent? = nil,
        usedOCR: Bool = false,
        ocrWordLocations: [OCRWordLocation?]? = nil,
        isSelectingStart: Bool = false,
        selectedWordIndex: Int? = nil,
        onWordSelected: ((Int) -> Void)? = nil,
        onTextExtracted: ((String) -> Void)? = nil,
        onPauseableBlocksExtracted: (([Int: PauseableBlock]) -> Void)? = nil,
        onEditTabActiveChanged: ((Bool) -> Void)? = nil,
        toolbarLeading: AnyView = AnyView(EmptyView()),
        toolbarTrailing: AnyView = AnyView(EmptyView())
    ) {
        self.url = url
        self.originalMarkdown = originalMarkdown
        self.engine = engine
        self.documentContent = documentContent
        self.usedOCR = usedOCR
        self.ocrWordLocations = ocrWordLocations
        self.isSelectingStart = isSelectingStart
        self.selectedWordIndex = selectedWordIndex
        self.onWordSelected = onWordSelected
        self.onTextExtracted = onTextExtracted
        self.onPauseableBlocksExtracted = onPauseableBlocksExtracted
        self.onEditTabActiveChanged = onEditTabActiveChanged
        self.toolbarLeading = toolbarLeading
        self.toolbarTrailing = toolbarTrailing

        // Default to Preview if markdown available, otherwise Original
        let hasMarkdown = originalMarkdown != nil && !(originalMarkdown?.isEmpty ?? true)
        _selectedTab = State(initialValue: hasMarkdown ? .preview : .original)
        _editedMarkdown = State(initialValue: originalMarkdown ?? "")
    }

    /// The tab picker, merged into the unified toolbar's leading slot.
    private var tabPicker: some View {
        Picker("View", selection: $selectedTab) {
            ForEach(PDFPreviewTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
        .labelsHidden()
    }

    /// File chip + tab picker — the leading content of the one unified control row.
    private var effectiveLeading: AnyView {
        AnyView(
            HStack(spacing: 10) {
                toolbarLeading
                tabPicker
            }
        )
    }

    /// Reset (Edit tab only) + the parent's trailing controls.
    private var effectiveTrailing: AnyView {
        AnyView(
            HStack(spacing: 8) {
                if selectedTab == .edit && editedMarkdown != originalMarkdown {
                    Button(action: { showingResetConfirmation = true }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help("Reset to original extracted text")
                }
                toolbarTrailing
            }
        )
    }

    var body: some View {
        // One `BookPreviewWithTOC` around all three tabs so the sidebar state
        // survives Original ↔ Preview ↔ Edit switches. Each tab renders its
        // own `PreviewToolbarRow`-style toolbar at the top of its content, so
        // we pass `topPadding` to make the floating panel slide in below the
        // toolbar instead of covering its chips.
        BookPreviewWithTOC(
            toc: documentContent?.toc,
            currentIndex: engine?.currentIndex ?? selectedWordIndex ?? 0,
            onSelect: handleTOCSelect,
            topPadding: PreviewToolbarRow<EmptyView>.approximateHeight + 12
        ) {
            VStack(spacing: 0) {
                // Content based on selected tab — the tab picker lives in each
                // tab's unified toolbar (or a standalone one for the Edit tab).
                Group {
                    switch selectedTab {
                    case .original:
                        if #available(macOS 14.0, *) {
                            SearchablePDFContainer(
                                pdfViewRef: $pdfViewRef,
                                wordLocations: documentContent?.ocrWordLocations,
                                isEnabled: engine == nil,
                                onStartFromHere: onWordSelected,
                                toolbarLeading: effectiveLeading,
                                toolbarTrailing: effectiveTrailing,
                                alwaysShowsToolbar: true
                            ) {
                                originalPDFView
                            }
                        } else {
                            originalPDFView
                        }
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
            .onAppear { onEditTabActiveChanged?(selectedTab == .edit) }
            .onChange(of: selectedTab) { _, newTab in
                onEditTabActiveChanged?(newTab == .edit)
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
    }

    /// Handles a TOC entry tap across all three tabs:
    /// 1. Seek the engine when reading; otherwise update the parent's
    ///    `selectedWordIndex` so the markdown preview's highlight + scroll
    ///    follow on the Preview tab.
    /// 2. Scroll the underlying `PDFView` to the target page so the Original
    ///    tab is on the right page when the user lands there. Highlight
    ///    follow-up on Original is handled by the existing OCR/word-location
    ///    pipeline once the engine seeks.
    private func handleTOCSelect(_ entry: TOCEntry) {
        if let engine {
            engine.seekTo(entry.wordIndex)
        } else {
            onWordSelected?(entry.wordIndex)
        }

        guard let blocks = documentContent?.blocks,
              let pdfView = pdfViewRef,
              let pdfDoc = pdfView.document else { return }

        if let pageNum = pageNumberForEntry(entry, blocks: blocks),
           pageNum >= 1, pageNum <= pdfDoc.pageCount,
           let page = pdfDoc.page(at: pageNum - 1) {
            pdfView.go(to: page)
        }
    }

    /// Resolves a TOC entry to a 1-based PDF page number using whichever
    /// signal the entry carries: `blockIndex` (set by PDFKit-outline /
    /// block-heading TOCs) or, for markdown-derived entries, a title
    /// substring match against the block text.
    private func pageNumberForEntry(_ entry: TOCEntry, blocks: [TextBlock]) -> Int? {
        // 1. Direct mapping when the entry was built from a block-based source.
        if let blockIndex = entry.blockIndex,
           blockIndex < blocks.count,
           let pageNum = blocks[blockIndex].pageNumber {
            return pageNum
        }

        // 2. Markdown-derived entries carry no blockIndex (the scanner doesn't
        //    know about Swift blocks). Match the heading title against block
        //    text. Headings in PDFs are often a leading fragment of a longer
        //    paragraph block, so a `contains` check is the realistic shape.
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // Compare on a normalized form so footnote markers / whitespace
        // differences between markdown and block text don't cause a miss.
        let needle = normalizeForMatch(title)
        guard !needle.isEmpty else { return nil }

        if let match = blocks.first(where: { normalizeForMatch($0.text).contains(needle) }) {
            return match.pageNumber
        }

        // 3. Last resort: try matching just the first few words of the title.
        let firstWords = title.split(separator: " ").prefix(3).joined(separator: " ")
        if firstWords != title {
            let shortNeedle = normalizeForMatch(firstWords)
            if !shortNeedle.isEmpty,
               let match = blocks.first(where: { normalizeForMatch($0.text).contains(shortNeedle) }) {
                return match.pageNumber
            }
        }

        return nil
    }

    /// Lowercases and collapses non-alphanumeric runs to single spaces so
    /// markdown headings ("FROM WIKIBOOKS^1") line up with their block-text
    /// counterparts ("FROM WIKIBOOKS 1") for `contains` matching.
    private func normalizeForMatch(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastWasSpace = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var originalPDFView: some View {
        // Keep the selectable view mounted whenever reading isn't active so the
        // start marker (from a TOC click / Read-from-here / manual click) stays
        // visible until the engine takes over. Clicks always re-pick the start;
        // the parent decides whether to start reading via its own toolbar.
        if engine == nil, let locations = ocrWordLocations, !locations.isEmpty {
            SelectablePDFPreviewView(
                url: url,
                wordLocations: locations,
                selectedWordIndex: selectedWordIndex,
                onWordSelected: onWordSelected,
                pdfViewRef: $pdfViewRef
            )
        } else if let engine = engine {
            if usedOCR, let locations = ocrWordLocations, !locations.isEmpty {
                OCRHighlightedPDFPreviewView(
                    url: url,
                    engine: engine,
                    wordLocations: locations,
                    pdfViewRef: $pdfViewRef
                )
            } else {
                HighlightedPDFPreviewView(url: url, engine: engine, pdfViewRef: $pdfViewRef)
            }
        } else {
            PDFPreviewView(url: url, pdfViewRef: $pdfViewRef)
        }
    }

    @ViewBuilder
    private var markdownPreviewView: some View {
        if let md = effectiveMarkdown {
            if #available(macOS 14.0, *) {
                SearchablePreviewContainer(
                    webViewRef: $markdownWebViewRef,
                    isEnabled: engine == nil,
                    onStartFromHere: onWordSelected,
                    toolbarLeading: effectiveLeading,
                    toolbarTrailing: effectiveTrailing,
                    alwaysShowsToolbar: true
                ) {
                    markdownPreviewContent(md: md)
                }
            } else {
                markdownPreviewContent(md: md)
            }
        } else {
            // Fallback to original if no markdown
            originalPDFView
        }
    }

    @ViewBuilder
    private func markdownPreviewContent(md: String) -> some View {
        if let engine = engine {
            ObservedMarkdownPreviewView(
                markdownString: md,
                engine: engine,
                onTextExtracted: onTextExtracted,
                onPauseableBlocksExtracted: onPauseableBlocksExtracted,
                webViewRef: $markdownWebViewRef
            )
        } else {
            MarkdownPreviewView(
                markdownString: md,
                wordIndex: selectedWordIndex ?? -1,
                isSelectingStart: isSelectingStart,
                highlightRole: .startMarker,
                onWordSelected: onWordSelected,
                onPauseableBlocksExtracted: onPauseableBlocksExtracted,
                webViewRef: $markdownWebViewRef
            )
        }
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

    private var effectiveMarkdown: String? {
        // Use edited version if in edit mode, otherwise original
        if selectedTab == .edit {
            return editedMarkdown.isEmpty ? nil : editedMarkdown
        }
        return originalMarkdown
    }

    private var wordCount: Int {
        let text = PDF2MDExtractor.plainText(fromMarkdown: editedMarkdown)
        return text.split(separator: " ").count
    }

    private func resetToOriginal() {
        editedMarkdown = originalMarkdown ?? ""
        syncEditedTextToEngine()
    }

    private func syncEditedTextToEngine() {
        let plainText = PDF2MDExtractor.plainText(fromMarkdown: editedMarkdown)
        onTextExtracted?(plainText)
    }
}
