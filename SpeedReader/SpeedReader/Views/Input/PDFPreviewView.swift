import SwiftUI
import PDFKit
import WebKit

/// SwiftUI wrapper for PDFKit's PDFView
struct PDFPreviewView: NSViewRepresentable {
    let url: URL
    /// Out-binding for the underlying `PDFView`. `SearchablePDFContainer` uses this ref
    /// to drive ⌘F search via `PDFSearchTarget`.
    var pdfViewRef: Binding<PDFView?>? = nil

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor.textBackgroundColor

        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }

        if let pdfViewRef {
            DispatchQueue.main.async { pdfViewRef.wrappedValue = pdfView }
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            if let document = PDFDocument(url: url) {
                pdfView.document = document
            }
        }
    }
}

// MARK: - Highlighted PDF Preview View

/// PDF view that highlights the current word being read
struct HighlightedPDFPreviewView: NSViewRepresentable {
    let url: URL
    @ObservedObject var engine: RSVPEngine
    /// Out-binding for the underlying `PDFView` — see `PDFPreviewView.pdfViewRef`.
    var pdfViewRef: Binding<PDFView?>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor.textBackgroundColor

        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }

        if let pdfViewRef {
            DispatchQueue.main.async { pdfViewRef.wrappedValue = pdfView }
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            if let document = PDFDocument(url: url) {
                pdfView.document = document
                context.coordinator.lastSearchPosition = nil
            }
        }

        highlightCurrentWord(in: pdfView, context: context)
    }

    private func highlightCurrentWord(in pdfView: PDFView, context: Context) {
        guard let document = pdfView.document else { return }

        let currentIndex = engine.currentIndex
        let currentWord = engine.currentWord
        guard !currentWord.isEmpty else {
            context.coordinator.clearHighlight(in: document)
            return
        }

        // Placeholder beats from MarkdownPreviewView ("formula" / "image" / "code") don't
        // correspond to any PDF text, so attempting to find them is either wasted work or
        // (worse) lands on a stray match. Keep the previous highlight in place.
        if RSVPEngine.placeholderWords.contains(currentWord) {
            return
        }

        // Use index (not word text) to detect change — same word can appear multiple times
        if currentIndex == context.coordinator.lastHighlightedIndex &&
           context.coordinator.currentHighlightAnnotation != nil {
            return
        }

        context.coordinator.clearHighlight(in: document)

        if let selection = findWordInDocument(currentWord, document: document, context: context) {
            context.coordinator.addHighlight(for: selection, in: document, index: currentIndex)

            if let page = selection.pages.first {
                let bounds = selection.bounds(for: page)

                if page !== context.coordinator.currentPage {
                    let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: bounds.maxY + 20))
                    pdfView.go(to: destination)
                    context.coordinator.currentPage = page
                } else {
                    let wordRectInView = pdfView.convert(bounds, from: page)
                    let visibleRect = pdfView.documentView?.visibleRect ?? .zero
                    if !visibleRect.contains(wordRectInView) {
                        let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: bounds.maxY + 20))
                        pdfView.go(to: destination)
                    }
                }
            }
        }
    }

    private func findWordInDocument(_ word: String, document: PDFDocument, context: Context) -> PDFSelection? {
        let cleanWord = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        guard !cleanWord.isEmpty else { return nil }

        // 1. Try sequential search from last known position
        if let lastPosition = context.coordinator.lastSearchPosition {
            if let selection = document.findString(cleanWord, fromSelection: lastPosition, withOptions: [.caseInsensitive]) {
                return selection
            }
        }

        // 2. Sequential search failed — find all occurrences and pick closest by page + Y position
        let selections = document.findString(cleanWord, withOptions: [.caseInsensitive])
        guard !selections.isEmpty else { return nil }
        if selections.count == 1 { return selections.first }

        guard let currentPage = context.coordinator.currentPage else {
            return selections.first
        }

        let currentPageIndex = document.index(for: currentPage)
        let lastY = context.coordinator.lastHighlightBoundsY

        var bestSelection = selections[0]
        var bestScore = Double.infinity

        for sel in selections {
            guard let page = sel.pages.first else { continue }
            let pageIdx = document.index(for: page)
            let bounds = sel.bounds(for: page)

            // Page distance weighted heavily, then Y proximity within page
            let pageDist = Double(abs(pageIdx - currentPageIndex)) * 100000.0
            let yDist: Double
            if let lastY = lastY, pageIdx == currentPageIndex {
                // Prefer selections below or near the last position (reading flows downward)
                let dy = lastY - bounds.midY  // positive = below last (PDF Y is bottom-up)
                yDist = dy < 0 ? abs(dy) * 2.0 : dy  // penalize going backward (up)
            } else {
                yDist = abs(bounds.midY)
            }
            let score = pageDist + yDist

            if score < bestScore {
                bestScore = score
                bestSelection = sel
            }
        }
        return bestSelection
    }

    // MARK: - Coordinator

    class Coordinator {
        var lastSearchPosition: PDFSelection?
        var lastHighlightedIndex: Int = -1
        var currentHighlightAnnotation: PDFAnnotation?
        var currentPage: PDFPage?
        /// Y midpoint of the last highlighted word (in page coordinates, origin bottom-left)
        var lastHighlightBoundsY: Double?

        func addHighlight(for selection: PDFSelection, in document: PDFDocument, index: Int) {
            guard let page = selection.pages.first else { return }
            let bounds = selection.bounds(for: page)

            let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            highlight.color = HighlightStyle.nsColor(for: .readingActive)

            page.addAnnotation(highlight)
            currentHighlightAnnotation = highlight
            lastSearchPosition = selection
            lastHighlightedIndex = index
            lastHighlightBoundsY = bounds.midY
        }

        func clearHighlight(in document: PDFDocument) {
            if let annotation = currentHighlightAnnotation,
               let page = annotation.page {
                page.removeAnnotation(annotation)
            }
            currentHighlightAnnotation = nil
        }
    }
}

