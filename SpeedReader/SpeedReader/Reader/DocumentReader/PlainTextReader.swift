import Foundation

/// Reader for plain text files (.txt)
final class PlainTextReader: DocumentReader {
    static let supportedExtensions = ["txt"]

    func read(from url: URL) async throws -> DocumentContent {
        let text: String

        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try other encodings
            if let content = try? String(contentsOf: url, encoding: .ascii) {
                text = content
            } else if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
                text = content
            } else {
                throw DocumentError.readingFailed(error.localizedDescription)
            }
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentError.emptyDocument
        }

        let blocks = parseBlocks(from: text)
        let plainText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return DocumentContent(
            title: extractTitle(from: url),
            blocks: blocks,
            plainText: plainText,
            metadata: nil
        )
    }

    /// Extract title from filename
    private func extractTitle(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Parse text into blocks (paragraphs separated by empty lines)
    private func parseBlocks(from text: String) -> [TextBlock] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var blocks: [TextBlock] = []
        var currentIndex = text.startIndex

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Find the range in original text
            if let range = text.range(of: paragraph, range: currentIndex..<text.endIndex) {
                blocks.append(TextBlock(
                    text: trimmed,
                    type: .paragraph,
                    range: range
                ))
                currentIndex = range.upperBound
            } else {
                // Fallback: create a dummy range
                blocks.append(TextBlock(
                    text: trimmed,
                    type: .paragraph,
                    range: text.startIndex..<text.startIndex
                ))
            }
        }

        return blocks
    }
}
