import Foundation

/// Reader for DOCX documents.
/// Extracts the ZIP archive to a temp directory, parses word/document.xml
/// and docProps/core.xml for content and metadata.
/// No external dependencies — uses /usr/bin/unzip and Foundation XMLParser.
final class DOCXReader: DocumentReader {
    static let supportedExtensions = ["docx"]

    func read(from url: URL) async throws -> DocumentContent {
        let tempDir = try unzipDOCX(at: url)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Parse metadata from docProps/core.xml
        var title: String?
        var author: String?
        let coreURL = tempDir.appendingPathComponent("docProps/core.xml")
        if FileManager.default.fileExists(atPath: coreURL.path),
           let coreData = try? Data(contentsOf: coreURL) {
            let coreParser = DOCXCorePropsParser()
            try? coreParser.parse(data: coreData)
            title = coreParser.title
            author = coreParser.author
        }

        // 2. Load style mappings from word/styles.xml
        var styleMap: [String: String] = [:]
        let stylesURL = tempDir.appendingPathComponent("word/styles.xml")
        if FileManager.default.fileExists(atPath: stylesURL.path),
           let stylesData = try? Data(contentsOf: stylesURL) {
            let stylesParser = DOCXStylesParser()
            try? stylesParser.parse(data: stylesData)
            styleMap = stylesParser.styleMap
        }

        // 3. Load relationship map from word/_rels/document.xml.rels
        // (rId → relative path, used to resolve embedded image references)
        var relsMap: [String: String] = [:]
        let relsURL = tempDir.appendingPathComponent("word/_rels/document.xml.rels")
        if FileManager.default.fileExists(atPath: relsURL.path),
           let relsData = try? Data(contentsOf: relsURL) {
            let relsParser = DOCXRelsParser()
            try? relsParser.parse(data: relsData)
            relsMap = relsParser.relsMap
        }

        // 4. Parse document content from word/document.xml
        let documentURL = tempDir.appendingPathComponent("word/document.xml")
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            throw DocumentError.readingFailed("Invalid DOCX: missing word/document.xml")
        }
        let documentData = try Data(contentsOf: documentURL)
        let contentParser = DOCXContentParser(
            styleMap: styleMap,
            relsMap: relsMap,
            wordDir: tempDir.appendingPathComponent("word")
        )
        try contentParser.parse(data: documentData)

        var allBlocks = contentParser.blocks

        // 5. Parse footnotes if referenced
        if !contentParser.footnoteRefIds.isEmpty {
            let footnotesURL = tempDir.appendingPathComponent("word/footnotes.xml")
            if FileManager.default.fileExists(atPath: footnotesURL.path),
               let footnotesData = try? Data(contentsOf: footnotesURL) {
                let footnotesParser = DOCXFootnotesParser(
                    requestedIds: Set(contentParser.footnoteRefIds)
                )
                try? footnotesParser.parse(data: footnotesData)
                allBlocks.append(contentsOf: footnotesParser.blocks)
            }
        }

        guard !allBlocks.isEmpty else {
            throw DocumentError.emptyDocument
        }

        // Prepend title as first block
        if let title = title, !title.isEmpty {
            let titleBlock = TextBlock(
                text: title,
                type: .heading(level: 1),
                range: title.startIndex..<title.endIndex
            )
            allBlocks.insert(titleBlock, at: 0)
        }

        let plainText = allBlocks
            .map { $0.text }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the table of contents from heading-styled blocks. `DOCXContentParser`
        // already maps `Heading 1`–`Heading 6` (both English IDs and the styles.xml
        // name fallback) to `.heading(level:)`, so the generic `fromBlocks` builder
        // produces a correct tree. Word counts agree between Swift and the DOCX
        // preview's JS walker because the preview renders blocks 1:1 (no marked.js
        // placeholder substitutions) and the only off-screen placeholder is the
        // single `"image"` token, which `fromBlocks` also counts as one word.
        // Stay nil when the doc has no real headings (only the prepended title).
        let toc = TableOfContents.fromBlocks(allBlocks)
        let resolvedTOC: TableOfContents? = (toc.entries.count <= 1) ? nil : toc

        return DocumentContent(
            title: title,
            blocks: allBlocks,
            plainText: plainText,
            metadata: DocumentMetadata(author: author),
            toc: resolvedTOC
        )
    }

    // MARK: - ZIP extraction

    private func unzipDOCX(at url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempDir)
            throw DocumentError.readingFailed("Failed to extract DOCX archive")
        }

        return tempDir
    }
}

// MARK: - docProps/core.xml parser