// MARK: - OCR Highlighted PDF Preview View

/// PDF view that highlights the current word using OCR-derived bounding boxes
struct OCRHighlightedPDFPreviewView: NSViewRepresentable {
    let url: URL
    @ObservedObject var engine: RSVPEngine
    let wordLocations: [OCRWordLocation?]
    /// Out-binding for the underlying `PDFView` — see `PDFPreviewView.pdfViewRef`.
    var pdfViewRef: Binding<PDFView?>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor.textBackgroundColor

        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }

        if let pdfViewRef {
            DispatchQueue.main.async { pdfViewRef.wrappedValue = pdfView }
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            if let document = PDFDocument(url: url) {
                pdfView.document = document
                context.coordinator.currentPageIndex = -1
            }
        }

        highlightCurrentWord(in: pdfView, context: context)
    }

    private func highlightCurrentWord(in pdfView: PDFView, context: Context) {
        guard let document = pdfView.document else { return }

        // Placeholder beats from MarkdownPreviewView ("formula" / "image" / "code"): keep the
        // previous highlight rather than clearing it, mirroring HighlightedPDFPreviewView.
        if RSVPEngine.placeholderWords.contains(engine.currentWord) {
            return
        }

        let index = engine.currentIndex
        guard index < wordLocations.count,
              let location = wordLocations[index] else {
            context.coordinator.clearHighlight(in: document)
            return
        }

        if index == context.coordinator.lastHighlightedIndex {
            return
        }

        context.coordinator.clearHighlight(in: document)

        guard let page = document.page(at: location.pageIndex) else { return }

        let highlight = PDFAnnotation(bounds: location.rect, forType: .highlight, withProperties: nil)
        highlight.color = ReaderSettings.shared.highlightColorPreset.nsColor
        page.addAnnotation(highlight)

        context.coordinator.currentHighlightAnnotation = highlight
        context.coordinator.lastHighlightedIndex = index

        // Auto-scroll: go to page if changed, or scroll if word is off-screen
        if location.pageIndex != context.coordinator.currentPageIndex {
            let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: location.rect.maxY + 20))
            pdfView.go(to: destination)
            context.coordinator.currentPageIndex = location.pageIndex
        } else {
            let wordRectInView = pdfView.convert(location.rect, from: page)
            let visibleRect = pdfView.documentView?.visibleRect ?? .zero
            if !visibleRect.contains(wordRectInView) {
                let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: location.rect.maxY + 20))
                pdfView.go(to: destination)
            }
        }
    }

    class Coordinator {
        var lastHighlightedIndex: Int = -1
        var currentPageIndex: Int = -1
        var currentHighlightAnnotation: PDFAnnotation?

        func clearHighlight(in document: PDFDocument) {
            if let annotation = currentHighlightAnnotation,
               let page = annotation.page {
                page.removeAnnotation(annotation)
            }
            currentHighlightAnnotation = nil
        }
    }
}

