import Foundation

/// Reader for EPUB e-books.
/// Extracts the ZIP archive to a temp directory, parses OPF spine,
/// then reads XHTML content files in reading order.
/// No external dependencies — uses /usr/bin/unzip and Foundation XMLParser.
final class EPUBReader: DocumentReader {
    static let supportedExtensions = ["epub"]

    func read(from url: URL) async throws -> DocumentContent {
        let tempDir = try unzipEPUB(at: url)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Find OPF path from container.xml
        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw DocumentError.readingFailed("Invalid EPUB: missing META-INF/container.xml")
        }
        let containerData = try Data(contentsOf: containerURL)
        let containerParser = ContainerXMLParser()
        try containerParser.parse(data: containerData)

        guard let opfRelativePath = containerParser.opfPath else {
            throw DocumentError.readingFailed("Invalid EPUB: no OPF path in container.xml")
        }

        // 2. Parse OPF for metadata + manifest + spine
        let opfURL = tempDir.appendingPathComponent(opfRelativePath)
        let opfDir = opfURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            throw DocumentError.readingFailed("Invalid EPUB: OPF file not found")
        }
        let opfData = try Data(contentsOf: opfURL)
        let opfParser = OPFParser()
        try opfParser.parse(data: opfData)

        // 3. Resolve spine items to file URLs
        let spineHrefs = opfParser.spineItemIDs.compactMap { opfParser.manifest[$0] }
        guard !spineHrefs.isEmpty else {
            throw DocumentError.readingFailed("Invalid EPUB: empty spine")
        }

        // 4. Parse each XHTML file in spine order, tracking per-file word ranges
        //    and `id -> wordOffset` maps so the TOC can resolve `href#fragment`.
        var allBlocks: [TextBlock] = []
        var fileInfos: [String: EPUBFileInfo] = [:]  // standardized path -> info

        // The title block (prepended below) shifts every spine file's global word
        // offset, so the running offset starts at the title's word count.
        var globalWordOffset = 0
        if let title = opfParser.title, !title.isEmpty {
            globalWordOffset = TableOfContents.wordCount(in: title)
        }

        for href in spineHrefs {
            let decodedHref = href.removingPercentEncoding ?? href
            let fileURL = opfDir.appendingPathComponent(decodedHref)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let data = try Data(contentsOf: fileURL)
            let xhtmlParser = XHTMLContentParser(baseDir: fileURL.deletingLastPathComponent())
            try xhtmlParser.parse(data: data)
            allBlocks.append(contentsOf: xhtmlParser.blocks)

            fileInfos[fileURL.standardizedFileURL.path] = EPUBFileInfo(
                startWord: globalWordOffset,
                idOffsets: xhtmlParser.idOffsets
            )
            globalWordOffset += xhtmlParser.fileWordCount
        }

        guard !allBlocks.isEmpty else {
            throw DocumentError.emptyDocument
        }

        // Prepend title as first block
        if let title = opfParser.title, !title.isEmpty {
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

        // 5. Build the table of contents — NCX (EPUB 2) or nav.xhtml (EPUB 3),
        //    falling back to heading blocks when neither is present.
        let toc = buildTOC(
            opfParser: opfParser,
            opfDir: opfDir,
            fileInfos: fileInfos,
            blocks: allBlocks
        )

        return DocumentContent(
            title: opfParser.title,
            blocks: allBlocks,
            plainText: plainText,
            metadata: DocumentMetadata(author: opfParser.author),
            toc: toc
        )
    }

    // MARK: - Table of contents

    /// Per-spine-file bookkeeping needed to map TOC `href#fragment` targets to
    /// global RSVP word indices.
    private struct EPUBFileInfo {
        /// Global RSVP word index where this file's text begins.
        let startWord: Int
        /// `id` attribute -> word offset within this file.
        let idOffsets: [String: Int]
    }

    /// Picks the best available TOC source and resolves it to a `TableOfContents`.
    /// Order: EPUB 3 `nav.xhtml` → EPUB 2 `toc.ncx` → heading-block fallback.
    private func buildTOC(
        opfParser: OPFParser,
        opfDir: URL,
        fileInfos: [String: EPUBFileInfo],
        blocks: [TextBlock]
    ) -> TableOfContents? {
        // EPUB 3: <item properties="nav">
        if let navHref = opfParser.navHref {
            let decoded = navHref.removingPercentEncoding ?? navHref
            let navURL = opfDir.appendingPathComponent(decoded)
            if FileManager.default.fileExists(atPath: navURL.path),
               let data = try? Data(contentsOf: navURL) {
                let parser = NavXHTMLParser()
                parser.parse(data: data)
                let toc = resolve(
                    rawEntries: parser.entries,
                    baseDir: navURL.deletingLastPathComponent(),
                    fileInfos: fileInfos
                )
                if let toc, !toc.isEmpty { return toc }
            }
        }

        // EPUB 2: <item media-type="application/x-dtbncx+xml">
        if let ncxHref = opfParser.ncxHref {
            let decoded = ncxHref.removingPercentEncoding ?? ncxHref
            let ncxURL = opfDir.appendingPathComponent(decoded)
            if FileManager.default.fileExists(atPath: ncxURL.path),
               let data = try? Data(contentsOf: ncxURL) {
                let parser = NCXParser()
                parser.parse(data: data)
                let toc = resolve(
                    rawEntries: parser.entries,
                    baseDir: ncxURL.deletingLastPathComponent(),
                    fileInfos: fileInfos
                )
                if let toc, !toc.isEmpty { return toc }
            }
        }

        // Fallback: build from heading blocks (h1–h6 found in the XHTML).
        let fallback = TableOfContents.fromBlocks(blocks)
        return fallback.isEmpty ? nil : fallback
    }

    /// Resolves parser-produced `(title, level, href)` triples — where `href` may
    /// carry a `#fragment` — into a nested `TableOfContents` of global word indices.
    private func resolve(
        rawEntries: [RawTOCEntry],
        baseDir: URL,
        fileInfos: [String: EPUBFileInfo]
    ) -> TableOfContents? {
        var flat: [FlatTOCItem] = []

        for raw in rawEntries {
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !raw.href.isEmpty else { continue }

            // Split "path#fragment"
            let parts = raw.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let pathPart = String(parts[0])
            let fragment = parts.count > 1 ? String(parts[1]) : nil
            guard !pathPart.isEmpty else { continue }  // pure "#fragment" — skip

            let decodedPath = pathPart.removingPercentEncoding ?? pathPart
            let fileURL = baseDir.appendingPathComponent(decodedPath).standardizedFileURL
            guard let info = fileInfos[fileURL.path] else { continue }

            var wordIndex = info.startWord
            if let fragment, let offset = info.idOffsets[fragment] {
                wordIndex += offset
            }

            flat.append(FlatTOCItem(title: title, level: max(1, raw.level), wordIndex: wordIndex))
        }

        guard !flat.isEmpty else { return nil }
        return TableOfContents(entries: TableOfContents.nest(flat))
    }

    // MARK: - ZIP extraction

    private func unzipEPUB(at url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_\(UUID().uuidString)")
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
            throw DocumentError.readingFailed("Failed to extract EPUB archive")
        }

        return tempDir
    }
}