/// Parses docProps/core.xml for title and author metadata.
private final class DOCXCorePropsParser: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?

    private var currentElement = ""
    private var currentText = ""

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = localName(elementName)
        if local == "title" || local == "creator" {
            currentElement = local
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !currentElement.isEmpty {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let local = localName(elementName)
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if local == "title" && !trimmed.isEmpty {
            title = trimmed
        } else if local == "creator" && !trimmed.isEmpty {
            author = trimmed
        }
        currentElement = ""
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name.lowercased()
    }
}

// MARK: - word/styles.xml parser

/// Parses word/styles.xml to map style IDs to style names.
/// E.g. "Heading1" style ID -> "heading 1" normalized name.
private final class DOCXStylesParser: NSObject, XMLParserDelegate {
    /// styleId -> normalized name (lowercased)
    var styleMap: [String: String] = [:]

    private var currentStyleId: String?
    private var currentStyleName: String?

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = localName(elementName)
        if local == "style" {
            currentStyleId = attributes["w:styleId"]
            currentStyleName = nil
        } else if local == "name", let val = attributes["w:val"] {
            currentStyleName = val
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let local = localName(elementName)
        if local == "style" {
            if let id = currentStyleId, let name = currentStyleName {
                styleMap[id] = name.lowercased()
            }
            currentStyleId = nil
            currentStyleName = nil
        }
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name.lowercased()
    }
}

// MARK: - word/document.xml parser

/// Parses word/document.xml into TextBlock array.
/// Handles paragraphs, headings, lists, blockquotes, and tables.
private final class DOCXContentParser: NSObject, XMLParserDelegate {
    var blocks: [TextBlock] = []

    private let styleMap: [String: String]
    private let relsMap: [String: String]
    private let wordDir: URL?
    private var currentText = ""
    private var pendingBlockType: BlockType = .paragraph
    private var insideBody = false
    private var insideParagraph = false
    private var insideParagraphProps = false
    private var insideRun = false
    private var insideRunProps = false
    private var elementStack: [String] = []

    // Track current paragraph's style
    private var currentPStyleId: String?
    private var currentNumLevel: Int?
    private struct RunInfo {
        let text: String
        let fontNames: Set<String>
    }
    private var paragraphRuns: [RunInfo] = []
    private var currentRunText = ""
    private var currentRunFonts: Set<String> = []

    // Table state
    private var insideTable = false
    private var tableRows: [[String]] = []     // rows of cell texts
    private var currentRowCells: [String] = []
    private var insideTableCell = false

    // Footnote references (IDs encountered in body)
    private(set) var footnoteRefIds: [String] = []

    // OMML (math) state — populated while we're inside an `<m:oMath>` subtree so
    // we can convert it to LaTeX on close and emit a `.formula` block.
    private var omathDepth = 0
    private var ommlStack: [OMMLNode] = []

    init(
        styleMap: [String: String] = [:],
        relsMap: [String: String] = [:],
        wordDir: URL? = nil
    ) {
        self.styleMap = styleMap
        self.relsMap = relsMap
        self.wordDir = wordDir
        super.init()
    }

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
        if let error = parser.parserError {
            throw DocumentError.readingFailed("DOCX document.xml parse error: \(error.localizedDescription)")
        }
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = localName(elementName)
        elementStack.append(local)

        // OMML capture: once we hit `<m:oMath>` we redirect all child events into
        // an OMMLNode tree, leaving the rest of the parser logic untouched. Skip
        // OMML inside table cells in v1 — the table flow uses currentText for cell
        // accumulation and would garble the layout if we injected a formula block.
        if local == "omath" {
            if insideBody && !insideTableCell {
                omathDepth += 1
                let node = OMMLNode(name: local, attributes: attributes)
                ommlStack.append(node)
            }
            return
        }
        if omathDepth > 0 {
            let node = OMMLNode(name: local, attributes: attributes)
            ommlStack.last?.children.append(node)
            ommlStack.append(node)
            return
        }

