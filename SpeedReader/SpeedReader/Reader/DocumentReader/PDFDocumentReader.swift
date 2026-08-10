import Foundation
import PDFKit

// MARK: - Logical line (P1-1 character-bounds extraction)

/// One `\n`-delimited logical line from the PDF text stream,
/// enriched with character-bound geometry for layout analysis.
private struct PDFLogicalLine {
    let text: String
    let nsRange: NSRange
    /// Non-outlier characters (X-outliers filtered) with their bounds
    let chars: [(index: Int, bounds: CGRect)]
    /// Median midY of valid chars; -1 when no bounds available
    let yCenter: CGFloat
    let xMin: CGFloat
    let xMax: CGFloat
    let yMin: CGFloat
    let yMax: CGFloat
}

// MARK: - PDFDocumentReader

/// Reader for PDF documents with N-column detection, noise filtering,
/// font-based heading detection, footnote/footer classification, and caption/table skipping.
final class PDFDocumentReader: DocumentReader {
    static let supportedExtensions = ["pdf"]

    private let columnGapThreshold: CGFloat = 0.1
    private let minBlocksForColumnDetection = 4
    private let edgeThreshold: CGFloat = 0.1

    // MARK: - Public read

    func read(from url: URL) async throws -> DocumentContent {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.cannotOpen
        }
        guard document.pageCount > 0 else {
            throw DocumentError.emptyDocument
        }

        let engine = OCREngine()
        var allBlocks: [TextBlock] = []
        var pageHeights: [CGFloat] = []
        var pagesWithText = 0
        var anyPageUsedOCR = false

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            let pageBounds = page.bounds(for: .mediaBox)
            pageHeights.append(pageBounds.height)