/// A TOC entry as produced by the NCX / nav.xhtml parsers, before `href` is
/// resolved to a global word index.
private struct RawTOCEntry {
    let title: String
    let level: Int
    let href: String
}

// MARK: - container.xml parser

/// Parses META-INF/container.xml to find the OPF file path.
private final class ContainerXMLParser: NSObject, XMLParserDelegate {
    var opfPath: String?

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let error = parser.parserError {
            throw DocumentError.readingFailed("container.xml parse error: \(error.localizedDescription)")
        }
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName.lowercased() == "rootfile" || elementName.hasSuffix(":rootfile") {
            if let path = attributes["full-path"] {
                opfPath = path
            }
        }
    }
}

// MARK: - OPF parser

/// Parses the OPF package document for metadata, manifest, and spine.
private final class OPFParser: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?

    /// manifest id -> href
    var manifest: [String: String] = [:]
    /// spine item IDs in reading order
    var spineItemIDs: [String] = []

    /// href of the EPUB 3 navigation document (`<item properties="nav">`)
    var navHref: String?
    /// href of the EPUB 2 NCX document (`media-type="application/x-dtbncx+xml"`,
    /// or the item referenced by `<spine toc="...">`)
    var ncxHref: String?

    private var currentElement = ""
    private var currentText = ""
    private var insideMetadata = false

    // Deferred NCX resolution: we may see <spine toc="ncx"> before/after the
    // matching <item>, so collect candidates and resolve in parserDidEndDocument.
    private var manifestMediaTypes: [String: String] = [:]
    private var spineTocID: String?

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let error = parser.parserError {
            throw DocumentError.readingFailed("OPF parse error: \(error.localizedDescription)")
        }
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = localName(elementName)

        switch local {
        case "metadata":
            insideMetadata = true

        case "title":
            if insideMetadata {
                currentElement = "title"
                currentText = ""
            }

        case "creator":
            if insideMetadata {
                currentElement = "creator"
                currentText = ""
            }

        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = href
                if let mediaType = attributes["media-type"] {
                    manifestMediaTypes[id] = mediaType
                    if mediaType == "application/x-dtbncx+xml" {
                        ncxHref = ncxHref ?? href
                    }
                }
                // EPUB 3 nav document: properties attribute contains "nav"
                if let properties = attributes["properties"],
                   properties.split(separator: " ").contains("nav") {
                    navHref = href
                }
            }

        case "itemref":
            if let idref = attributes["idref"] {
                spineItemIDs.append(idref)
            }

        case "spine":
            // EPUB 2 points the spine at its NCX via the `toc` attribute.
            if let toc = attributes["toc"] {
                spineTocID = toc
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "title" || currentElement == "creator" {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let local = localName(elementName)

        switch local {
        case "metadata":
            insideMetadata = false

        case "title":
            if insideMetadata && !currentText.isEmpty {
                title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentElement = ""

        case "creator":
            if insideMetadata && !currentText.isEmpty {
                author = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentElement = ""

        default:
            break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        // Prefer the spine's explicit `toc` reference when present.
        if let tocID = spineTocID, let href = manifest[tocID] {
            ncxHref = href
        }
    }

    /// Strip namespace prefix: "dc:title" -> "title"
    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name.lowercased()
    }
}

// MARK: - XHTML content parser

/// Parses XHTML body content into TextBlock array, and records an
/// `id -> wordOffset` map so the TOC can resolve in-file `#fragment` anchors.
private final class XHTMLContentParser: NSObject, XMLParserDelegate {
    var blocks: [TextBlock] = []

    /// `id` attribute value -> word offset within this file (count of words
    /// flushed before the element carrying the id).
    var idOffsets: [String: Int] = [:]
    /// Total words in this file (sum over all flushed blocks).
    private(set) var fileWordCount = 0

    private var currentText = ""
    private var pendingBlockType: BlockType = .paragraph
    private var insideBody = false
    private var elementStack: [String] = []
    private var skipDepth = 0
    private let baseDir: URL

    // Table state. EPUB XHTML tables are emitted as one placeholder beat, with
    // preview HTML reconstructed from cells so RSVP does not read cell text as prose.
    private var insideTable = false
    private var insideTableCell = false
    private var insideTableCaption = false
    private var tableRows: [[String]] = []
    private var currentRowCells: [String] = []
    private var currentTableText = ""
    private var tableCaption: String?

    // MathML state. We support the high-value EPUB 3 path first:
    // <math><semantics><annotation encoding="application/x-tex">...</annotation>.
    private var mathDepth = 0
    private var insideLatexAnnotation = false
    private var latexAnnotation = ""

    init(baseDir: URL) {
        self.baseDir = baseDir
        super.init()
    }

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
        // Don't throw on XHTML parse errors — EPUBs often have minor issues
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        let local = name.contains(":") ? String(name.split(separator: ":").last ?? "") : name
        elementStack.append(local)

        if skipDepth > 0 {
            skipDepth += 1
            return
        }

        if mathDepth > 0 {
            mathDepth += 1
            if local == "annotation",
               let encoding = attributes.first(where: { localName($0.key) == "encoding" })?.value.lowercased(),
               encoding.contains("tex") {
                insideLatexAnnotation = true
                latexAnnotation = ""
            }
            return
        }

        switch local {
        case "body":
            insideBody = true

        case "script", "style", "svg", "image":
            skipDepth = 1

        case "img":
            if insideBody && !insideTable, let src = attributes["src"] ?? attributes["xlink:href"] {
                emitImage(src: src, altText: attributes["alt"])
            }

        case "math":
            if insideBody && !insideTable {
                flushBlock()
                mathDepth = 1
                insideLatexAnnotation = false
                latexAnnotation = ""
            }

        case "table":
            if insideBody {
                flushBlock()
                insideTable = true
                tableRows = []
                currentRowCells = []
                currentTableText = ""
                tableCaption = nil
            }

        case "caption":
            if insideTable {
                insideTableCaption = true
                currentTableText = ""
            }

        case "tr":
            if insideTable {
                currentRowCells = []
            }

        case "td", "th":
            if insideTable {
                insideTableCell = true
                currentTableText = ""
            }

        case "h1", "h2", "h3", "h4", "h5", "h6":
            if insideBody && !insideTable {
                flushBlock()
                let level = Int(String(local.last!)) ?? 1
                pendingBlockType = .heading(level: level)
                currentText = ""
            }

        case "blockquote":
            if insideBody && !insideTable {
                flushBlock()
                pendingBlockType = .quote
                currentText = ""
            }

        case "pre":
            if insideBody && !insideTable {
                flushBlock()
                // BlockType.code carries (language:, source:) but we don't have
                // either until the inner text accumulates — flushBlock() fills
                // in the source from `currentText` when this marker is present.
                pendingBlockType = .code(language: nil, source: "")
                currentText = ""
            }

        case "p", "div":
            if insideBody && !insideTable && !isInsideHeading {
                flushBlock()
                pendingBlockType = .paragraph
                currentText = ""
            }

        case "br":
            if insideBody && !insideTable {
                currentText += " "
            } else if insideTable {
                currentTableText += " "
            }

        case "li":
            if insideBody && !insideTable {
                flushBlock()
                pendingBlockType = .list
                currentText = ""
            }

        default:
            break
        }

        // Record id anchors after any flushBlock above so `fileWordCount` is
        // current. Words still buffered in `currentText` are added on so the
        // offset points at (roughly) the id's position, not the block start.
        if insideBody, let id = attributes["id"], idOffsets[id] == nil {
            idOffsets[id] = fileWordCount + TableOfContents.wordCount(in: currentText)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideBody && skipDepth == 0 else { return }
        if mathDepth > 0 {
            if insideLatexAnnotation {
                latexAnnotation += string
            }
            return
        }
        if insideTable {
            currentTableText += string
            return
        }
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let name = elementName.lowercased()
        let local = name.contains(":") ? String(name.split(separator: ":").last ?? "") : name

        if !elementStack.isEmpty { elementStack.removeLast() }

        if skipDepth > 0 {
            skipDepth -= 1
            return
        }

        if mathDepth > 0 {
            if local == "annotation" {
                insideLatexAnnotation = false
            }
            if local == "math" {
                mathDepth -= 1
                if mathDepth == 0 {
                    emitFormula(latex: latexAnnotation)
                    latexAnnotation = ""
                }
            } else {
                mathDepth -= 1
            }
            return
        }

        if insideTable {
            switch local {
            case "caption":
                tableCaption = normalized(currentTableText)
                currentTableText = ""
                insideTableCaption = false

            case "td", "th":
                currentRowCells.append(normalized(currentTableText))
                currentTableText = ""
                insideTableCell = false

            case "tr":
                if !currentRowCells.isEmpty {
                    tableRows.append(currentRowCells)
                }
                currentRowCells = []

            case "table":
                flushTable()
                insideTable = false

            default:
                break
            }
            return
        }

        switch local {
        case "body":
            flushBlock()
            insideBody = false

        case "h1", "h2", "h3", "h4", "h5", "h6",
             "p", "div", "blockquote", "pre", "li":
            if insideBody {
                flushBlock()
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    private var isInsideHeading: Bool {
        elementStack.contains(where: { $0.hasPrefix("h") && $0.count == 2 && $0.last?.isNumber == true })
    }

    private func flushBlock() {
        let text = currentText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            currentText = ""
            return
        }
        // Code blocks: the marker case carries no source yet — wrap `currentText`
        // into the associated value and replace the visible text with the
        // placeholder so the engine sees one beat per `<pre>` instead of every
        // line of code as RSVP words.
        if case .code(let language, _) = pendingBlockType {
            let placeholder = RSVPEngine.placeholderCode
            blocks.append(TextBlock(
                text: placeholder,
                type: .code(language: language, source: currentText),
                range: placeholder.startIndex..<placeholder.endIndex
            ))
            fileWordCount += 1
        } else {
            blocks.append(TextBlock(text: text, type: pendingBlockType,
                                    range: text.startIndex..<text.endIndex))
            fileWordCount += TableOfContents.wordCount(in: text)
        }
        currentText = ""
        pendingBlockType = .paragraph
    }

    private func emitImage(src: String, altText: String?) {
        let cleanSrc = src.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? src
        let pathOnly = cleanSrc.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? cleanSrc
        guard !pathOnly.isEmpty else { return }

        let decodedPath = pathOnly.removingPercentEncoding ?? pathOnly
        let imageURL = URL(fileURLWithPath: decodedPath, relativeTo: baseDir).standardizedFileURL
        guard let data = try? Data(contentsOf: imageURL) else { return }

        flushBlock()

        let mime = Self.mimeForExtension(imageURL.pathExtension.lowercased())
        let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
        let placeholder = RSVPEngine.placeholderImage
        blocks.append(TextBlock(
            text: placeholder,
            type: .image(src: dataURL, altText: altText),
            range: placeholder.startIndex..<placeholder.endIndex
        ))
        fileWordCount += 1
        currentText = ""
        pendingBlockType = .paragraph
    }

    private func emitFormula(latex: String) {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        flushBlock()

        let placeholder = RSVPEngine.placeholderFormula
        blocks.append(TextBlock(
            text: placeholder,
            type: .formula(latex: trimmed, caption: nil),
            range: placeholder.startIndex..<placeholder.endIndex
        ))
        fileWordCount += 1
        currentText = ""
        pendingBlockType = .paragraph
    }

    private func flushTable() {
        let rows = tableRows.filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard !rows.isEmpty else {
            resetTableState()
            return
        }

        let columnCount = rows.map(\.count).max() ?? 0
        let html = Self.tableHTML(rows: rows)
        let placeholder = RSVPEngine.placeholderTable
        blocks.append(TextBlock(
            text: placeholder,
            type: .table(html: html, columnCount: columnCount, caption: tableCaption),
            range: placeholder.startIndex..<placeholder.endIndex
        ))
        fileWordCount += 1
        resetTableState()
        currentText = ""
        pendingBlockType = .paragraph
    }

    private func resetTableState() {
        tableRows = []
        currentRowCells = []
        currentTableText = ""
        tableCaption = nil
        insideTableCell = false
        insideTableCaption = false
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableHTML(rows: [[String]]) -> String {
        var out = "<table>"
        if let first = rows.first {
            out += "<thead><tr>"
            for cell in first {
                out += "<th>\(escapeHTML(cell))</th>"
            }
            out += "</tr></thead>"
        }
        out += "<tbody>"
        for row in rows.dropFirst() {
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

    private static func mimeForExtension(_ ext: String) -> String {
        switch ext {
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "bmp":          return "image/bmp"
        case "tiff", "tif":  return "image/tiff"
        case "svg":          return "image/svg+xml"
        case "webp":         return "image/webp"
        default:             return "application/octet-stream"
        }
    }

    private func localName(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.contains(":") ? String(lower.split(separator: ":").last ?? "") : lower
    }
}

// MARK: - NCX parser (EPUB 2)

/// Parses an EPUB 2 `toc.ncx` `<navMap>` into a flat, reading-order list of
/// `(title, level, href)` entries. Nesting depth of `<navPoint>` sets `level`.
private final class NCXParser: NSObject, XMLParserDelegate {
    private(set) var entries: [RawTOCEntry] = []

    private final class Node {
        var title = ""
        var src = ""
        var children: [Node] = []
    }

    private var roots: [Node] = []
    private var stack: [Node] = []
    private var insideNavMap = false
    private var insideText = false

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()

        var flat: [RawTOCEntry] = []
        flatten(roots, level: 1, into: &flat)
        entries = flat
    }

    private func flatten(_ nodes: [Node], level: Int, into out: inout [RawTOCEntry]) {
        for node in nodes {
            out.append(RawTOCEntry(
                title: node.title.trimmingCharacters(in: .whitespacesAndNewlines),
                level: level,
                href: node.src
            ))
            flatten(node.children, level: level + 1, into: &out)
        }
    }

    private func localName(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.contains(":") ? String(lower.split(separator: ":").last ?? "") : lower
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "navmap":
            insideNavMap = true

        case "navpoint":
            guard insideNavMap else { return }
            let node = Node()
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)

        case "text":
            if insideNavMap, !stack.isEmpty { insideText = true }

        case "content":
            if insideNavMap, let node = stack.last, node.src.isEmpty,
               let src = attributes["src"] {
                node.src = src
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText, let node = stack.last {
            node.title += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        switch localName(elementName) {
        case "navmap":
            insideNavMap = false

        case "navpoint":
            if !stack.isEmpty { stack.removeLast() }

        case "text":
            insideText = false

        default:
            break
        }
    }
}

// MARK: - nav.xhtml parser (EPUB 3)

/// Parses an EPUB 3 navigation document — `<nav epub:type="toc">` containing
/// nested `<ol>/<li>/<a>` — into a flat, reading-order list. `<ol>` nesting
/// depth sets `level`.
private final class NavXHTMLParser: NSObject, XMLParserDelegate {
    private(set) var entries: [RawTOCEntry] = []

    private var insideTocNav = false
    private var olDepth = 0
    private var insideAnchor = false
    private var currentHref = ""
    private var currentTitle = ""

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    private func localName(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.contains(":") ? String(lower.split(separator: ":").last ?? "") : lower
    }

    /// True when any of the toc-marking attributes (`epub:type`, `type`, `role`)
    /// identifies this `<nav>` as the table of contents.
    private func isTocNav(_ attributes: [String: String]) -> Bool {
        for key in ["epub:type", "type", "role"] {
            if let value = attributes[key]?.lowercased(),
               value.split(whereSeparator: { $0 == " " }).contains(where: { $0.contains("toc") }) {
                return true
            }
        }
        return false
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "nav":
            if isTocNav(attributes) { insideTocNav = true }

        case "ol":
            if insideTocNav { olDepth += 1 }

        case "a":
            if insideTocNav, olDepth > 0 {
                insideAnchor = true
                currentHref = attributes["href"] ?? ""
                currentTitle = ""
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideAnchor { currentTitle += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        switch localName(elementName) {
        case "a":
            if insideAnchor {
                let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, !currentHref.isEmpty {
                    entries.append(RawTOCEntry(title: title, level: max(1, olDepth), href: currentHref))
                }
                insideAnchor = false
                currentHref = ""
                currentTitle = ""
            }

        case "ol":
            if insideTocNav, olDepth > 0 { olDepth -= 1 }

        case "nav":
            if insideTocNav {
                insideTocNav = false
                olDepth = 0
            }

        default:
            break
        }
    }
}