        switch local {
        case "body":
            insideBody = true

        // MARK: Table elements
        case "tbl":
            if insideBody {
                insideTable = true
                tableRows = []
            }

        case "tr":
            if insideTable {
                currentRowCells = []
            }

        case "tc":
            if insideTable {
                insideTableCell = true
                currentText = ""
            }

        // MARK: Paragraph
        case "p":
            if insideBody {
                insideParagraph = true
                // In table cells, separate multiple paragraphs with space
                if insideTableCell && !currentText.isEmpty {
                    currentText += " "
                } else if !insideTableCell {
                    currentText = ""
                    currentPStyleId = nil
                    currentNumLevel = nil
                    paragraphRuns = []
                    pendingBlockType = .paragraph
                }
            }

        case "r":
            if insideParagraph && !insideTableCell {
                insideRun = true
                currentRunText = ""
                currentRunFonts = []
            }

        case "ppr":
            if insideParagraph {
                insideParagraphProps = true
            }

        case "rpr":
            if insideRun {
                insideRunProps = true
            }

        case "pstyle":
            if insideParagraphProps && !insideTableCell, let val = attributes["w:val"] {
                currentPStyleId = val
                pendingBlockType = blockType(forStyleId: val)
            }

        case "rfonts":
            if insideRunProps {
                captureRunFonts(from: attributes)
            }

        case "numpr":
            if insideParagraphProps && !insideTableCell {
                pendingBlockType = .list
            }

        case "ilvl":
            if insideParagraphProps, let val = attributes["w:val"], let level = Int(val) {
                currentNumLevel = level
            }

        case "footnotereference":
            if let id = attributes["w:id"], id != "0" && id != "1" {
                // id 0 = separator, 1 = continuation separator — skip those
                footnoteRefIds.append(id)
            }

        case "blip":
            // <a:blip r:embed="rId..."> inside a paragraph references an embedded image
            // via word/_rels/document.xml.rels. Skip images inside table cells in v1 — they
            // would break table-row text accumulation.
            if insideBody && insideParagraph && !insideTableCell,
               let rId = attributes["r:embed"] {
                emitImage(rId: rId)
            }

        case "t":
            break // text content handled in foundCharacters

        case "tab":
            if insideParagraph {
                currentText += insideTableCell ? " " : "\t"
                if insideRun && !insideTableCell {
                    currentRunText += "\t"
                }
            }

        case "br":
            if insideParagraph {
                currentText += " "
                if insideRun && !insideTableCell {
                    currentRunText += "\n"
                }
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if omathDepth > 0 {
            // Inside OMML — only the `m:t` element carries glyphs we want.
            if let top = ommlStack.last, top.name == "t" {
                top.text += string
            }
            return
        }
        guard insideBody && insideParagraph else { return }
        if let last = elementStack.last, last == "t" {
            currentText += string
            if insideRun && !insideTableCell {
                currentRunText += string
            }
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let local = localName(elementName)
        if !elementStack.isEmpty { elementStack.removeLast() }

        // OMML capture mirror of didStartElement. When the top-level `<m:oMath>` closes,
        // flush any text accumulated before it (so the formula doesn't run together with
        // the preceding sentence) and emit a `.formula` block.
        if local == "omath" {
            if omathDepth > 0 {
                let root = ommlStack.removeLast()
                omathDepth -= 1
                if omathDepth == 0 {
                    emitFormula(from: root)
                }
            }
            return
        }
        if omathDepth > 0 {
            if !ommlStack.isEmpty { ommlStack.removeLast() }
            return
        }

        switch local {
        case "body":
            if insideParagraph { flushBlock() }
            insideBody = false

        case "tbl":
            if insideBody {
                flushTable()
                insideTable = false
            }

        case "tr":
            if insideTable {
                tableRows.append(currentRowCells)
                currentRowCells = []
            }

        case "tc":
            if insideTable {
                let cellText = currentText
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentRowCells.append(cellText)
                insideTableCell = false
                currentText = ""
            }

        case "p":
            if insideBody && !insideTableCell {
                flushBlock()
                insideParagraph = false
                insideParagraphProps = false
            }

        case "ppr":
            insideParagraphProps = false

        case "r":
            if insideRun && !insideTableCell {
                let text = currentRunText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    paragraphRuns.append(RunInfo(text: text, fontNames: currentRunFonts))
                }
                currentRunText = ""
                currentRunFonts = []
                insideRun = false
                insideRunProps = false
            }

        case "rpr":
            insideRunProps = false

        default:
            break
        }
    }

    // MARK: - Table flushing

    /// Builds an HTML `<table>` from the captured rows and emits a single
    /// `.table(html:, columnCount:, caption:)` block. The block's text is the
    /// canonical placeholder word so the engine pauses on one beat per table
    /// (previously: one beat per row, with all cells joined by " | " — which
    /// disrupted reading and gave RSVP a bunch of glance-and-skip words).
    private func flushTable() {
        guard !tableRows.isEmpty else { return }

        let nonEmptyRows = tableRows.filter { row in
            row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        guard !nonEmptyRows.isEmpty else {
            tableRows = []
            currentRowCells = []
            return
        }

        let columnCount = nonEmptyRows.map(\.count).max() ?? 0
        let html = Self.tableHTML(rows: nonEmptyRows, headerRow: true)

        let placeholder = RSVPEngine.placeholderTable
        blocks.append(TextBlock(
            text: placeholder,
            type: .table(html: html, columnCount: columnCount, caption: nil),
            range: placeholder.startIndex..<placeholder.endIndex
        ))

        tableRows = []
        currentRowCells = []
    }

    /// Emits a minimal `<table>` with `<thead>` + `<tbody>`. The first row is
    /// promoted to header when `headerRow` is true — DOCX doesn't reliably mark
    /// `<w:tblHeader>`, so we use the common-case heuristic. Cells are escaped
    /// for HTML safety.
    private static func tableHTML(rows: [[String]], headerRow: Bool) -> String {
        var out = "<table>"
        if headerRow, let first = rows.first {
            out += "<thead><tr>"
            for cell in first {
                out += "<th>\(escapeHTML(cell))</th>"
            }
            out += "</tr></thead>"
        }
        out += "<tbody>"
        for row in rows.dropFirst(headerRow ? 1 : 0) {
            out += "<tr>"
            for cell in row {
                out += "<td>\(escapeHTML(cell))</td>"
            }
            out += "</tr>"
        }
        out += "</tbody></table>"
        return out
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Helpers

    private func blockType(forStyleId styleId: String) -> BlockType {
        let lowered = styleId.lowercased()

        if let level = headingLevel(from: lowered) {
            return .heading(level: level)
        }

        if let styleName = styleMap[styleId], let level = headingLevel(from: styleName) {
            return .heading(level: level)
        }

        let quotePatterns = ["quote", "blockquote", "intense quote", "block text"]
        if quotePatterns.contains(where: { lowered.contains($0) }) ||
           (styleMap[styleId].map { name in quotePatterns.contains(where: { name.contains($0) }) } ?? false) {
            return .quote
        }

        let listPatterns = ["list", "bullet", "toc"]
        if listPatterns.contains(where: { lowered.contains($0) }) ||
           (styleMap[styleId].map { name in listPatterns.contains(where: { name.contains($0) }) } ?? false) {
            return .list
        }

        return .paragraph
    }

    private func headingLevel(from string: String) -> Int? {
        for i in 1...6 {
            let variants = ["heading\(i)", "heading \(i)", "заголовок \(i)"]
            if variants.contains(where: { string.contains($0) }) {
                return i
            }
        }

        if string.contains("title") && !string.contains("subtitle") {
            return 1
        }
        if string.contains("subtitle") {
            return 2
        }

        return nil
    }

    private func flushBlock() {
        let text = currentText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            currentText = ""
            paragraphRuns = []
            return
        }

        if isMonospacedCodeParagraph {
            appendCodeBlock(source: text)
            currentText = ""
            paragraphRuns = []
            pendingBlockType = .paragraph
            return
        }

        var finalText = text
        if case .list = pendingBlockType {
            let indent = String(repeating: "  ", count: currentNumLevel ?? 0)
            finalText = "\(indent)• \(text)"
        }

        blocks.append(TextBlock(text: finalText, type: pendingBlockType,
                                range: finalText.startIndex..<finalText.endIndex))
        currentText = ""
        paragraphRuns = []
        pendingBlockType = .paragraph
    }

    private var isMonospacedCodeParagraph: Bool {
        guard case .paragraph = pendingBlockType else { return false }
        let textRuns = paragraphRuns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !textRuns.isEmpty else { return false }
        return textRuns.allSatisfy { run in
            !run.fontNames.isEmpty && run.fontNames.allSatisfy(Self.isMonospacedFont)
        }
    }

    private func appendCodeBlock(source: String) {
        let placeholder = RSVPEngine.placeholderCode
        if let last = blocks.last,
           case .code(let language, let previousSource) = last.type {
            blocks.removeLast()
            let merged = previousSource + "\n" + source
            blocks.append(TextBlock(
                text: placeholder,
                type: .code(language: language, source: merged),
                range: placeholder.startIndex..<placeholder.endIndex
            ))
        } else {
            blocks.append(TextBlock(
                text: placeholder,
                type: .code(language: nil, source: source),
                range: placeholder.startIndex..<placeholder.endIndex
            ))
        }
    }

    private func captureRunFonts(from attributes: [String: String]) {
        for (key, value) in attributes {
            let attr = localName(key)
            guard ["ascii", "hansi", "eastasia", "cs"].contains(attr) else { continue }
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !normalized.isEmpty {
                currentRunFonts.insert(normalized)
            }
        }
    }

    private static func isMonospacedFont(_ fontName: String) -> Bool {
        let lower = fontName.lowercased()
        let monospacePatterns = [
            "courier",
            "consolas",
            "monaco",
            "menlo",
            "source code pro",
            "sf mono",
            "lucida console"
        ]
        return monospacePatterns.contains { lower.contains($0) }
    }

    /// Converts the captured OMML tree to LaTeX and emits a `.formula` TextBlock with
    /// the canonical placeholder word so the RSVP engine pauses on the math beat. Any
    /// preceding text in the paragraph is flushed first, so the formula lands between
    /// "...such that" and "for all x." as a separate block (same shape as images).
    /// No-op when the converted LaTeX is empty.
    private func emitFormula(from root: OMMLNode) {
        let latex = OMMLToLaTeX.convert(root)
        guard !latex.isEmpty else { return }

        flushBlock()

        let placeholder = RSVPEngine.placeholderFormula
        blocks.append(TextBlock(
            text: placeholder,
            type: .formula(latex: latex, caption: nil),
            range: placeholder.startIndex..<placeholder.endIndex
        ))

        currentText = ""
        pendingBlockType = .paragraph
    }

    /// Resolves an `r:embed` rId to an embedded image file via relsMap, loads its bytes,
    /// and emits an `.image` TextBlock. Any text accumulated so far is flushed first so
    /// the image lands between the text before and after it within the paragraph.
    private func emitImage(rId: String) {
        guard let target = relsMap[rId], let wordDir else { return }

        // Target is relative to word/ (e.g. "media/image1.png"). Resolve and standardize.
        let imageURL = URL(fileURLWithPath: target, relativeTo: wordDir).standardized
        guard let data = try? Data(contentsOf: imageURL) else { return }

        let mime = Self.mimeForExtension(imageURL.pathExtension.lowercased())
        let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"

        flushBlock()

        let imageText = "image"
        blocks.append(TextBlock(
            text: imageText,
            type: .image(src: dataURL, altText: nil),
            range: imageText.startIndex..<imageText.endIndex
        ))

        currentText = ""
        pendingBlockType = .paragraph
    }

    private static func mimeForExtension(_ ext: String) -> String {
        switch ext {
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "bmp":          return "image/bmp"
        case "tiff", "tif":  return "image/tiff"
        case "svg":          return "image/svg+xml"
        case "webp":         return "image/webp"
        case "wmf":          return "image/x-wmf"
        case "emf":          return "image/x-emf"
        default:             return "application/octet-stream"
        }
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...]).lowercased()
        }
        return name.lowercased()
    }
}

