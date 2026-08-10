import Foundation

/// A single entry in a document's table of contents.
/// `wordIndex` is the RSVP word index to jump to; `blockIndex` is the index in
/// `DocumentContent.blocks` (used for active-section highlighting).
struct TOCEntry: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let level: Int            // 1 = top-level, 2 = subsection, ...
    let wordIndex: Int        // RSVP word index — the jump target
    let blockIndex: Int?      // index into DocumentContent.blocks (nil if unknown)
    let children: [TOCEntry]  // nested sections (EPUB NCX / nested <ol>)

    init(title: String, level: Int, wordIndex: Int, blockIndex: Int? = nil, children: [TOCEntry] = []) {
        self.title = title
        self.level = level
        self.wordIndex = wordIndex
        self.blockIndex = blockIndex
        self.children = children
    }

    static func == (lhs: TOCEntry, rhs: TOCEntry) -> Bool {
        lhs.title == rhs.title
            && lhs.level == rhs.level
            && lhs.wordIndex == rhs.wordIndex
            && lhs.blockIndex == rhs.blockIndex
            && lhs.children == rhs.children
    }
}

/// A document's table of contents — a tree of `TOCEntry` values.
struct TableOfContents: Equatable {
    let entries: [TOCEntry]   // top-level entries

    var isEmpty: Bool { entries.isEmpty }

    init(entries: [TOCEntry]) {
        self.entries = entries
    }

    /// Depth-first flattening of the tree, preserving reading order.
    var flattened: [TOCEntry] {
        var result: [TOCEntry] = []
        func visit(_ entry: TOCEntry) {
            result.append(entry)
            entry.children.forEach(visit)
        }
        entries.forEach(visit)
        return result
    }
}
