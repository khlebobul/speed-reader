import Foundation

/// Type of content block in a document
enum BlockType: Equatable {
    case paragraph
    case heading(level: Int)
    case list
    /// Fenced / preformatted code. Carries the raw source plus optional language
    /// hint (`"swift"`, `"python"`, …) so `CodePreviewView` can syntax-highlight.
    /// The `text` on the surrounding `TextBlock` is the placeholder word
    /// `RSVPEngine.placeholderCode` — code reads as a single beat the engine can
    /// auto-pause on (gated by `ReaderSettings.autoPauseOnCode`).
    case code(language: String?, source: String)
    case quote
    case footnote   // Unique per-page footnote (not a repeating footer)
    case caption    // Figure/table caption — skipped during reading
    /// Tabular data. Carries the rendered HTML for `TablePreviewView` and the
    /// column count so the preview can lay out without re-parsing. Producers:
    /// DOCXReader (one block per `<w:tbl>`), Defuddle/ReadabilityExtractor
    /// (one block per `<table>`). The `text` on the surrounding `TextBlock` is
    /// the placeholder word `RSVPEngine.placeholderTable` so RSVP word counts
    /// stay aligned with `plainText`.
    case table(html: String, columnCount: Int, caption: String?)
    case image(src: String, altText: String?)
    /// Math block carrying LaTeX source. Producers: MarkdownReader ($$...$$),
    /// Defuddle (KaTeX annotations + MathML), DOCXReader (OMML→LaTeX).
    /// `text` on the block is the placeholder word `RSVPEngine.placeholderFormula`
    /// so word counts stay aligned with `plainText`.
    case formula(latex: String, caption: String?)
}

/// Represents a block of text with metadata from a document
struct TextBlock: Equatable {
    let text: String
    let type: BlockType
    let column: Int?
    let pageNumber: Int?
    let range: Range<String.Index>

    /// Text with inline Markdown formatting (bold/italic) from font analysis.
    var markdownText: String?

    /// Y position for sorting (PDFKit: Y=0 at bottom, increases upward)
    var y: CGFloat = 0

    /// Left edge of the block (used for N-column detection)
    var xMin: CGFloat = 0

    /// Right edge of the block
    var xMax: CGFloat = 0

    /// Whether this block is at the top of the page
    var isAtTop: Bool = false

    /// Whether this block is at the bottom of the page
    var isAtBottom: Bool = false

    init(
        text: String,
        type: BlockType,
        column: Int? = nil,
        pageNumber: Int? = nil,
        range: Range<String.Index>,
        markdownText: String? = nil,
        y: CGFloat = 0,
        xMin: CGFloat = 0,
        xMax: CGFloat = 0,
        isAtTop: Bool = false,
        isAtBottom: Bool = false
    ) {
        self.text = text
        self.type = type
        self.column = column
        self.pageNumber = pageNumber
        self.range = range
        self.markdownText = markdownText
        self.y = y
        self.xMin = xMin
        self.xMax = xMax
        self.isAtTop = isAtTop
        self.isAtBottom = isAtBottom
    }
}
