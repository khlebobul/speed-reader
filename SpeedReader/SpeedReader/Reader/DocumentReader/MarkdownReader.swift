import Foundation

/// Reader for Markdown files (.md, .markdown)
final class MarkdownReader: DocumentReader {
    static let supportedExtensions = ["md", "markdown"]

    /// Strips markdown formatting to produce clean plain text matching the
    /// visible content of a marked.js render. Used by the Edit tab to keep
    /// the RSVP engine in sync with edited source.
    static func plainText(fromMarkdown markdown: String) -> String {
        PDF2MDExtractor.plainText(fromMarkdown: markdown)
    }

    func read(from url: URL) async throws -> DocumentContent {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DocumentError.readingFailed(error.localizedDescription)
        }

        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentError.emptyDocument
        }

        let blocks = parseBlocks(from: raw)
        let plainText = blocks
            .map { $0.text }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // For Markdown, `DocumentContent.toc` exists only as a **structural
        // signal** ("this document has headings") so the unified toolbar's TOC
        // chip can be shown by `FileInputView.hasTOC`. Its `wordIndex` values
        // are NOT reliable for seeking — `MarkdownTabsPreviewView` ignores
        // them and rebuilds an accurate TOC from the DOM walker that produces
        // the engine's word stream (formulas, code blocks, images, tables all
        // count differently between Swift `parseBlocks` and the JS walker).
        let toc = TableOfContents.fromBlocks(blocks)
        let resolvedTOC: TableOfContents? = toc.isEmpty ? nil : toc

        return DocumentContent(
            title: url.deletingPathExtension().lastPathComponent,
            blocks: blocks,
            plainText: plainText,
            markdownText: raw,
            toc: resolvedTOC
        )
    }

    // MARK: - Block Parsing

    private func parseBlocks(from text: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        var paragraphBuffer: [String] = []
        var insideCodeBlock = false
        var codeLines: [String] = []
        var codeLanguage: String? = nil

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(makeBlock(joined, .paragraph))
            }
            paragraphBuffer = []
        }

        func flushCode() {
            let code = codeLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                // Block text is the placeholder word so the RSVP engine pauses on
                // one beat instead of reading the source line-by-line. The raw
                // source + language hint ride on the associated value for
                // `CodePreviewView`.
                blocks.append(makeBlock(RSVPEngine.placeholderCode,
                                        .code(language: codeLanguage, source: code)))
            }
            codeLines = []
            codeLanguage = nil
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Code fences: ``` or ~~~ — opening fence can carry a language tag
            // right after the fence (` ```swift`, `~~~python`, etc.).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if insideCodeBlock {
                    flushCode()
                    insideCodeBlock = false
                } else {
                    flushParagraph()
                    insideCodeBlock = true
                    let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                    let tag = String(trimmed.dropFirst(fence.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = tag.isEmpty ? nil : tag.lowercased()
                }
                i += 1
                continue
            }

            if insideCodeBlock {
                codeLines.append(raw)
                i += 1
                continue
            }

            // Empty line → flush paragraph buffer
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // ATX heading: # H1 … ###### H6
            if let (level, headingText) = parseATXHeading(raw) {
                flushParagraph()
                blocks.append(makeBlock(headingText, .heading(level: level)))
                i += 1
                continue
            }

            // Setext underline: === → H1, --- → H2
            // If paragraph buffer has content, the buffered text is the heading.
            // If buffer is empty, treat as horizontal rule and skip.
            if trimmed.allSatisfy({ $0 == "=" }), trimmed.count >= 2 {
                if !paragraphBuffer.isEmpty {
                    let headingText = paragraphBuffer.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    paragraphBuffer = []
                    blocks.append(makeBlock(headingText, .heading(level: 1)))
                }
                i += 1
                continue
            }
            if trimmed.allSatisfy({ $0 == "-" }), trimmed.count >= 2 {
                if !paragraphBuffer.isEmpty {
                    let headingText = paragraphBuffer.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    paragraphBuffer = []
                    blocks.append(makeBlock(headingText, .heading(level: 2)))
                }
                // If buffer is empty → standalone ---, skip as horizontal rule
                i += 1
                continue
            }

            // Horizontal rules: ***, ___
            if (trimmed.allSatisfy({ $0 == "*" }) || trimmed.allSatisfy({ $0 == "_" })),
               trimmed.count >= 3 {
                flushParagraph()
                i += 1
                continue
            }

            // Display math block: $$...$$ on a single line → one formula block.
            if trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4 {
                flushParagraph()
                let latex = String(trimmed.dropFirst(2).dropLast(2))
                emitFormulaBlock(latex: latex, blocks: &blocks)
                i += 1
                continue
            }

            // Display math block: opening `$$` on its own line — collect until the
            // closing `$$` and emit one formula block. Handles the common multi-line
            // form `$$\n...latex...\n$$` used in technical docs.
            if trimmed == "$$" {
                flushParagraph()
                var latexLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    let inner = lines[j].trimmingCharacters(in: .whitespaces)
                    if inner == "$$" { break }
                    latexLines.append(lines[j])
                    j += 1
                }
                if j < lines.count {
                    let latex = latexLines.joined(separator: "\n")
                    emitFormulaBlock(latex: latex, blocks: &blocks)
                    i = j + 1
                    continue
                }
                // Unterminated `$$` — fall through and treat the rest as paragraph text.
            }

            // Footnote definition: [^1]: text — skip entirely
            if trimmed.range(of: #"^\[\^[^\]]+\]:"#, options: .regularExpression) != nil {
                i += 1
                continue
            }

            // Blockquote: > text
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let quoteText = stripInline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                if !quoteText.isEmpty {
                    blocks.append(makeBlock(quoteText, .quote))
                }
                i += 1
                continue
            }

            // List item: -, *, +, or ordered 1.
            if let listText = parseListItem(trimmed) {
                flushParagraph()
                if !listText.isEmpty {
                    blocks.append(makeBlock(listText, .list))
                }
                i += 1
                continue
            }

            // GFM table: header row + separator row + zero or more data rows.
            // The separator row is what distinguishes GFM tables from arbitrary
            // pipe-containing prose (`a | b` in regular text), so we require it
            // to be on the very next line before committing.
            if looksLikeTableRow(trimmed),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                if let (block, consumed) = parseGFMTable(startingAt: i, in: lines) {
                    blocks.append(block)
                    i += consumed
                    continue
                }
            }

            // Regular paragraph line
            let cleaned = stripInline(trimmed)
            if !cleaned.isEmpty {
                paragraphBuffer.append(cleaned)
            }
            i += 1
        }

        flushParagraph()
        if insideCodeBlock { flushCode() }

        return blocks
    }

    // MARK: - Parsing Helpers

    private func parseATXHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" {
            level += 1
            idx = line.index(after: idx)
        }
        guard (1...6).contains(level), idx < line.endIndex, line[idx] == " " else { return nil }
        var text = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        // Strip closing hashes: ## Heading ##
        if let trailingRange = text.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
            text = String(text[..<trailingRange.lowerBound])
        }
        return (level, stripInline(text))
    }

    private func parseListItem(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) {
                var text = String(line.dropFirst(prefix.count))
                // Strip task checkbox: [ ], [x], [X]
                if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                    text = String(text.dropFirst(4))
                }
                return stripInline(text)
            }
        }
        // Ordered: 1. item, 12. item
        if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return stripInline(String(line[range.upperBound...]))
        }
        return nil
    }

    /// Strips inline Markdown: **bold**, *italic*, `code`, [links](url), ~~strike~~, images, footnotes, math, escapes.
    private func stripInline(_ text: String) -> String {
        var s = text
        // Display math: $$...$$ → remove (LaTeX not readable as words)
        s = s.replacingOccurrences(of: #"\$\$[^$]+\$\$"#, with: "", options: .regularExpression)
        // Inline math: $...$ → remove
        s = s.replacingOccurrences(of: #"\$[^$]+\$"#, with: "", options: .regularExpression)
        // Footnote references: [^1], [^note] → remove
        s = s.replacingOccurrences(of: #"\[\^[^\]]+\]"#, with: "", options: .regularExpression)
        // Images: ![alt](url) → remove (preview renders <img>, no text nodes in DOM)
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "", options: .regularExpression)
        // Links: [text](url)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Bold+italic: ***text***, ___text___
        s = s.replacingOccurrences(of: #"\*{3}(.+?)\*{3}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"_{3}(.+?)_{3}"#, with: "$1", options: .regularExpression)
        // Bold: **text**, __text__
        s = s.replacingOccurrences(of: #"\*{2}(.+?)\*{2}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"_{2}(.+?)_{2}"#, with: "$1", options: .regularExpression)
        // Italic: *text*, _text_
        s = s.replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"_(.+?)_"#, with: "$1", options: .regularExpression)
        // Strikethrough: ~~text~~
        s = s.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
        // Inline code: `code`
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // Backslash escapes: \* → *, \` → `, etc.
        s = s.replacingOccurrences(of: #"\\([\\`*_{}[\]()#+\-.!~>|$])"#, with: "$1", options: .regularExpression)
        return s
    }

    private func makeBlock(_ text: String, _ type: BlockType) -> TextBlock {
        TextBlock(text: text, type: type, range: text.startIndex..<text.endIndex)
    }

    /// Emits a `.formula` block with the canonical placeholder word so the engine's
    /// word counter advances by exactly one when it reaches the math. Skips blank
    /// LaTeX bodies so empty `$$$$` doesn't show up as a phantom pause.
    private func emitFormulaBlock(latex rawLatex: String, blocks: inout [TextBlock]) {
        let latex = rawLatex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty else { return }
        blocks.append(makeBlock(RSVPEngine.placeholderFormula,
                                .formula(latex: latex, caption: nil)))
    }

    // MARK: - GFM Tables

    /// Heuristic check: line contains at least one un-escaped pipe — cheap gate
    /// before we look at the separator row.
    private func looksLikeTableRow(_ line: String) -> Bool {
        var prevWasBackslash = false
        for ch in line {
            if ch == "|" && !prevWasBackslash { return true }
            prevWasBackslash = (ch == "\\" && !prevWasBackslash)
        }
        return false
    }

    /// Validates a GFM separator row like `| --- | :---: | ---: |`. Each cell must
    /// be one or more `-` with optional leading/trailing `:` for alignment. We
    /// don't apply the alignment in v1; we just need to recognize the row.
    private func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        let pattern = #"^:?-{1,}:?$"#
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: pattern, options: .regularExpression) == nil {
                return false
            }
        }
        return true
    }

    /// Splits a GFM row by `|`, honoring `\|` as an escaped literal pipe inside a
    /// cell. Strips a single leading/trailing empty cell so both `| a | b |` and
    /// `a | b` produce `["a", "b"]`.
    private func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var prevWasBackslash = false
        for ch in line {
            if ch == "|" && !prevWasBackslash {
                cells.append(current)
                current = ""
                prevWasBackslash = false
                continue
            }
            if ch == "\\" && !prevWasBackslash {
                prevWasBackslash = true
                continue
            }
            if prevWasBackslash {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                prevWasBackslash = false
            } else {
                current.append(ch)
            }
        }
        cells.append(current)

        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeFirst()
        }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    /// Parses a GFM table starting at `start` (header row). Returns `nil` if the
    /// header / separator column counts disagree (mismatched table — fall through
    /// to paragraph rendering). On success returns the emitted block and how many
    /// source lines were consumed.
    private func parseGFMTable(
        startingAt start: Int,
        in lines: [String]
    ) -> (TextBlock, Int)? {
        let headerCells = splitTableRow(lines[start].trimmingCharacters(in: .whitespaces))
            .map { stripInline($0.trimmingCharacters(in: .whitespaces)) }
        let separatorCells = splitTableRow(lines[start + 1].trimmingCharacters(in: .whitespaces))
        guard headerCells.count == separatorCells.count, !headerCells.isEmpty else { return nil }

        var dataRows: [[String]] = []
        var cursor = start + 2
        while cursor < lines.count {
            let raw = lines[cursor]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !looksLikeTableRow(trimmed) { break }
            let cells = splitTableRow(trimmed)
                .map { stripInline($0.trimmingCharacters(in: .whitespaces)) }
            // Pad / clip to header width so the rendered table stays rectangular
            // even if a row has fewer/more cells (GFM spec: extra cells are
            // dropped, missing cells become empty).
            var normalized = cells
            if normalized.count < headerCells.count {
                normalized.append(contentsOf:
                    Array(repeating: "", count: headerCells.count - normalized.count))
            } else if normalized.count > headerCells.count {
                normalized = Array(normalized.prefix(headerCells.count))
            }
            dataRows.append(normalized)
            cursor += 1
        }

        var html = "<table><thead><tr>"
        for cell in headerCells { html += "<th>\(escapeHTML(cell))</th>" }
        html += "</tr></thead><tbody>"
        for row in dataRows {
            html += "<tr>"
            for cell in row { html += "<td>\(escapeHTML(cell))</td>" }
            html += "</tr>"
        }
        html += "</tbody></table>"

        let placeholder = RSVPEngine.placeholderTable
        let block = TextBlock(
            text: placeholder,
            type: .table(html: html, columnCount: headerCells.count, caption: nil),
            range: placeholder.startIndex..<placeholder.endIndex
        )
        return (block, cursor - start)
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
