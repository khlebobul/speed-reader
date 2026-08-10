import SwiftUI
import AppKit
import UniformTypeIdentifiers

@available(macOS 13.0, *)
struct FileInputView: View {
    @Binding var inputText: String
    @Binding var selectedStartIndex: Int?

    /// Word-index → pauseable block map extracted from the loaded `DocumentContent`.
    /// Exposed to the parent so it can be passed into
    /// `RSVPEngine.loadText(_:pauseableBlocks:)` at start-reading time, enabling
    /// auto-pause on figures, diagrams, and any future block kinds.
    @Binding var pauseableBlocks: [Int: PauseableBlock]

    // Non-nil when InlineReaderView is active
    var engine: RSVPEngine? = nil

    @State private var selectedFile: URL?
    @State private var documentContent: DocumentContent?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showContinuePrompt = false
    @State private var savedWordIndex: Int?
    @State private var ocrState: OCRState = .idle
    @State private var ocrCurrentPage: Int = 0
    @State private var ocrTotalPages: Int = 0
    @State private var ocrFileName: String?
    @State private var isSelectingStart: Bool = false
    @State private var isOnEditTab: Bool = false
    @ObservedObject private var recentFiles = RecentFilesManager.shared

    private enum OCRState {
        case idle
        case recognizing
    }

    private let supportedExtensions = DocumentReaderFactory.supportedExtensions
    private let displayExtensions = DocumentReaderFactory.displayExtensions

    /// PDF is selected (show document area even while text is still parsing)
    private var hasFile: Bool { selectedFile != nil }
    /// Text parsing complete
    private var hasContent: Bool { documentContent != nil && selectedFile != nil }
    private var isReading: Bool { engine != nil }

    private var isImageFile: Bool {
        guard let ext = selectedFile?.pathExtension.lowercased() else { return false }
        return ImageReader.supportedExtensions.contains(ext)
    }

