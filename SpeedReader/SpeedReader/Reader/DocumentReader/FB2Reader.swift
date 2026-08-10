import Foundation

/// Reader for FB2 (FictionBook 2) — de-facto standard for Russian-language e-books.
/// Parses XML via Foundation's XMLParser, no external dependencies.
final class FB2Reader: DocumentReader {
    static let supportedExtensions = ["fb2"]

    func read(from url: URL) async throws -> DocumentContent {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentError.readingFailed(error.localizedDescription)
        }

        guard !data.isEmpty else {
            throw DocumentError.emptyDocument
        }

        let parser = FB2XMLParser()
        try parser.parse(data: data)

        guard !parser.blocks.isEmpty else {
            throw DocumentError.emptyDocument
        }

        // Prepend book title as the first block so it appears in both
        // plainText (for RSVPEngine) and blocks (for BookPreviewView)
        var blocks = parser.blocks
        if let title = parser.title, !title.isEmpty {
            let titleBlock = TextBlock(
                text: title,
                type: .heading(level: 1),
                range: title.startIndex..<title.endIndex
            )
            blocks.insert(titleBlock, at: 0)
        }

        let plainText = blocks
            .map { $0.text }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // FB2 emits `<section>` titles as `.heading` blocks with level = nesting depth,
        // so the generic block-walking builder produces a correct tree without a
        // format-specific NCX/nav-style index. Stay nil when the book has no
        // section structure so the TOC button hides instead of showing just the title.
        let toc = TableOfContents.fromBlocks(blocks)
        let resolvedTOC: TableOfContents? = (toc.entries.count <= 1) ? nil : toc

        return DocumentContent(
            title: parser.title,
            blocks: blocks,
            plainText: plainText,
            metadata: DocumentMetadata(author: parser.author),
            toc: resolvedTOC
        )
    }
}

// MARK: - XML Parser

private final class FB2XMLParser: NSObject, XMLParserDelegate {

    var title: String?
    var author: String?
    var blocks: [TextBlock] = []

    private var currentText = ""
    private var pendingBlockType: BlockType = .paragraph

    private var elementStack: [String] = []

    // Context flags
    private var insideBody = false
    private var insideTitleInfo = false
    private var insideSectionTitle = false
    private var insideEpigraph = false
    private var insideAuthor = false
    private var insideBinary = false

    // Author name parts
    private var firstName = ""
    private var lastName = ""

    func parse(data: Data) throws {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()
        if let error = xmlParser.parserError {
            throw DocumentError.readingFailed(error.localizedDescription)
        }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        elementStack.append(name)

        switch name {
        case "body":
            insideBody = true

        case "title-info":
            insideTitleInfo = true

        case "binary":
            insideBinary = true

        case "author":
            if insideTitleInfo {
                insideAuthor = true
                firstName = ""
                lastName = ""
            }

        case "title":
            // <title> inside <body> is a section heading
            if insideBody {
                flushBlock()
                insideSectionTitle = true
                pendingBlockType = .heading(level: sectionDepth())
                currentText = ""
            }

        case "epigraph":
            if insideBody {
                insideEpigraph = true
            }

        case "p":
            if insideBody && !insideSectionTitle {
                flushBlock()
                pendingBlockType = insideEpigraph ? .quote : .paragraph
                currentText = ""
            }

        case "v":
            // Verse line inside <poem>/<stanza>
            if insideBody {
                flushBlock()
                pendingBlockType = .paragraph
                currentText = ""
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !insideBinary else { return }

        if insideBody {
            currentText += string
            return
        }

        if insideTitleInfo {
            switch elementStack.last ?? "" {
            case "book-title":
                title = (title ?? "") + string
            case "first-name":
                if insideAuthor { firstName += string }
            case "last-name":
                if insideAuthor { lastName += string }
            default:
                break
            }
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let name = elementName.lowercased()
        if !elementStack.isEmpty { elementStack.removeLast() }

        switch name {
        case "body":
            flushBlock()
            insideBody = false

        case "title-info":
            insideTitleInfo = false

        case "binary":
            insideBinary = false

        case "author":
            if insideAuthor {
                let parts = [firstName, lastName].filter { !$0.isEmpty }
                if !parts.isEmpty { author = parts.joined(separator: " ") }
                insideAuthor = false
            }

        case "title":
            if insideSectionTitle {
                flushBlock()
                insideSectionTitle = false
            }

        case "epigraph":
            flushBlock()
            insideEpigraph = false

        case "p", "v":
            if insideBody && !insideSectionTitle {
                flushBlock()
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    private func flushBlock() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            currentText = ""
            return
        }
        blocks.append(TextBlock(text: text, type: pendingBlockType,
                                range: text.startIndex..<text.endIndex))
        currentText = ""
        pendingBlockType = .paragraph
    }

    /// Returns heading level based on nesting depth of <section> elements (clamped 1–6).
    private func sectionDepth() -> Int {
        max(1, min(6, elementStack.filter { $0 == "section" }.count))
    }
}