// MARK: - word/footnotes.xml parser

/// Parses word/footnotes.xml and extracts text for referenced footnote IDs.
private final class DOCXFootnotesParser: NSObject, XMLParserDelegate {
    var blocks: [TextBlock] = []

    private let requestedIds: Set<String>
    private var currentFootnoteId: String?
    private var isCollecting = false
    private var currentText = ""
    private var elementStack: [String] = []

    init(requestedIds: Set<String>) {
        self.requestedIds = requestedIds
        super.init()
    }

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = localName(elementName)
        elementStack.append(local)

        if local == "footnote" {
            if let id = attributes["w:id"], requestedIds.contains(id) {
                currentFootnoteId = id
                isCollecting = true
                currentText = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isCollecting else { return }
        if let last = elementStack.last, last == "t" {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let local = localName(elementName)
        if !elementStack.isEmpty { elementStack.removeLast() }

        if local == "footnote" && isCollecting {
            let text = currentText
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let id = currentFootnoteId {
                let footnoteText = "[\(id)] \(text)"
                blocks.append(TextBlock(text: footnoteText, type: .footnote,
                                        range: footnoteText.startIndex..<footnoteText.endIndex))
            }
            isCollecting = false
            currentFootnoteId = nil
            currentText = ""
        }
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...]).lowercased()
        }
        return name.lowercased()
    }
}

// MARK: - word/_rels/document.xml.rels parser

/// Parses `word/_rels/document.xml.rels` into a `rId → Target` map. The `Target`
/// path is relative to the rels file's parent directory (i.e. relative to `word/`),
/// so callers should resolve it against `tempDir/word/`.
private final class DOCXRelsParser: NSObject, XMLParserDelegate {
    /// rId → relative path (e.g. "rId5" → "media/image1.png")
    var relsMap: [String: String] = [:]

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // Rels XML uses unprefixed element names (`Relationship`).
        if elementName.lowercased() == "relationship",
           let id = attributes["Id"],
           let target = attributes["Target"] {
            relsMap[id] = target
        }
    }
}