/// Generic file preview - shows PDF, rendered Markdown, or plain text
@available(macOS 13.0, *)
struct FilePreviewView: View {
    let url: URL
    var engine: RSVPEngine?
    /// Pre-parsed document content (used for formats like FB2)
    var documentContent: DocumentContent?
    /// Whether OCR was used — disables word highlighting in PDF (positions don't match)
    var usedOCR: Bool = false
    /// OCR-derived word locations for highlighting on scanned PDFs
    var ocrWordLocations: [OCRWordLocation?]? = nil
    /// When true, clicking a word in the preview selects it as the start position
    var isSelectingStart: Bool = false
    /// The currently selected word index (shown as highlight)
    @Binding var selectedWordIndex: Int?
    /// Called when the user clicks a word in selection mode
    var onWordSelected: ((Int) -> Void)? = nil
    /// Called once after markdown WebView renders with DOM-extracted plain text
    var onTextExtracted: ((String) -> Void)? = nil
    /// Called once after markdown renders with the JS-walker-extracted
    /// `wordIndex → PauseableBlock` map. Only Markdown previews emit this —
    /// other formats build the map server-side via their own readers.
    var onPauseableBlocksExtracted: (([Int: PauseableBlock]) -> Void)? = nil
    /// Called when the user moves to/from the Edit tab in tabbed previews
    /// (PDF / Markdown). The parent uses this to hide controls that don't
    /// apply to a plain TextEditor.
    var onEditTabActiveChanged: ((Bool) -> Void)? = nil
    /// Leading content of the preview's unified top toolbar (file chip).
    var toolbarLeading: AnyView = AnyView(EmptyView())
    /// Trailing controls of the preview's unified top toolbar (Set start position, Contents).
    var toolbarTrailing: AnyView = AnyView(EmptyView())

    @State private var bookWebView: WKWebView? = nil
    @State private var docxWebView: WKWebView? = nil

    private var ext: String { url.pathExtension.lowercased() }
    private var isPDF: Bool { ext == "pdf" }
    private var isMarkdown: Bool { ext == "md" || ext == "markdown" }
    private var isBook: Bool { ext == "fb2" || ext == "epub" }
    private var isDOCX: Bool { ext == "docx" }
    private var isImage: Bool { ImageReader.supportedExtensions.contains(ext) }

