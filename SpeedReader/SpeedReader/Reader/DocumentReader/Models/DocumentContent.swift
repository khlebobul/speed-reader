import Foundation

/// Metadata extracted from a document
struct DocumentMetadata: Equatable {
    let author: String?
    let creationDate: Date?
    let modificationDate: Date?
    let pageCount: Int?
    let subject: String?
    let keywords: [String]?

    init(
        author: String? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        pageCount: Int? = nil,
        subject: String? = nil,
        keywords: [String]? = nil
    ) {
        self.author = author
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pageCount = pageCount
        self.subject = subject
        self.keywords = keywords
    }
}

/// Result of parsing a document
struct DocumentContent: Equatable {
    /// Document title (if available)
    let title: String?

    /// Parsed text blocks (paragraphs, headings, etc.)
    let blocks: [TextBlock]

    /// Full text concatenated for RSVP reading
    let plainText: String

    /// Optional document metadata
    let metadata: DocumentMetadata?

    /// Whether OCR was used to extract text (affects word highlighting in PDF preview)
    let usedOCR: Bool

    /// Word-level locations for OCR pages, indexed by RSVP word index.
    /// nil for non-OCR documents; elements are nil for words from text-layer pages (hybrid PDFs).
    let ocrWordLocations: [OCRWordLocation?]?

    /// Markdown representation of the document (generated from blocks for PDF preview)
    let markdownText: String?

    /// Table of contents — nil when the format has no structure or none was extracted.
    let toc: TableOfContents?

    /// Word count in the document
    var wordCount: Int {
        plainText.split(separator: " ").count
    }

    /// Maps a word index in the RSVP stream to the `PauseableBlock` for a placeholder
    /// block at that position. Walks `blocks` in order, counting words via
    /// `RSVPEngine.wordPattern`, and records `(wordIndex, PauseableBlock)` for each
    /// pause-worthy block. Empty when the document has no such blocks or `blocks`
    /// is empty (the plainText path can't recover block structure).
    ///
    /// Relies on the invariant that `plainText == blocks.map(\.text).joined(separator: "\n\n")`
    /// up to leading/trailing whitespace trimming — the same join used by every reader.
    ///
    /// Producers today: `.image` blocks from DOCX and URL articles. Formula / table /
    /// code blocks are emitted by some readers as text or stripped — once those
    /// readers learn to emit structured blocks (Phases 3–5 of the smart-pause plan),
    /// the corresponding `PauseableBlock` cases populate here for free.
    var pauseableBlocks: [Int: PauseableBlock] {
        guard !blocks.isEmpty else { return [:] }
        var refs: [Int: PauseableBlock] = [:]
        var wordIndex = 0
        for block in blocks {
            let count = wordCount(in: block.text)
            switch block.type {
            case .image(let src, let alt):
                if let ref = ImageRef.from(src: src, caption: alt) {
                    refs[wordIndex] = .image(ref)
                }
            case .formula(let latex, let caption):
                let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    refs[wordIndex] = .formula(latex: trimmed, caption: caption)
                }
            case .table(let html, let columnCount, let caption):
                let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    refs[wordIndex] = .table(html: trimmed, columnCount: columnCount, caption: caption)
                }
            case .code(let language, let source):
                let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    refs[wordIndex] = .code(language: language, source: source)
                }
            default:
                break
            }
            wordIndex += count
        }
        return refs
    }

    private func wordCount(in text: String) -> Int {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern) else {
            return 0
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    init(
        title: String? = nil,
        blocks: [TextBlock] = [],
        plainText: String,
        metadata: DocumentMetadata? = nil,
        usedOCR: Bool = false,
        ocrWordLocations: [OCRWordLocation?]? = nil,
        markdownText: String? = nil,
        toc: TableOfContents? = nil
    ) {
        self.title = title
        self.blocks = blocks
        self.plainText = plainText
        self.metadata = metadata
        self.usedOCR = usedOCR
        self.ocrWordLocations = ocrWordLocations
        self.markdownText = markdownText
        self.toc = toc
    }
}