            if let t = page.string, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pagesWithText += 1
            }

            let result = try await extractBlocksSmart(
                from: page, pageNumber: pageIndex + 1,
                pageHeight: pageBounds.height, engine: engine
            )
            // OCR blocks already have correct reading order from Vision — don't re-sort
            if result.usedOCR {
                anyPageUsedOCR = true
                allBlocks.append(contentsOf: result.blocks)
            } else {
                let sortedBlocks = sortBlocksByReadingOrder(result.blocks, pageWidth: pageBounds.width)
                allBlocks.append(contentsOf: sortedBlocks)
            }
        }

        let avgPageHeight = pageHeights.isEmpty ? 800
            : pageHeights.reduce(0, +) / CGFloat(pageHeights.count)
        let filteredBlocks = filterNoise(allBlocks, pageCount: document.pageCount,
                                         pageHeight: avgPageHeight)
        let mergedBlocks = mergeCrossPageParagraphs(filteredBlocks)

        var plainText = ""
        var finalBlocks: [TextBlock] = []

        for block in mergedBlocks {
            guard block.type != .footnote,
                  block.type != .caption else { continue }
            if case .table = block.type { continue }

            let startIndex = plainText.endIndex
            plainText += block.text + "\n\n"
            let endIndex = plainText.endIndex

            finalBlocks.append(TextBlock(
                text: block.text, type: block.type, column: block.column,
                pageNumber: block.pageNumber, range: startIndex..<endIndex,
                markdownText: block.markdownText,
                y: block.y, xMin: block.xMin, xMax: block.xMax,
                isAtTop: block.isAtTop, isAtBottom: block.isAtBottom
            ))
        }

        plainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !plainText.isEmpty else {
            if pagesWithText == 0 {
                throw DocumentError.needsOCR(pageCount: document.pageCount, url: url)
            }
            throw DocumentError.emptyDocument
        }

        // Build word locations from character bounds for precise highlighting
        let wordLocations = buildCharBoundsWordLocations(
            plainText: plainText, finalBlocks: finalBlocks, document: document
        )

        let toc = buildPDFTOC(document: document, finalBlocks: finalBlocks)

        return DocumentContent(
            title: extractTitle(from: document, url: url),
            blocks: finalBlocks,
            plainText: plainText,
            metadata: extractMetadata(from: document),
            usedOCR: anyPageUsedOCR,
            ocrWordLocations: wordLocations.isEmpty ? nil : wordLocations,
            toc: toc
        )
    }

    // MARK: - OCR Reading

    /// Reads a PDF using OCR for pages without a text layer.
    /// For hybrid PDFs, text pages use the normal extraction; scan pages use Vision OCR.
    func readWithOCR(
        from url: URL,
        options: OCREngine.Options = .init(),
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> DocumentContent {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.cannotOpen
        }
        guard document.pageCount > 0 else {
            throw DocumentError.emptyDocument
        }

        let engine = OCREngine()
        var allBlocks: [TextBlock] = []
        /// Per-page OCR word locations: index = sequential page, value = word locations for OCR pages, nil for text-layer pages
        var perPageWordLocations: [[(word: String, location: OCRWordLocation)]] = []
        var pageIsOCR: [Bool] = []

        for i in 0..<document.pageCount {
            await onProgress(i + 1, document.pageCount)
            guard let page = document.page(at: i) else { continue }

            let pageBounds = page.bounds(for: .mediaBox)

            // Try text layer first
            if let text = page.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let pageBlocks = extractBlocks(from: page, pageNumber: i + 1,
                                               pageHeight: pageBounds.height)
                let sorted = sortBlocksByReadingOrder(pageBlocks, pageWidth: pageBounds.width)
                allBlocks.append(contentsOf: sorted)
                perPageWordLocations.append([])
                pageIsOCR.append(false)
                continue
            }

            // Page is a scan — render and OCR
            guard let cgImage = OCRPageRenderer.render(page: page) else {
                perPageWordLocations.append([])
                pageIsOCR.append(false)
                continue
            }
            let result = try await engine.recognize(cgImage: cgImage, pageIndex: i, options: options)
            let ocrBlocks = OCRTextRebuilder.buildBlocks(
                from: [result], pageSize: pageBounds.size, pageNumber: i + 1
            )
            allBlocks.append(contentsOf: ocrBlocks)

            // Extract word-level locations for highlighting
            let wordLocs = OCRTextRebuilder.buildWordLocations(
                from: [result], pageSize: pageBounds.size, pageIndex: i
            )
            perPageWordLocations.append(wordLocs)
            pageIsOCR.append(true)
        }

        let avgPageHeight = document.pageCount > 0
            ? (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).height }.reduce(0, +) / CGFloat(document.pageCount)
            : 800.0
        let filteredBlocks = filterNoise(allBlocks, pageCount: document.pageCount,
                                         pageHeight: avgPageHeight)
        let mergedBlocks = mergeCrossPageParagraphs(filteredBlocks)

        var plainText = ""
        var finalBlocks: [TextBlock] = []

        for block in mergedBlocks {
            guard block.type != .footnote,
                  block.type != .caption else { continue }
            if case .table = block.type { continue }

            let startIndex = plainText.endIndex
            plainText += block.text + "\n\n"
            let endIndex = plainText.endIndex

            finalBlocks.append(TextBlock(
                text: block.text, type: block.type, column: block.column,
                pageNumber: block.pageNumber, range: startIndex..<endIndex,
                markdownText: block.markdownText,
                y: block.y, xMin: block.xMin, xMax: block.xMax,
                isAtTop: block.isAtTop, isAtBottom: block.isAtBottom
            ))
        }

        plainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !plainText.isEmpty else {
            throw DocumentError.emptyDocument
        }

        // Build word locations array aligned with RSVP word indices.
        // Walk finalBlocks → for each block's words, match to OCR locations by page.
        let ocrWordLocations = buildOCRWordLocationIndex(
            plainText: plainText,
            finalBlocks: finalBlocks,
            perPageWordLocations: perPageWordLocations,
            pageIsOCR: pageIsOCR
        )

        let toc = buildPDFTOC(document: document, finalBlocks: finalBlocks)

        return DocumentContent(
            title: extractTitle(from: document, url: url),
            blocks: finalBlocks,
            plainText: plainText,
            metadata: extractMetadata(from: document),
            usedOCR: true,
            ocrWordLocations: ocrWordLocations,
            toc: toc
        )
    }

    // MARK: - Table of contents

    /// Builds a TOC for a PDF document. Prefers PDFKit's embedded outline
    /// (`outlineRoot` / NSOutline tree from the PDF's bookmarks dictionary),
    /// falling back to font-based heading blocks emitted by the block extractor.
    /// Returns `nil` when neither produces entries.
    private func buildPDFTOC(document: PDFDocument, finalBlocks: [TextBlock]) -> TableOfContents? {
        // 1. PDFKit outline: most reliable when the PDF was authored with bookmarks.
        if let outlineRoot = document.outlineRoot {
            var flat: [FlatTOCItem] = []
            flattenPDFOutline(outlineRoot, document: document, depth: 0,
                              finalBlocks: finalBlocks, into: &flat)
            if !flat.isEmpty {
                return TableOfContents(entries: TableOfContents.nest(flat))
            }
        }

        // 2. Fallback: heading blocks the reader detected via font-size analysis
        //    (these already carry `level:` per the SanitizeHeaders pipeline).
        let fallback = TableOfContents.fromBlocks(finalBlocks)
        return fallback.isEmpty ? nil : fallback
    }

    /// Pre-order DFS over the PDFKit outline tree, resolving each entry's
    /// destination page to the first matching block's word offset. Children of
    /// the root are level 1; depth grows with nesting.
    private func flattenPDFOutline(
        _ outline: PDFOutline,
        document: PDFDocument,
        depth: Int,
        finalBlocks: [TextBlock],
        into result: inout [FlatTOCItem]
    ) {
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty,
               let destination = child.destination,
               let page = destination.page {
                let pageIndex = document.index(for: page) + 1   // 1-based
                if let blockIdx = finalBlocks.firstIndex(where: { $0.pageNumber == pageIndex }) {
                    let wordIndex = wordOffsetFor(blockIndex: blockIdx, blocks: finalBlocks)
                    result.append(FlatTOCItem(
                        title: title,
                        level: max(1, depth + 1),
                        wordIndex: wordIndex,
                        blockIndex: blockIdx
                    ))
                }
            }
            flattenPDFOutline(child, document: document, depth: depth + 1,
                              finalBlocks: finalBlocks, into: &result)
        }
    }

    /// Cumulative word count of blocks `0..<blockIndex`, using the same
    /// tokenization regex as `RSVPEngine` so the result lines up with
    /// `engine.currentIndex` after seek.
    private func wordOffsetFor(blockIndex: Int, blocks: [TextBlock]) -> Int {
        var offset = 0
        for i in 0..<min(blockIndex, blocks.count) {
            offset += TableOfContents.wordCount(in: blocks[i].text)
        }
        return offset
    }

    /// Builds an array of OCRWordLocation? aligned with RSVP word indices.
    /// For each word in plainText: if it came from an OCR page, provide its location; otherwise nil.
    private func buildOCRWordLocationIndex(
        plainText: String,
        finalBlocks: [TextBlock],
        perPageWordLocations: [[(word: String, location: OCRWordLocation)]],
        pageIsOCR: [Bool]
    ) -> [OCRWordLocation?] {
        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern, options: []) else {
            return []
        }

        // Extract all RSVP words from plainText
        let nsRange = NSRange(plainText.startIndex..., in: plainText)
        let matches = regex.matches(in: plainText, options: [], range: nsRange)

        // Build a per-page cursor for OCR word locations
        var pageCursors = [Int: Int]()  // pageIndex (0-based) → next word cursor

        var result: [OCRWordLocation?] = []
        result.reserveCapacity(matches.count)

        for match in matches {
            guard let swiftRange = Range(match.range, in: plainText) else {
                result.append(nil)
                continue
            }

            let word = String(plainText[swiftRange])

            // Find which block this word belongs to (by range overlap)
            var pageIndex: Int?
            for block in finalBlocks {
                // block.range is in plainText coordinates
                if block.range.overlaps(swiftRange), let pn = block.pageNumber {
                    pageIndex = pn - 1  // convert 1-based to 0-based
                    break
                }
            }

            guard let pi = pageIndex,
                  pi < pageIsOCR.count,
                  pageIsOCR[pi] else {
                result.append(nil)
                continue
            }

            // Find matching word in this page's OCR locations
            let cursor = pageCursors[pi, default: 0]
            let pageLocs = perPageWordLocations[pi]

            if cursor < pageLocs.count {
                // Two-pass: exact match first, then fuzzy within expanded lookahead
                let lookahead = min(8, pageLocs.count - cursor)
                var bestOffset = -1
                var bestScore = 0.0

                for offset in 0..<lookahead {
                    let score = Self.wordSimilarity(pageLocs[cursor + offset].word, word)
                    if score == 1.0 {
                        bestOffset = offset
                        break
                    }
                    let threshold: Double = word.count <= 3 ? 0.5 : 0.7
                    if score > bestScore && score >= threshold {
                        bestOffset = offset
                        bestScore = score
                    }
                }

                if bestOffset >= 0 {
                    result.append(pageLocs[cursor + bestOffset].location)
                    pageCursors[pi] = cursor + bestOffset + 1
                } else {
                    // No good match — skip rather than consume wrong location
                    result.append(nil)
                }
            } else {
                result.append(nil)
            }
        }

        return result
    }

    /// Builds word locations using PDFPage.selection(for:) for text-layer PDFs.
    /// For each RSVP word, finds ALL occurrences in the page text, gets their visual
    /// positions, and picks the closest unused one based on proximity to the last word.
    private func buildCharBoundsWordLocations(
        plainText: String,
        finalBlocks: [TextBlock],
        document: PDFDocument
    ) -> [OCRWordLocation?] {
        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern, options: []) else {
            return []
        }

        let nsRange = NSRange(plainText.startIndex..., in: plainText)
        let matches = regex.matches(in: plainText, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        // Pre-build all occurrences per page per word for fast lookup
        // Cache page strings
        var pageStrings: [Int: NSString] = [:]
        // Track used occurrence locations per page to avoid duplicates
        var usedLocations: [Int: Set<Int>] = [:]  // pageIndex → set of range.location
        // Sliding window of recent word rects per page for context-aware proximity
        var recentRects: [Int: [CGRect]] = [:]
        let contextWindowSize = 3

        var result: [OCRWordLocation?] = []
        result.reserveCapacity(matches.count)

        for match in matches {
            guard let swiftRange = Range(match.range, in: plainText) else {
                result.append(nil)
                continue
            }
            let word = String(plainText[swiftRange])

            // Find which block → page
            var pageIndex: Int?
            for block in finalBlocks {
                if block.range.overlaps(swiftRange), let pn = block.pageNumber {
                    pageIndex = pn - 1
                    break
                }
            }

            guard let pi = pageIndex,
                  let page = document.page(at: pi) else {
                result.append(nil)
                continue
            }

            // Get/cache the page string
            let pageNS: NSString
            if let cached = pageStrings[pi] {
                pageNS = cached
            } else if let s = page.string {
                let ns = s as NSString
                pageStrings[pi] = ns
                pageNS = ns
            } else {
                result.append(nil)
                continue
            }

            // Strip punctuation/currency for flexible matching
            let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: CharacterSet(charactersIn: "$€£¥₹₽¢%"))
            guard !cleanWord.isEmpty else {
                result.append(nil)
                continue
            }

            // Find ALL occurrences of the word in the page text
            var occurrences: [(range: NSRange, rect: CGRect)] = []
            var searchStart = 0
            let used = usedLocations[pi, default: []]

            while searchStart < pageNS.length {
                let searchRange = NSRange(location: searchStart, length: pageNS.length - searchStart)
                let found = pageNS.range(of: cleanWord, options: [.caseInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }

                // Skip already-used occurrences
                if !used.contains(found.location) {
                    if let sel = page.selection(for: found) {
                        let bounds = sel.bounds(for: page)
                        if bounds.width > 0, bounds.height > 0,
                           bounds.width < page.bounds(for: .mediaBox).width * 0.5 {
                            occurrences.append((range: found, rect: bounds))
                        }
                    }
                }
                searchStart = found.location + 1
            }

            guard !occurrences.isEmpty else {
                result.append(nil)
                continue
            }

            // Pick best occurrence using context-aware proximity
            let chosen: (range: NSRange, rect: CGRect)
            if occurrences.count == 1 {
                chosen = occurrences[0]
            } else if let recent = recentRects[pi], !recent.isEmpty {
                let prev = recent.last!
                chosen = occurrences.min(by: { a, b in
                    let da = contextAwareDistance(candidate: a.rect, prev: prev, recentRects: recent)
                    let db = contextAwareDistance(candidate: b.rect, prev: prev, recentRects: recent)
                    return da < db
                })!
            } else {
                // First word on page — pick topmost-leftmost (reading order start)
                chosen = occurrences.min(by: { a, b in
                    let lineH = max(a.rect.height, b.rect.height, 10)
                    if abs(a.rect.midY - b.rect.midY) < lineH {
                        return a.rect.midX < b.rect.midX  // same line → leftmost
                    }
                    return a.rect.midY > b.rect.midY  // higher Y = higher on page
                })!
            }

            result.append(OCRWordLocation(pageIndex: pi, rect: chosen.rect))
            usedLocations[pi, default: []].insert(chosen.range.location)
            var rects = recentRects[pi, default: []]
            rects.append(chosen.rect)
            if rects.count > contextWindowSize { rects.removeFirst() }
            recentRects[pi] = rects
        }

        return result
    }

    // MARK: - Fuzzy Word Matching

    /// Normalized similarity score (0…1) using Levenshtein distance on cleaned words.
    private static func wordSimilarity(_ a: String, _ b: String) -> Double {
        let cleanA = a.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let cleanB = b.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !cleanA.isEmpty, !cleanB.isEmpty else { return 0 }
        if cleanA == cleanB { return 1.0 }
        let maxLen = max(cleanA.count, cleanB.count)
        let dist = levenshteinDistance(Array(cleanA), Array(cleanB))
        return 1.0 - Double(dist) / Double(maxLen)
    }

    private static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? prev : min(prev, dp[j], dp[j - 1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    /// Context-aware distance: uses the sliding window of recent word rects
    /// to detect same-line reading flow and give a bonus to candidates that
    /// continue the established direction.
    private func contextAwareDistance(candidate: CGRect, prev: CGRect, recentRects: [CGRect]) -> Double {
        let base = readingDistance(from: prev, to: candidate)

        guard recentRects.count >= 2 else { return base }

        let prevPrev = recentRects[recentRects.count - 2]
        let lineHeight = max(prev.height, 10)

        // If recent words are on the same line, prefer candidates on that line
        if abs(prev.midY - prevPrev.midY) < lineHeight {
            let avgY = recentRects.map(\.midY).reduce(0, +) / CGFloat(recentRects.count)
            if abs(candidate.midY - avgY) < lineHeight && candidate.midX > prev.midX {
                return base * 0.5  // bonus for continuing same-line flow
            }
        }

        return base
    }

    /// Distance heuristic for reading order: same line (similar Y) and to the right is close;
    /// next line down is medium; going backward (up) is penalized.
    /// PDF coordinates: Y increases upward, so "next line" = lower Y.
    private func readingDistance(from prev: CGRect, to next: CGRect) -> Double {
        let dy = prev.midY - next.midY  // positive = next is below prev (reading direction)
        let dx = next.midX - prev.midX  // positive = next is to the right

        let lineHeight = max(prev.height, next.height, 10)

        // Same line: Y difference < line height
        // Forward on same line should always beat going to a different line.
        if abs(dy) < lineHeight {
            return dx > 0 ? 1.0 + dx * 0.02 : 100.0 + abs(dx)
        }

        // Next line(s) down: positive dy — base penalty ensures same-line wins
        if dy > 0 {
            return 50.0 + dy + abs(dx) * 0.1
        }

        // Going back up: heavy penalty
        return 200.0 + abs(dy) * 5.0 + abs(dx)
    }

    // MARK: - Block Extraction (dispatcher)

    private func extractBlocks(from page: PDFPage, pageNumber: Int, pageHeight: CGFloat) -> [TextBlock] {
        if let blocks = extractBlocksViaCharacterBounds(from: page, pageNumber: pageNumber,
                                                        pageHeight: pageHeight),
           !blocks.isEmpty {
            return blocks
        }
        return extractBlocksViaParagraphSplit(from: page, pageNumber: pageNumber,
                                              pageHeight: pageHeight)
    }

    /// Result of smart extraction indicating whether OCR was used.
    private struct SmartExtractionResult {
        let blocks: [TextBlock]
        let usedOCR: Bool
    }

    /// Smart extraction: tries PDFKit first, validates quality, falls back to OCR if layout is problematic.
    /// This runs synchronously for good layouts and only triggers async OCR when needed.
    private func extractBlocksSmart(
        from page: PDFPage,
        pageNumber: Int,
        pageHeight: CGFloat,
        engine: OCREngine
    ) async throws -> SmartExtractionResult {
        // Quick pre-check: detect scattered line-level layout using character bounds
        // This catches brochures/tickets where lines at similar Y have very different X
        if hasScatteredLines(page) {
            let ocrBlocks = try await extractBlocksViaOCR(from: page, pageNumber: pageNumber, engine: engine)
            if !ocrBlocks.isEmpty {
                return SmartExtractionResult(blocks: ocrBlocks, usedOCR: true)
            }
        }

        let pdfBlocks = extractBlocks(from: page, pageNumber: pageNumber, pageHeight: pageHeight)

        // If PDFKit returned nothing, try OCR
        if pdfBlocks.isEmpty {
            let ocrBlocks = try await extractBlocksViaOCR(from: page, pageNumber: pageNumber, engine: engine)
            return SmartExtractionResult(blocks: ocrBlocks, usedOCR: true)
        }

        // Validate layout quality
        let quality = assessLayoutQuality(pdfBlocks, pageWidth: page.bounds(for: .mediaBox).width)

        switch quality {
        case .good:
            return SmartExtractionResult(blocks: pdfBlocks, usedOCR: false)
        case .poor:
            // Layout is problematic — use OCR instead
            let ocrBlocks = try await extractBlocksViaOCR(from: page, pageNumber: pageNumber, engine: engine)
            // If OCR got meaningful text, use it; otherwise fall back to PDFKit
            if ocrBlocks.isEmpty {
                return SmartExtractionResult(blocks: pdfBlocks, usedOCR: false)
            }
            return SmartExtractionResult(blocks: ocrBlocks, usedOCR: true)
        }
    }

    /// Quick line-level check for scattered layouts using character bounds.
    /// Looks at text lines (split by \n) and checks if lines at similar Y positions
    /// have very different X center positions — a hallmark of brochure/form layouts.
    private func hasScatteredLines(_ page: PDFPage) -> Bool {
        guard let text = page.string, !text.isEmpty else { return false }

        let nsText = text as NSString
        let total = nsText.length
        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width

        struct LineInfo {
            let yCenter: CGFloat
            let xMid: CGFloat
        }

        var lines: [LineInfo] = []
        var cursor = 0

        while cursor < total {
            let lineStart = cursor
            var lineEnd = lineStart
            while lineEnd < total {
                let ch = nsText.character(at: lineEnd)
                if ch == 0x000A || ch == 0x000D { break }
                lineEnd += 1
            }

            if lineEnd > lineStart {
                let lineText = nsText.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
                if !lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                    var midYs: [CGFloat] = []
                    var xMin: CGFloat = .greatestFiniteMagnitude
                    var xMax: CGFloat = -.greatestFiniteMagnitude
                    for i in lineStart..<lineEnd {
                        let b = page.characterBounds(at: i)
                        if b.width > 0, b.height > 0 {
                            midYs.append(b.midY)
                            xMin = min(xMin, b.minX)
                            xMax = max(xMax, b.maxX)
                        }
                    }
                    if !midYs.isEmpty {
                        midYs.sort()
                        lines.append(LineInfo(
                            yCenter: midYs[midYs.count / 2],
                            xMid: (xMin + xMax) / 2
                        ))
                    }
                }
            }
            cursor = lineEnd + 1
        }

        guard lines.count >= 3 else { return false }

        // Check for lines at similar Y but very different X midpoints.
        // Two lines at the same height but centered in different page halves
        // indicate a scattered brochure/form layout.
        let yTolerance = pageWidth * 0.05
        let xMidThreshold = pageWidth * 0.30
        var scatteredPairs = 0

        for i in 0..<lines.count {
            for j in (i + 1)..<min(lines.count, i + 6) {
                let a = lines[i], b = lines[j]
                if abs(a.yCenter - b.yCenter) < yTolerance,
                   abs(a.xMid - b.xMid) > xMidThreshold {
                    scatteredPairs += 1
                    if scatteredPairs >= 2 { return true }
                }
            }
        }

        return false
    }

    /// Extracts text blocks from a page using Vision OCR.
    private func extractBlocksViaOCR(
        from page: PDFPage,
        pageNumber: Int,
        engine: OCREngine
    ) async throws -> [TextBlock] {
        let pageBounds = page.bounds(for: .mediaBox)
        guard let cgImage = OCRPageRenderer.render(page: page) else { return [] }
        let result = try await engine.recognize(cgImage: cgImage, pageIndex: pageNumber - 1)
        return OCRTextRebuilder.buildBlocks(from: [result], pageSize: pageBounds.size, pageNumber: pageNumber)
    }

    // MARK: - Layout Quality Assessment

    private enum LayoutQuality {
        case good
        case poor
    }

    /// Analyzes extracted blocks for signs of problematic layout that PDFKit can't handle well.
    private func assessLayoutQuality(_ blocks: [TextBlock], pageWidth: CGFloat) -> LayoutQuality {
        guard blocks.count >= 2 else { return .good }

        // Check 1: Grid/overlap detection
        // Blocks in different X-sections with heavily overlapping Y-ranges indicate
        // a grid layout (tickets, forms, brochures) that PDFKit reads in wrong order.
        if hasGridOverlap(blocks, pageWidth: pageWidth) {
            return .poor
        }

        // Check 2: Excessive fragmentation
        // Many very short blocks (< 3 words) suggest form fields or fragmented extraction
        let shortBlocks = blocks.filter { $0.text.split(separator: " ").count < 3 }
        if blocks.count >= 4, Double(shortBlocks.count) / Double(blocks.count) > 0.5 {
            return .poor
        }

        // Check 3: Gibberish detection
        // High ratio of replacement characters or unusual Unicode suggests broken font mapping
        let totalChars = blocks.reduce(0) { $0 + $1.text.count }
        if totalChars > 0 {
            let gibberishChars = blocks.reduce(0) { count, block in
                count + block.text.unicodeScalars.filter { scalar in
                    scalar == "\u{FFFD}" || // replacement character
                    (scalar.value >= 0xF000 && scalar.value <= 0xF8FF) // private use area
                }.count
            }
            if Double(gibberishChars) / Double(totalChars) > 0.1 {
                return .poor
            }
        }

        // Check 4: Scattered layout detection
        // Blocks at similar Y positions but very different X positions indicate
        // a complex layout (brochures, tickets, forms) that needs OCR for correct reading order
        if hasScatteredLayout(blocks, pageWidth: pageWidth) {
            return .poor
        }

        return .good
    }

    /// Detects layouts where blocks at similar Y positions span different horizontal regions.
    /// This catches brochure-style layouts where text boxes are placed freely on the page.
    private func hasScatteredLayout(_ blocks: [TextBlock], pageWidth: CGFloat) -> Bool {
        guard blocks.count >= 3 else { return false }

        let yTolerance = pageWidth * 0.05 // ~30pt for a 595pt page
        var scatteredPairs = 0
        var totalPairs = 0

        for i in 0..<blocks.count {
            for j in (i + 1)..<blocks.count {
                let b1 = blocks[i], b2 = blocks[j]
                // Check if at similar Y height
                if abs(b1.y - b2.y) < yTolerance {
                    totalPairs += 1
                    // Check if X ranges don't overlap significantly
                    let overlapStart = max(b1.xMin, b2.xMin)
                    let overlapEnd = min(b1.xMax, b2.xMax)
                    let overlap = max(0, overlapEnd - overlapStart)
                    let smallerWidth = min(b1.xMax - b1.xMin, b2.xMax - b2.xMin)
                    if smallerWidth > 0, overlap / smallerWidth < 0.3 {
                        scatteredPairs += 1
                    }
                }
            }
        }

        // If we have enough scattered pairs relative to total same-Y pairs
        return scatteredPairs >= 2
    }

    /// Detects grid-like layouts where blocks in different horizontal sections
    /// have heavily overlapping vertical ranges — a sign of tabular/form layout.
    private func hasGridOverlap(_ blocks: [TextBlock], pageWidth: CGFloat) -> Bool {
        // Split page into left and right halves
        let midX = pageWidth / 2.0
        let leftBlocks = blocks.filter { $0.xMin < midX && $0.xMax < midX * 1.3 }
        let rightBlocks = blocks.filter { $0.xMin > midX * 0.7 }

        guard leftBlocks.count >= 2, rightBlocks.count >= 2 else { return false }

        // Check how many left blocks have a right block at a similar Y position
        // (Y-overlap > 50% of the smaller block's height)
        var overlappingPairs = 0
        for left in leftBlocks {
            let leftTop = left.y
            for right in rightBlocks {
                let rightTop = right.y
                // If Y positions are very close (within ~5% of page width as rough metric), it's a grid row
                if abs(leftTop - rightTop) < pageWidth * 0.08 {
                    overlappingPairs += 1
                    break
                }
            }
        }

        // If >40% of left blocks have a matching right block, it's a grid
        return Double(overlappingPairs) / Double(leftBlocks.count) > 0.4
    }

    // MARK: - P1-1: Character Bounds Extraction (logical-line approach)

    /// Extracts text blocks using per-character geometry.
    ///
    /// Instead of clustering individual chars by Y proximity (fragile for PDFs with watermarks
    /// or decorative text whose glyphs land at unexpected coordinates), we:
    ///   1. Split the text stream by `\n` to get reliable logical lines.
    ///   2. Attach character bounds to each line, filtering X-outliers that indicate
    ///      watermark/background glyphs (they jump backward in X relative to reading order).
    ///   3. Cluster logical lines into paragraphs via median line-spacing threshold.
    ///   4. Use paragraph bounding boxes for N-column detection.
    private func extractBlocksViaCharacterBounds(
        from page: PDFPage,
        pageNumber: Int,
        pageHeight: CGFloat
    ) -> [TextBlock]? {
        guard let text = page.string, !text.isEmpty else { return nil }

        let nsText = text as NSString
        let total = nsText.length
        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width

        // Step 1: Build char-bounds map (only chars with non-zero size)
        var charBoundsMap: [Int: CGRect] = [:]
        charBoundsMap.reserveCapacity(total)
        for i in 0..<total {
            let b = page.characterBounds(at: i)
            if b.width > 0, b.height > 0 { charBoundsMap[i] = b }
        }
        // Less than 20% valid → likely scanned PDF, let fallback handle it
        guard charBoundsMap.count * 5 >= total else { return nil }

        // Step 2: Build logical lines (split by \n, filter X-outliers)
        let logicalLines = buildLogicalLines(from: nsText, charBoundsMap: charBoundsMap,
                                             pageWidth: pageWidth)
        guard !logicalLines.isEmpty else { return nil }

        // Step 3: Cluster lines into paragraphs using median line-spacing threshold
        let paragraphs = clusterLogicalLinesIntoParagraphs(logicalLines, pageWidth: pageWidth)
        guard !paragraphs.isEmpty else { return nil }

        // Step 4: Detect column boundaries from paragraph bounding boxes
        let paragraphRects = paragraphs.map { boundingBoxForParaLines($0) }
        let boundaries = detectColumnBoundaries(from: paragraphRects, pageWidth: pageWidth)

        // Step 5: Build TextBlocks
        let attributedString = page.attributedString
        let bodyFontSize = attributedString.map { detectBodyFontSize($0) } ?? 12.0

        var blocks: [TextBlock] = []
        for (para, rect) in zip(paragraphs, paragraphRects) {
            guard rect != .zero else { continue }
            let blockText = textFromLogicalLines(para)
            let trimmed = blockText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let xMin = rect.minX
            let xMax = rect.maxX
            let relativeY = rect.origin.y / pageHeight
            let isAtTop = relativeY > (1.0 - edgeThreshold)
            let isAtBottom = relativeY < edgeThreshold
            let column = assignColumn(xMin: xMin, boundaries: boundaries)

            let blockType: BlockType
            if isTableStructure(para, pageWidth: pageWidth) {
                // PDF table detection is purely a layout heuristic — we don't
                // reconstruct cells, so pass an empty html. Downstream skip
                // filters (L82, L199) remove this block from RSVP plainText
                // before it ever reaches the pause path, and
                // `DocumentContent.pauseableBlocks` skips empty-html tables.
                blockType = .table(html: "", columnCount: 0, caption: nil)
            } else if let attrStr = attributedString,
                      let firstIdx = para.flatMap({ $0.chars }).map({ $0.index }).min(),
                      let lastIdx  = para.flatMap({ $0.chars }).map({ $0.index }).max() {
                let attrRange = NSRange(location: firstIdx, length: lastIdx - firstIdx + 1)
                blockType = detectBlockTypeWithFont(trimmed, attributedString: attrStr,
                                                   range: attrRange, bodyFontSize: bodyFontSize)
            } else {
                blockType = detectBlockType(trimmed)
            }

            // Build inline markdown formatting from font traits
            let mdText: String?
            if let attrStr = attributedString {
                mdText = buildMarkdownFromLines(para, attributedString: attrStr,
                                                bodyFontSize: bodyFontSize)
            } else {
                mdText = nil
            }

            blocks.append(TextBlock(
                text: trimmed, type: blockType, column: column, pageNumber: pageNumber,
                range: text.startIndex..<text.startIndex,
                markdownText: mdText,
                y: rect.origin.y, xMin: xMin, xMax: xMax,
                isAtTop: isAtTop, isAtBottom: isAtBottom
            ))
        }

        return blocks.isEmpty ? nil : blocks
    }

    // MARK: - Logical Line Helpers

    /// Splits `nsText` by `\n` into logical lines, attaches character bounds,
    /// and filters X-outlier characters (e.g. watermark glyphs that land far to the
    /// left of the expected reading position).
    private func buildLogicalLines(
        from nsText: NSString,
        charBoundsMap: [Int: CGRect],
        pageWidth: CGFloat
    ) -> [PDFLogicalLine] {
        let total = nsText.length
        var lines: [PDFLogicalLine] = []
        var cursor = 0

        while cursor < total {
            let lineStart = cursor
            var lineEnd = lineStart
            while lineEnd < total {
                let ch = nsText.character(at: lineEnd)
                if ch == 0x000A || ch == 0x000D { break }
                lineEnd += 1
            }

            let nsRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            let lineText = lineEnd > lineStart ? nsText.substring(with: nsRange) : ""

            if !lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                // Collect chars in text-stream order; drop X-outliers.
                // An X-outlier is a char whose left edge is >30% of page width to the LEFT
                // of the running rightmost edge — indicating a stray glyph (watermark, etc.)
                var lineChars: [(index: Int, bounds: CGRect)] = []
                var runningMaxX: CGFloat = -(pageWidth)

                for i in lineStart..<lineEnd {
                    guard let b = charBoundsMap[i] else { continue }
                    if runningMaxX - b.minX < pageWidth * 0.30 {
                        lineChars.append((i, b))
                        runningMaxX = max(runningMaxX, b.maxX)
                    }
                    // else: X jumped backward significantly → skip (watermark / decoration)
                }

                let (yCenter, xMin, xMax, yMin, yMax): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
                if lineChars.isEmpty {
                    (yCenter, xMin, xMax, yMin, yMax) = (-1, 0, 0, 0, 0)
                } else {
                    let midYs = lineChars.map { $0.bounds.midY }.sorted()
                    yCenter = midYs[midYs.count / 2]   // median — robust against per-glyph variance
                    xMin = lineChars.map { $0.bounds.minX }.min()!
                    xMax = lineChars.map { $0.bounds.maxX }.max()!
                    yMin = lineChars.map { $0.bounds.minY }.min()!
                    yMax = lineChars.map { $0.bounds.maxY }.max()!
                }

                lines.append(PDFLogicalLine(
                    text: lineText, nsRange: nsRange, chars: lineChars,
                    yCenter: yCenter, xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax
                ))
            }

            cursor = lineEnd + 1
        }

        // Sort top-to-bottom (higher Y = higher on page in PDFKit coordinates).
        // Lines with unknown Y (yCenter == -1) go to the end.
        return lines.sorted {
            if $0.yCenter < 0 { return false }
            if $1.yCenter < 0 { return true }
            return $0.yCenter > $1.yCenter
        }
    }

    /// Groups logical lines into paragraphs.
    /// The paragraph-break threshold is 1.6× the median consecutive line spacing,
    /// adapting automatically to the document's actual leading.
    private func clusterLogicalLinesIntoParagraphs(
        _ lines: [PDFLogicalLine],
        pageWidth: CGFloat
    ) -> [[PDFLogicalLine]] {
        guard !lines.isEmpty else { return [] }

        // Compute median line spacing from consecutive valid lines
        var spacings: [CGFloat] = []
        for i in 1..<lines.count where lines[i - 1].yCenter >= 0 && lines[i].yCenter >= 0 {
            let gap = lines[i - 1].yCenter - lines[i].yCenter
            if gap > 0, gap < 200 { spacings.append(gap) }
        }
        let medianSpacing: CGFloat = spacings.isEmpty ? 12.0
            : { let s = spacings.sorted(); return s[s.count / 2] }()
        let paragraphGap = medianSpacing * 1.6

        var paragraphs: [[PDFLogicalLine]] = []
        var current: [PDFLogicalLine] = [lines[0]]

        for line in lines.dropFirst() {
            let prev = current.last!
            let yGap = prev.yCenter - line.yCenter

            // Two lines at similar Y but non-overlapping X (different columns or sections)
            // should never be in the same paragraph.
            let xGap = max(0.0, max(line.xMin - prev.xMax, prev.xMin - line.xMax))
            let differentSections = xGap > pageWidth * columnGapThreshold

            if line.yCenter < 0 || yGap > paragraphGap || differentSections {
                paragraphs.append(current)
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs
    }

    private func boundingBoxForParaLines(_ lines: [PDFLogicalLine]) -> CGRect {
        let valid = lines.filter { $0.yCenter >= 0 }
        guard !valid.isEmpty else { return .zero }
        return CGRect(
            x: valid.map(\.xMin).min()!,
            y: valid.map(\.yMin).min()!,
            width: valid.map(\.xMax).max()! - valid.map(\.xMin).min()!,
            height: valid.map(\.yMax).max()! - valid.map(\.yMin).min()!
        )
    }

    /// Reconstructs paragraph text by joining logical lines with spaces.
    /// End-of-line hyphens are removed (dehyphenation).
    private func textFromLogicalLines(_ lines: [PDFLogicalLine]) -> String {
        let lineTexts = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result = ""
        for (i, line) in lineTexts.enumerated() {
            if i == 0 {
                result = line
            } else if result.hasSuffix("-") {
                result = String(result.dropLast()) + line   // dehyphenate
            } else {
                result += " " + line
            }
        }
        return result
    }

    // MARK: - Inline Markdown Formatting

    /// Font trait for a character run.
    private enum FontStyle {
        case regular
        case bold
        case italic
        case boldItalic
    }

    /// Builds markdown text with **bold** and *italic* markers from the attributed string.
    /// Falls back to plain text if no formatting is detected.
    private func buildMarkdownFromLines(
        _ lines: [PDFLogicalLine],
        attributedString: NSAttributedString,
        bodyFontSize: CGFloat
    ) -> String? {
        // Collect all char indices in order
        let allChars = lines.flatMap { $0.chars }
        guard !allChars.isEmpty else { return nil }

        // Build a map: original char index → FontStyle
        var styleMap: [Int: FontStyle] = [:]
        for charInfo in allChars {
            let idx = charInfo.index
            guard idx < attributedString.length else { continue }
            let attrs = attributedString.attributes(at: idx, effectiveRange: nil)
            guard let font = attrs[.font] as? NSFont else { continue }
            let traits = font.fontDescriptor.symbolicTraits
            let isBold = traits.contains(.bold) || font.pointSize > bodyFontSize * 1.15
            let isItalic = traits.contains(.italic)
            if isBold && isItalic {
                styleMap[idx] = .boldItalic
            } else if isBold {
                styleMap[idx] = .bold
            } else if isItalic {
                styleMap[idx] = .italic
            } else {
                styleMap[idx] = .regular
            }
        }

        // Check if there's any formatting at all
        let hasFormatting = styleMap.values.contains { $0 != .regular }
        guard hasFormatting else { return nil }

        // Build formatted text line by line, then join with dehyphenation
        var formattedLines: [String] = []

        for line in lines {
            let trimmedText = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmedText.isEmpty else { continue }

            // Build per-character style array for this line's chars
            let lineChars = line.chars
            guard !lineChars.isEmpty else {
                formattedLines.append(trimmedText)
                continue
            }

            // Map original text positions to trimmed text positions
            let whitespacePrefix = line.text.prefix(while: { $0.isWhitespace }).count
            var result = ""
            var currentStyle: FontStyle = .regular
            var runText = ""

            // Walk through the trimmed text character by character
            var charIdx = 0
            for (i, ch) in trimmedText.enumerated() {
                let originalIdx = whitespacePrefix + i
                // Find the corresponding char in lineChars
                let style: FontStyle
                if charIdx < lineChars.count && lineChars[charIdx].index == originalIdx + line.nsRange.location {
                    style = styleMap[lineChars[charIdx].index] ?? .regular
                    charIdx += 1
                } else {
                    // Try to find by original index
                    let targetIdx = originalIdx + line.nsRange.location
                    style = styleMap[targetIdx] ?? currentStyle
                }

                if style != currentStyle && i > 0 {
                    result += wrapWithStyle(runText, style: currentStyle)
                    runText = ""
                }
                currentStyle = style
                runText.append(ch)
            }
            if !runText.isEmpty {
                result += wrapWithStyle(runText, style: currentStyle)
            }

            formattedLines.append(result)
        }

        guard !formattedLines.isEmpty else { return nil }

        // Join with dehyphenation (same logic as textFromLogicalLines)
        var result = ""
        for (i, line) in formattedLines.enumerated() {
            if i == 0 {
                result = line
            } else if result.hasSuffix("-") {
                result = String(result.dropLast()) + line
            } else {
                result += " " + line
            }
        }

        // Merge adjacent same-style markers: "**word1** **word2**" → "**word1 word2**"
        result = mergeAdjacentMarkers(result)

        return result
    }

    private func wrapWithStyle(_ text: String, style: FontStyle) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }

        let leadingSpace = text.prefix(while: { $0.isWhitespace })
        let trailingSpace = text.reversed().prefix(while: { $0.isWhitespace })

        switch style {
        case .regular:
            return text
        case .bold:
            return "\(leadingSpace)**\(trimmed)**\(String(trailingSpace.reversed()))"
        case .italic:
            return "\(leadingSpace)*\(trimmed)*\(String(trailingSpace.reversed()))"
        case .boldItalic:
            return "\(leadingSpace)***\(trimmed)***\(String(trailingSpace.reversed()))"
        }
    }

    /// Merges adjacent identical markers: "**word1** **word2**" → "**word1 word2**"
    private func mergeAdjacentMarkers(_ text: String) -> String {
        var result = text
        // Merge bold+italic: ***text*** ***more*** → ***text more***
        result = result.replacingOccurrences(of: "***" + " " + "***", with: " ")
        result = result.replacingOccurrences(of: "******", with: "")
        // Merge bold: **text** **more** → **text more**
        result = result.replacingOccurrences(of: "** **", with: " ")
        result = result.replacingOccurrences(of: "****", with: "")
        // Merge italic: *text* *more* → *text more*
        // Use regex to avoid matching ** markers
        if let regex = try? NSRegularExpression(pattern: #"(?<!\*)\*(?!\*) \*(?!\*)"#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }
        return result
    }

    // MARK: - Table Detection

    /// Returns true when the paragraph's line structure looks like tabular data:
    /// most lines have large internal X-gaps (cell boundaries) that align across rows.
    private func isTableStructure(_ lines: [PDFLogicalLine], pageWidth: CGFloat) -> Bool {
        guard lines.count >= 2 else { return false }

        let minCellGap = pageWidth * 0.04
        var multiCellLines = 0
        var allGapCenters: [CGFloat] = []

        for line in lines {
            guard line.chars.count >= 4 else { continue }
            let sortedByX = line.chars.sorted { $0.bounds.minX < $1.bounds.minX }

            var lineGapCenters: [CGFloat] = []
            for i in 1..<sortedByX.count {
                let gap = sortedByX[i].bounds.minX - sortedByX[i - 1].bounds.maxX
                if gap >= minCellGap {
                    lineGapCenters.append((sortedByX[i - 1].bounds.maxX + sortedByX[i].bounds.minX) / 2)
                }
            }
            if !lineGapCenters.isEmpty {
                multiCellLines += 1
                allGapCenters.append(contentsOf: lineGapCenters)
            }
        }

        let nonTrivial = lines.filter { $0.chars.count >= 4 }.count
        guard nonTrivial >= 2, multiCellLines * 2 >= nonTrivial else { return false }

        guard !allGapCenters.isEmpty else { return false }
        let sorted = allGapCenters.sorted()
        var clusters: [[CGFloat]] = [[sorted[0]]]
        for center in sorted.dropFirst() {
            if center - clusters[clusters.count - 1].last! < minCellGap {
                clusters[clusters.count - 1].append(center)
            } else {
                clusters.append([center])
            }
        }
        return clusters.contains { $0.count >= 2 }
    }

    // MARK: - Fallback: Paragraph Split Extraction

    private func extractBlocksViaParagraphSplit(
        from page: PDFPage,
        pageNumber: Int,
        pageHeight: CGFloat
    ) -> [TextBlock] {
        guard let pageText = page.string, !pageText.isEmpty else { return [] }

        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width
        let attributedString = page.attributedString
        let bodyFontSize = attributedString.map { detectBodyFontSize($0) } ?? 12.0

        let paragraphs = pageText.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var rawBlocks: [(text: String, bounds: CGRect)] = []
        for paragraph in paragraphs {
            if let range = pageText.range(of: paragraph),
               let selection = page.selection(for: NSRange(range, in: pageText)) {
                rawBlocks.append((paragraph, selection.bounds(for: page)))
            } else {
                rawBlocks.append((paragraph, .zero))
            }
        }

        let boundaries = detectColumnBoundaries(from: rawBlocks.map { $0.bounds }, pageWidth: pageWidth)

        return rawBlocks.map { text, bounds in
            let hasBounds = bounds != .zero
            let xMin = hasBounds ? bounds.minX : 0
            let xMax = hasBounds ? bounds.maxX : 0
            let relativeY = hasBounds ? bounds.origin.y / pageHeight : 0
            let isAtTop = hasBounds && relativeY > (1.0 - edgeThreshold)
            let isAtBottom = hasBounds && relativeY < edgeThreshold
            let column = hasBounds ? assignColumn(xMin: xMin, boundaries: boundaries) : nil

            let blockType: BlockType
            if let attrStr = attributedString, let range = pageText.range(of: text), hasBounds {
                blockType = detectBlockTypeWithFont(text, attributedString: attrStr,
                                                   range: NSRange(range, in: pageText),
                                                   bodyFontSize: bodyFontSize)
            } else {
                blockType = detectBlockType(text)
            }

            return TextBlock(
                text: text, type: blockType, column: column, pageNumber: pageNumber,
                range: pageText.startIndex..<pageText.startIndex,
                y: bounds.origin.y, xMin: xMin, xMax: xMax,
                isAtTop: isAtTop, isAtBottom: isAtBottom
            )
        }
    }

    // MARK: - N-Column Detection

    /// Builds an X-occupancy histogram and returns gap centers between detected columns.
    private func detectColumnBoundaries(from rects: [CGRect], pageWidth: CGFloat) -> [CGFloat] {
        guard pageWidth > 0 else { return [] }
        let nonZero = rects.filter { $0 != .zero }
        guard !nonZero.isEmpty else { return [] }

        let binCount = 100
        var bins = Array(repeating: 0, count: binCount)
        for rect in nonZero {
            let l = max(0, Int((rect.minX / pageWidth) * CGFloat(binCount)))
            let r = min(binCount - 1, Int((rect.maxX / pageWidth) * CGFloat(binCount)))
            guard l <= r else { continue }
            for i in l...r { bins[i] += 1 }
        }

        let minGapBins = max(2, Int(columnGapThreshold * CGFloat(binCount)))
        var boundaries: [CGFloat] = []
        var gapStart: Int? = nil

        for i in 0..<binCount {
            if bins[i] == 0 {
                if gapStart == nil { gapStart = i }
            } else if let start = gapStart {
                let w = i - start
                if w >= minGapBins {
                    boundaries.append(CGFloat(start + w / 2) / CGFloat(binCount) * pageWidth)
                }
                gapStart = nil
            }
        }
        return boundaries
    }

    private func assignColumn(xMin: CGFloat, boundaries: [CGFloat]) -> Int {
        boundaries.sorted().filter { xMin > $0 }.count
    }

    // MARK: - Column Sorting (per-page)

    private func sortBlocksByReadingOrder(_ blocks: [TextBlock], pageWidth: CGFloat) -> [TextBlock] {
        guard blocks.count >= minBlocksForColumnDetection else {
            return blocks.sorted { $0.y > $1.y }
        }
        let hasColumnInfo = blocks.contains { $0.column != nil }
        if hasColumnInfo {
            let count = Set(blocks.compactMap { $0.column }).count
            if count > 1 {
                let groups = Dictionary(grouping: blocks) { $0.column ?? 0 }
                return groups.keys.sorted().flatMap { col in
                    (groups[col] ?? []).sorted { $0.y > $1.y }
                }
            }
        }
        return blocks.sorted { $0.y > $1.y }
    }

    // MARK: - Noise Filtering

    private func filterNoise(_ blocks: [TextBlock], pageCount: Int, pageHeight: CGFloat) -> [TextBlock] {
        guard pageCount > 1 else { return blocks.filter { !isPageNumber($0) } }

        let repeatedTexts = findRepeatedTexts(blocks, threshold: max(2, pageCount / 2))

        return blocks.compactMap { block in
            if isPageNumber(block) { return nil }
            let normalized = block.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if block.isAtTop && repeatedTexts.contains(normalized) { return nil }

            if block.isAtBottom {
                if repeatedTexts.contains(normalized) { return nil }
                if isFootnote(block.text) {
                    return TextBlock(
                        text: block.text, type: .footnote, column: block.column,
                        pageNumber: block.pageNumber, range: block.range,
                        markdownText: block.markdownText,
                        y: block.y, xMin: block.xMin, xMax: block.xMax,
                        isAtTop: block.isAtTop, isAtBottom: block.isAtBottom
                    )
                }
            }
            return block
        }
    }

    private func isFootnote(_ text: String) -> Bool {
        let pattern = #"^[\d\*†‡§¶]+[\s\.\)]"#
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: pattern, options: .regularExpression) != nil
    }

    private func findRepeatedTexts(_ blocks: [TextBlock], threshold: Int) -> Set<String> {
        var counts: [String: Int] = [:]
        for block in blocks where (block.isAtTop || block.isAtBottom) && block.text.count < 200 {
            counts[block.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   default: 0] += 1
        }
        return Set(counts.filter { $0.value >= threshold }.keys)
    }

    private func isPageNumber(_ block: TextBlock) -> Bool {
        let t = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard block.isAtTop || block.isAtBottom, t.count <= 10 else { return false }
        if t.allSatisfy({ $0.isNumber }) { return true }
        if t.range(of: #"^-?\s*\d+\s*-?$"#, options: .regularExpression) != nil { return true }
        if t.lowercased().range(of: #"^(page\s*)?\d+(\s*(of|/)\s*\d+)?$"#, options: .regularExpression) != nil { return true }
        if t.lowercased().range(of: #"^[ivxlcdm]+$"#, options: .regularExpression) != nil,
           t.count <= 6 { return true }
        return false
    }

    // MARK: - Cross-Page Paragraph Merging

    /// Merges paragraphs that are split across page boundaries.
    /// If the last block on page N ends without sentence-final punctuation
    /// and the first block on page N+1 starts with a lowercase letter,
    /// they are joined into a single block.
    private func mergeCrossPageParagraphs(_ blocks: [TextBlock]) -> [TextBlock] {
        guard blocks.count >= 2 else { return blocks }

        var result: [TextBlock] = []
        var i = 0

        while i < blocks.count {
            var current = blocks[i]
            i += 1

            // Only try merging paragraph blocks
            guard current.type == .paragraph else {
                result.append(current)
                continue
            }

            // Check if this block should merge with the next one
            while i < blocks.count {
                let next = blocks[i]

                // Must be on different pages, both paragraphs
                guard let currentPage = current.pageNumber,
                      let nextPage = next.pageNumber,
                      nextPage == currentPage + 1,
                      next.type == .paragraph else { break }

                // Current block must NOT end with sentence-final punctuation
                let lastChar = current.text.last
                let endsWithPunctuation = lastChar == "." || lastChar == "!" ||
                    lastChar == "?" || lastChar == ":" || lastChar == ";"

                // Next block must start with lowercase (continuation)
                let firstChar = next.text.first
                let startsWithLowercase = firstChar?.isLowercase == true

                guard !endsWithPunctuation, startsWithLowercase else { break }

                // Merge: join with space
                let mergedText: String
                if current.text.hasSuffix("-") {
                    mergedText = String(current.text.dropLast()) + next.text
                } else {
                    mergedText = current.text + " " + next.text
                }

                // Merge markdown text too
                let mergedMd: String?
                if let curMd = current.markdownText, let nextMd = next.markdownText {
                    if curMd.hasSuffix("-") {
                        mergedMd = String(curMd.dropLast()) + nextMd
                    } else {
                        mergedMd = curMd + " " + nextMd
                    }
                } else {
                    mergedMd = current.markdownText ?? next.markdownText
                }

                current = TextBlock(
                    text: mergedText, type: .paragraph, column: current.column,
                    pageNumber: current.pageNumber, range: current.range,
                    markdownText: mergedMd,
                    y: current.y, xMin: min(current.xMin, next.xMin),
                    xMax: max(current.xMax, next.xMax),
                    isAtTop: current.isAtTop, isAtBottom: next.isAtBottom
                )
                i += 1
            }

            result.append(current)
        }

        return result
    }

    // MARK: - Block Type Detection

    private func detectBodyFontSize(_ attrString: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        attrString.enumerateAttribute(.font, in: NSRange(location: 0, length: attrString.length)) { value, _, _ in
            if let font = value as? NSFont { counts[font.pointSize, default: 0] += 1 }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 12.0
    }

    private func detectBlockTypeWithFont(
        _ text: String,
        attributedString: NSAttributedString,
        range: NSRange,
        bodyFontSize: CGFloat
    ) -> BlockType {
        if isCaption(text) { return .caption }

        let safeRange = NSRange(
            location: min(range.location, attributedString.length),
            length: min(range.length, attributedString.length - min(range.location, attributedString.length))
        )
        guard safeRange.length > 0 else { return detectBlockType(text) }

        var maxFontSize: CGFloat = 0
        var totalChars = 0
        var boldChars = 0
        attributedString.enumerateAttribute(.font, in: safeRange) { value, attrRange, _ in
            if let font = value as? NSFont {
                maxFontSize = max(maxFontSize, font.pointSize)
                let len = attrRange.length
                totalChars += len
                if font.fontDescriptor.symbolicTraits.contains(.bold) {
                    boldChars += len
                }
            }
        }

        let ratio = maxFontSize / bodyFontSize

        // Large font → heading with level based on size ratio
        if ratio > 1.8 { return .heading(level: 1) }
        if ratio > 1.5 { return .heading(level: 2) }
        if ratio > 1.2 { return .heading(level: 3) }

        // All bold + short text → subheading (h4)
        let isMostlyBold = totalChars > 0 && boldChars * 100 / totalChars > 80
        if isMostlyBold && text.count < 120 && !text.contains("\n") {
            return .heading(level: 4)
        }

        return detectBlockType(text)
    }

    private func detectBlockType(_ text: String) -> BlockType {
        let t = text.trimmingCharacters(in: .whitespaces)
        if isCaption(t) { return .caption }
        if !t.contains("\n") && t.count < 100,
           t.first?.isUppercase == true, !t.hasSuffix("."), !t.hasSuffix(","),
           t.split(separator: " ").count <= 10 { return .heading(level: 2) }
        if t.hasPrefix("•") || t.hasPrefix("-") || t.hasPrefix("*") { return .list }
        if let first = t.first, first.isNumber,
           t.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) != nil { return .list }
        return .paragraph
    }

    private func isCaption(_ text: String) -> Bool {
        let pattern = #"^(fig(ure)?|рис(унок)?|table|таблица|scheme|схема|fig\.|рис\.)\.?\s*\d+"#
        return text.lowercased().range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Metadata Extraction

    private func extractTitle(from document: PDFDocument, url: URL) -> String? {
        if let attrs = document.documentAttributes,
           let title = attrs[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return url.deletingPathExtension().lastPathComponent
    }

    private func extractMetadata(from document: PDFDocument) -> DocumentMetadata? {
        guard let attrs = document.documentAttributes else { return nil }
        return DocumentMetadata(
            author: attrs[PDFDocumentAttribute.authorAttribute] as? String,
            creationDate: attrs[PDFDocumentAttribute.creationDateAttribute] as? Date,
            modificationDate: attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date,
            pageCount: document.pageCount,
            subject: attrs[PDFDocumentAttribute.subjectAttribute] as? String,
            keywords: (attrs[PDFDocumentAttribute.keywordsAttribute] as? String)?
                .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )
    }
}