    var body: some View {
        Group {
            if isPDF {
                // Use tabbed preview with Original PDF, Markdown Preview, and Edit modes
                PDFTabsPreviewView(
                    url: url,
                    originalMarkdown: documentContent?.markdownText,
                    engine: engine,
                    documentContent: documentContent,
                    usedOCR: usedOCR,
                    ocrWordLocations: ocrWordLocations,
                    isSelectingStart: isSelectingStart,
                    selectedWordIndex: selectedWordIndex,
                    onWordSelected: onWordSelected,
                    onTextExtracted: onTextExtracted,
                    onPauseableBlocksExtracted: onPauseableBlocksExtracted,
                    onEditTabActiveChanged: onEditTabActiveChanged,
                    toolbarLeading: toolbarLeading,
                    toolbarTrailing: toolbarTrailing
                )
            } else if isMarkdown {
                MarkdownTabsPreviewView(
                    url: url,
                    engine: engine,
                    isSelectingStart: isSelectingStart,
                    selectedWordIndex: selectedWordIndex,
                    onWordSelected: onWordSelected,
                    onTextExtracted: onTextExtracted,
                    onPauseableBlocksExtracted: onPauseableBlocksExtracted,
                    onEditTabActiveChanged: onEditTabActiveChanged,
                    toolbarLeading: toolbarLeading,
                    toolbarTrailing: toolbarTrailing
                )
            } else if isBook, let content = documentContent {
                SearchablePreviewContainer(
                    webViewRef: $bookWebView,
                    isEnabled: engine == nil,
                    onStartFromHere: onWordSelected,
                    toolbarLeading: toolbarLeading,
                    toolbarTrailing: toolbarTrailing,
                    alwaysShowsToolbar: true
                ) {
                    if let engine = engine {
                        ObservedBookPreviewWithTOC(
                            blocks: content.blocks,
                            title: content.title,
                            toc: content.toc,
                            engine: engine,
                            webViewRef: $bookWebView
                        )
                    } else {
                        BookPreviewWithTOC(
                            toc: content.toc,
                            currentIndex: selectedWordIndex ?? 0,
                            onSelect: { entry in onWordSelected?(entry.wordIndex) }
                        ) {
                            BookPreviewView(
                                blocks: content.blocks,
                                title: content.title,
                                wordIndex: selectedWordIndex ?? -1,
                                isSelectingStart: isSelectingStart,
                                highlightRole: .startMarker,
                                onWordSelected: onWordSelected,
                                webViewRef: $bookWebView
                            )
                        }
                    }
                }
            } else if isDOCX, let content = documentContent {
                SearchablePreviewContainer(
                    webViewRef: $docxWebView,
                    isEnabled: engine == nil,
                    onStartFromHere: onWordSelected,
                    toolbarLeading: toolbarLeading,
                    toolbarTrailing: toolbarTrailing,
                    alwaysShowsToolbar: true
                ) {
                    if let engine = engine {
                        ObservedDOCXPreviewWithTOC(
                            blocks: content.blocks,
                            title: content.title,
                            toc: content.toc,
                            engine: engine,
                            webViewRef: $docxWebView
                        )
                    } else {
                        BookPreviewWithTOC(
                            toc: content.toc,
                            currentIndex: selectedWordIndex ?? 0,
                            onSelect: { entry in onWordSelected?(entry.wordIndex) }
                        ) {
                            DOCXPreviewView(
                                blocks: content.blocks,
                                title: content.title,
                                wordIndex: selectedWordIndex ?? -1,
                                isSelectingStart: isSelectingStart,
                                highlightRole: .startMarker,
                                onWordSelected: onWordSelected,
                                webViewRef: $docxWebView
                            )
                        }
                    }
                }
            } else if isImage {
                VStack(spacing: 0) {
                    PreviewToolbarRow(leading: toolbarLeading, trailing: toolbarTrailing) { EmptyView() }
                    if let content = documentContent {
                        // After OCR: show extracted text (like area capture)
                        if let engine = engine {
                            HighlightedTextView(text: content.plainText, engine: engine)
                        } else {
                            ScrollView {
                                Text(content.plainText)
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        ImageFilePreviewView(url: url)
                    }
                }
            } else {
                // Plain text files — load from file directly
                if let engine = engine {
                    VStack(spacing: 0) {
                        PreviewToolbarRow(leading: toolbarLeading, trailing: toolbarTrailing) { EmptyView() }
                        HighlightedTextFilePreviewView(url: url, engine: engine)
                    }
                } else if #available(macOS 14.0, *), let content = documentContent {
                    SearchableTextContainer(
                        text: content.plainText,
                        onStartFromHere: { selectedWordIndex = $0 },
                        toolbarLeading: toolbarLeading,
                        toolbarTrailing: toolbarTrailing,
                        alwaysShowsToolbar: true
                    ) { matches, active in
                        ClickableTextPreview(
                            text: content.plainText,
                            selectedWordIndex: $selectedWordIndex,
                            searchMatchIndices: matches,
                            activeSearchIndex: active,
                            selectionEnabled: isSelectingStart
                        )
                    }
                } else {
                    VStack(spacing: 0) {
                        PreviewToolbarRow(leading: toolbarLeading, trailing: toolbarTrailing) { EmptyView() }
                        TextFilePreviewView(url: url)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

/// Preview for text-based files
struct TextFilePreviewView: View {
    let url: URL
    @State private var content: String = ""

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .onAppear {
            loadContent()
        }
    }

    private func loadContent() {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            content = text
        } else if let text = try? String(contentsOf: url, encoding: .ascii) {
            content = text
        }
    }
}

/// Preview for text files with word highlighting
@available(macOS 13.0, *)
struct HighlightedTextFilePreviewView: View {
    let url: URL
    @ObservedObject var engine: RSVPEngine
    @State private var content: String = ""

    var body: some View {
        HighlightedTextView(text: content, engine: engine)
            .onAppear {
                loadContent()
            }
    }

    private func loadContent() {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            content = text
        } else if let text = try? String(contentsOf: url, encoding: .ascii) {
            content = text
        }
    }
}

/// Preview for image files — displays the original image
struct ImageFilePreviewView: View {
    let url: URL

    var body: some View {
        ScrollView {
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(12)
            } else {
                Text("Unable to load image")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