    /// Formats that support in-preview start selection without the plain fallback preview.
    private var isWebViewFormat: Bool {
        guard let ext = selectedFile?.pathExtension.lowercased() else { return false }
        if ["pdf", "md", "markdown", "fb2", "epub", "docx"].contains(ext) {
            return true
        }
        if ext == "txt" {
            if #available(macOS 14.0, *) {
                return true
            }
        }
        return false
    }

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
            if hasFile {
                // Document preview — full height. The file chip and controls
                // (Set start position, Contents) live in the preview's unified
                // top toolbar instead of a separate header row.
                if let url = selectedFile {
                    if needsParsedPreview && documentContent == nil {
                        // Show loading while parsing FB2/structured formats
                        VStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing document...")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                            Text("Large documents may take longer")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.7))
                                .padding(.top, 2)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            if isSelectingStart && !isReading && !isWebViewFormat {
                                // Fallback for images in selection mode: ClickableTextPreview
                                // with a standalone unified toolbar on top.
                                VStack(spacing: 0) {
                                    PreviewToolbarRow(
                                        leading: AnyView(fileChip),
                                        trailing: AnyView(controlButtons)
                                    ) { EmptyView() }
                                    ClickableTextPreview(text: inputText, selectedWordIndex: $selectedStartIndex)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .previewCard()
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                            } else {
                                ZStack {
                                    FilePreviewView(
                                        url: url,
                                        engine: engine,
                                        documentContent: documentContent,
                                        usedOCR: documentContent?.usedOCR ?? false,
                                        ocrWordLocations: documentContent?.ocrWordLocations,
                                        isSelectingStart: isSelectingStart && !isReading,
                                        selectedWordIndex: $selectedStartIndex,
                                        onWordSelected: { index in selectedStartIndex = index },
                                        onTextExtracted: { text in
                                            if !text.isEmpty, text != inputText {
                                                inputText = text
                                                // Reload engine if not playing so it uses the DOM-synced text
                                                if let engine = engine, !engine.isPlaying {
                                                    engine.loadText(text)
                                                }
                                            }
                                        },
                                        onPauseableBlocksExtracted: { blocks in
                                            // Authoritative pauseable-block map for markdown — overrides
                                            // the Swift-parser map (`content.pauseableBlocks`) whose
                                            // indices don't line up with the JS-extracted word stream
                                            // the engine actually reads. Re-fires on every preview render
                                            // (e.g. when the user edits the source).
                                            if pauseableBlocks != blocks {
                                                pauseableBlocks = blocks
                                            }
                                        },
                                        onEditTabActiveChanged: { isEdit in
                                            isOnEditTab = isEdit
                                            // Selection isn't usable in a plain TextEditor — bail out.
                                            if isEdit && isSelectingStart {
                                                isSelectingStart = false
                                                selectedStartIndex = nil
                                            }
                                        },
                                        toolbarLeading: AnyView(fileChip),
                                        toolbarTrailing: AnyView(controlButtons)
                                    )
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                                    // Loading overlay while text is being extracted or OCR is running
                                    if ocrState == .recognizing {
                                        VStack(spacing: 12) {
                                            Image(systemName: "photo.badge.magnifyingglass")
                                                .font(.system(size: 28))
                                                .foregroundStyle(.secondary)
                                                .symbolEffect(.pulse)
                                            Text("Recognizing text...")
                                                .font(.system(size: 13, weight: .medium))
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Using on-device OCR")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary.opacity(0.7))
                                        }
                                        .frame(maxWidth: 220)
                                        .padding(.vertical, 18)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(.ultraThinMaterial)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                        )
                                    } else if isLoading && documentContent == nil {
                                        VStack(spacing: 10) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Extracting text...")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxWidth: 180)
                                        .padding(.vertical, 14)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(.ultraThinMaterial)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                        )
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                            }
                        }
                        .padding(.top, 16)
                    }
                }

                // Word count + start position toggle
                if !isReading && hasContent {
                    HStack {
                        if let pageCount = documentContent?.metadata?.pageCount {
                            Text("\(pageCount) pages")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text("•")
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        Text("\(documentContent?.wordCount ?? 0) words")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        if let ext = selectedFile?.pathExtension.lowercased() {
                            if ext == "pdf" {
                                Text("•")
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("PDF text extraction may lose formatting on complex layouts")
                                    .font(.system(size: 10))
                                    .foregroundColor(.purple)
                            } else if ["jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp"].contains(ext) {
                                Text("•")
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("OCR may be inaccurate on complex layouts")
                                    .font(.system(size: 10))
                                    .foregroundColor(.purple)
                            }
                        }
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

            } else {
                // OCR states
                switch ocrState {
                case .recognizing:
                    Spacer()
                    OCRProgressView(
                        currentPage: ocrCurrentPage,
                        totalPages: ocrTotalPages,
                        fileName: ocrFileName
                    )
                    Spacer()

                case .idle:
                    DropZoneView(
                        supportedExtensions: displayExtensions,
                        isLoading: isLoading,
                        onDrop: handleFile,
                        onChooseFile: openFilePicker
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                }

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // Recent files (hidden during OCR)
                if !recentFiles.files.isEmpty && ocrState == .idle {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recent")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear All") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    recentFiles.clearAll()
                                }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(recentFiles.files, id: \.path) { url in
                                    RecentFileCard(url: url, onOpen: handleFile, onRemove: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            recentFiles.remove(url)
                                        }
                                    })
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 16)
                }

                Spacer(minLength: 16)
            }
        }

            // Continue reading dialog overlay
            if showContinuePrompt, let wordIndex = savedWordIndex, let total = documentContent?.wordCount {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        recentFiles.resumeWordIndex = nil
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showContinuePrompt = false
                        }
                    }

                VStack(spacing: 16) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)

                    Text("Continue Reading?")
                        .font(.system(size: 15, weight: .semibold))

                    Text("You stopped at word \(min(wordIndex, total)) of \(total) (\(min(Int(Double(wordIndex) / Double(total) * 100), 100))%)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button {
                            recentFiles.resumeWordIndex = nil
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showContinuePrompt = false
                            }
                        } label: {
                            Text("Start Over")
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            recentFiles.resumeWordIndex = wordIndex
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showContinuePrompt = false
                            }
                            NotificationCenter.default.post(name: .startReading, object: nil)
                        } label: {
                            Text("Continue")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(width: 260)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 30, y: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .openFilePicker)) { _ in
            openFilePicker()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileFromFinder)) { notification in
            if let url = notification.object as? URL {
                handleFile(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissDocument)) { _ in
            if hasFile && !isReading {
                clearDocument()
            }
        }
    }

    // MARK: - Helpers

    /// Formats where raw file should not be loaded directly (e.g. FB2 contains binary XML, PDF renders as Markdown)
    private var needsParsedPreview: Bool {
        ["fb2", "epub", "docx", "pdf"].contains(selectedFile?.pathExtension.lowercased())
    }

    private var fileIcon: String {
        guard let ext = selectedFile?.pathExtension.lowercased() else {
            return "doc.fill"
        }
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "txt": return "doc.text.fill"
        case "md", "markdown": return "doc.text"
        case "fb2", "epub", "docx": return "book.fill"
        case "jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp": return "photo.fill"
        default: return "doc.fill"
        }
    }

    /// True when the open document has a non-empty table of contents (EPUB so far).
    private var hasTOC: Bool {
        !(documentContent?.toc?.isEmpty ?? true)
    }

    // MARK: - Toolbar slots

    /// Leading slot of the preview's unified toolbar — file icon, name, and close button.
    private var fileChip: some View {
        HStack(spacing: 6) {
            Image(systemName: fileIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            if let url = selectedFile {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            if !isReading {
                Button(action: clearDocument) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    /// Trailing controls of the preview's unified toolbar — table of contents
    /// toggle (books) and the Set-start-position toggle.
    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: 8) {
            if hasTOC {
                Button {
                    NotificationCenter.default.post(name: .toggleTOC, object: nil)
                } label: {
                    ToolbarChipLabel(icon: "list.bullet.indent", text: "Contents")
                }
                .buttonStyle(.plain)
                .help("Toggle table of contents (⌘⇧O)")
            }

            if !isReading && hasContent && !isOnEditTab {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelectingStart.toggle()
                        if !isSelectingStart {
                            selectedStartIndex = nil
                        }
                    }
                } label: {
                    ToolbarChipLabel(
                        icon: isSelectingStart ? "doc.richtext" : "hand.point.up.left",
                        text: isSelectingStart ? "Preview" : "Set start position",
                        active: isSelectingStart
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        var contentTypes: [UTType] = []
        for ext in supportedExtensions {
            if let type = UTType(filenameExtension: ext) {
                contentTypes.append(type)
            }
        }
        panel.allowedContentTypes = contentTypes

        if panel.runModal() == .OK, let url = panel.url {
            handleFile(url)
        }
    }

    private func handleFile(_ url: URL) {
        errorMessage = nil
        documentContent = nil
        pauseableBlocks = [:]
        showContinuePrompt = false
        savedWordIndex = nil
        isSelectingStart = false
        selectedStartIndex = nil

        recentFiles.resumeWordIndex = nil
        selectedFile = url
        recentFiles.currentFile = url
        isLoading = true
        recentFiles.add(url)

        Task {
            do {
                guard let reader = DocumentReaderFactory.reader(for: url) else {
                    throw DocumentError.unsupportedFormat
                }
                var content = try await reader.read(from: url)

                // For PDFs: use jzillmann/pdf-to-markdown for higher quality markdown + plain text
                if url.pathExtension.lowercased() == "pdf" {
                    do {
                        let markdown = try await PDF2MDExtractor.convert(pdfURL: url)
                        if !markdown.isEmpty {
                            let mdPlainText = PDF2MDExtractor.plainText(fromMarkdown: markdown)
                            // The engine now streams `mdPlainText`, so a TOC whose
                            // `wordIndex` values were computed from `finalBlocks` no
                            // longer aligns. Rebuild from the markdown — same scanner
                            // as `plainText(fromMarkdown:)` — so each heading's
                            // `wordIndex` matches the new stream. Fall back to the
                            // PDFKit-outline / block-heading TOC produced by
                            // `PDFDocumentReader` when the markdown contains no
                            // headings (e.g. a one-flow scan with no font cues).
                            let mdToc = TableOfContents.fromMarkdown(markdown)
                            let resolvedTOC: TableOfContents? = mdToc.isEmpty ? content.toc : mdToc

                            content = DocumentContent(
                                title: content.title,
                                blocks: content.blocks,
                                plainText: mdPlainText.isEmpty ? content.plainText : mdPlainText,
                                metadata: content.metadata,
                                usedOCR: content.usedOCR,
                                ocrWordLocations: content.ocrWordLocations,
                                markdownText: markdown,
                                toc: resolvedTOC
                            )
                        }
                    } catch { }
                }

                await MainActor.run {
                    documentContent = content
                    inputText = content.plainText
                    pauseableBlocks = content.pauseableBlocks
                    isLoading = false

                    // Check for saved reading progress
                    if let progress = recentFiles.savedProgress(for: url),
                       progress < content.wordCount {
                        savedWordIndex = progress
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showContinuePrompt = true
                        }
                    }
                }
            } catch let error as DocumentError {
                await MainActor.run {
                    switch error {
                    case .needsOCR(_, let ocrURL):
                        let ext = ocrURL.pathExtension.lowercased()
                        let isImageFile = ImageReader.supportedExtensions.contains(ext)
                        if !isImageFile {
                            selectedFile = nil
                            recentFiles.currentFile = nil
                        }
                        isLoading = false
                        startOCR(url: ocrURL, options: .init(quality: .accurate))
                    case .emptyDocument:
                        let ext = url.pathExtension.lowercased()
                        if ImageReader.supportedExtensions.contains(ext) {
                            errorMessage = "No text recognized in this image. Try a clearer photo with readable text."
                        } else if ["fb2", "epub", "docx", "md", "markdown"].contains(ext) {
                            errorMessage = "No readable text found. The document may contain only images."
                        } else {
                            errorMessage = error.localizedDescription
                        }
                        selectedFile = nil
                        recentFiles.currentFile = nil
                        isLoading = false
                    default:
                        errorMessage = error.localizedDescription
                        selectedFile = nil
                        recentFiles.currentFile = nil
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    selectedFile = nil
                    recentFiles.currentFile = nil
                    isLoading = false
                }
            }
        }
    }

    private func startOCR(url: URL, options: OCREngine.Options) {
        errorMessage = nil
        ocrState = .recognizing
        ocrCurrentPage = 0
        ocrTotalPages = 1
        ocrFileName = url.lastPathComponent

        Task {
            do {
                let content: DocumentContent

                let ext = url.pathExtension.lowercased()
                if ImageReader.supportedExtensions.contains(ext) {
                    let reader = ImageReader()
                    content = try await reader.readWithOCR(
                        from: url, options: options
                    ) { current, total in
                        ocrCurrentPage = current
                        ocrTotalPages = total
                    }
                } else {
                    let reader = PDFDocumentReader()
                    content = try await reader.readWithOCR(
                        from: url, options: options
                    ) { current, total in
                        ocrCurrentPage = current
                        ocrTotalPages = total
                    }
                }

                await MainActor.run {
                    documentContent = content
                    inputText = content.plainText
                    pauseableBlocks = content.pauseableBlocks
                    selectedFile = url
                    recentFiles.currentFile = url
                    recentFiles.add(url)
                    ocrState = .idle
                    isLoading = false

                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    selectedFile = nil
                    recentFiles.currentFile = nil
                    documentContent = nil
                    pauseableBlocks = [:]
                    ocrState = .idle
                    isLoading = false
                }
            }
        }
    }

    private func clearDocument() {
        documentContent = nil
        pauseableBlocks = [:]
        selectedFile = nil
        errorMessage = nil
        inputText = ""
        showContinuePrompt = false
        savedWordIndex = nil
        isSelectingStart = false
        selectedStartIndex = nil

        ocrState = .idle
        ocrCurrentPage = 0
        ocrTotalPages = 0
        ocrFileName = nil
        recentFiles.currentFile = nil
        recentFiles.resumeWordIndex = nil
    }
}

// MARK: - Recent File Card

private struct RecentFileCard: View {
    let url: URL
    let onOpen: (URL) -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    private var ext: String { url.pathExtension.lowercased() }
    private var name: String {
        let full = url.deletingPathExtension().lastPathComponent
        return full.count > 20 ? String(full.prefix(18)) + "..." : full
    }

    private var icon: String {
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "txt": return "doc.text.fill"
        case "md", "markdown": return "doc.text"
        case "fb2", "epub", "docx": return "book.fill"
        default: return "doc.fill"
        }
    }

    var body: some View {
        Button { onOpen(url) } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
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
                                .background(Color.primary.opacity(0.12))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 2, y: -2)
                    }
                }

                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(".\(ext)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 110)
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
