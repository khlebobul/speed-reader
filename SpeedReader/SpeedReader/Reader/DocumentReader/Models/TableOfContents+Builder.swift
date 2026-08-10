import Foundation

/// A flat (pre-nesting) table-of-contents item. Format readers build a flat list
/// of these, then call `TableOfContents.nest(_:)` to produce the entry tree.
struct FlatTOCItem: Equatable {
    let title: String
    let level: Int
    let wordIndex: Int
    let blockIndex: Int?

    init(title: String, level: Int, wordIndex: Int, blockIndex: Int? = nil) {
        self.title = title
        self.level = level
        self.wordIndex = wordIndex
        self.blockIndex = blockIndex
    }
}

extension TableOfContents {

    /// Builds a TOC from a document's blocks by collecting `.heading` blocks and
    /// counting cumulative words with the same regex `RSVPEngine` uses to tokenize —
    /// so `wordIndex` lines up exactly with `engine.seekTo(_:)`.
    static func fromBlocks(_ blocks: [TextBlock]) -> TableOfContents {
        var wordOffset = 0
        var flat: [FlatTOCItem] = []

        for (i, block) in blocks.enumerated() {
            if case .heading(let level) = block.type {
                flat.append(FlatTOCItem(
                    title: block.text,
                    level: level,
                    wordIndex: wordOffset,
                    blockIndex: i
                ))
            }
            wordOffset += wordCount(in: block.text)
        }

        return TableOfContents(entries: nest(flat))
    }

    /// Groups a flat list into a tree: each item with a higher `level` becomes a
    /// child of the most recent item with a lower `level`. Tolerates skipped
    /// levels (e.g. h1 → h3) and out-of-order jumps.
    static func nest(_ items: [FlatTOCItem]) -> [TOCEntry] {
        var index = 0

        func build(parentLevel: Int) -> [TOCEntry] {
            var result: [TOCEntry] = []
            while index < items.count {
                let item = items[index]
                guard item.level > parentLevel else { break }
                index += 1
                let children = build(parentLevel: item.level)
                result.append(TOCEntry(
                    title: item.title,
                    level: item.level,
                    wordIndex: item.wordIndex,
                    blockIndex: item.blockIndex,
                    children: children
                ))
            }
            return result
        }

        return build(parentLevel: 0)
    }

    /// Counts words in `text` using `RSVPEngine.wordPattern` — the single source of
    /// truth for tokenization across the engine and the OCR word-location builder.
    static func wordCount(in text: String) -> Int {
        guard let regex = Self.wordRegex else {
            return text.split(separator: " ").count
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, options: [], range: nsRange)
    }

    private static let wordRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: RSVPEngine.wordPattern, options: [])
    }()

    /// Builds a TOC from raw markdown by walking it line-by-line through
    /// `PDF2MDExtractor.scanMarkdownLine(_:inTable:)` — the same scanner that
    /// produces `PDF2MDExtractor.plainText(fromMarkdown:)`. This guarantees
    /// each TOC entry's `wordIndex` lines up with the engine's `currentIndex`
    /// when the engine streams the markdown-derived plain text (which is how
    /// PDF reading works after the pdf2md conversion).
    static func fromMarkdown(_ markdown: String) -> TableOfContents {
        var flat: [FlatTOCItem] = []
        var wordOffset = 0
        var inTable = false

        for line in markdown.components(separatedBy: .newlines) {
            let scan = PDF2MDExtractor.scanMarkdownLine(line, inTable: &inTable)

            if case .skipped = scan.kind { continue }

            if case .heading(let level) = scan.kind {
                let title = scan.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    flat.append(FlatTOCItem(
                        title: title,
                        level: max(1, min(6, level)),
                        wordIndex: wordOffset
                    ))
                }
            }

            wordOffset += wordCount(in: scan.text)
        }

        return TableOfContents(entries: nest(flat))
    }
}
