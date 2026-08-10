import Foundation

/// `SearchTarget` implementation for plain-Swift word arrays (URL articles, plain text, OCR area).
///
/// Splits the source text with `RSVPEngine.wordPattern` so the resulting word indices line up
/// 1:1 with `RSVPEngine.words` once reading starts — that's the same index `ClickableTextPreview`
/// uses for tap-to-select-start. Match navigation just walks a `[Int]` of hit word indices and
/// publishes the current selection via `onUpdate` so the wrapping view can paint highlights.
@MainActor
final class TextSearchTarget: SearchTarget {
    /// Returns the source text at the moment of search — captured lazily so a stale closure
    /// doesn't pin the view to old content if it gets recomputed before the user opens ⌘F.
    private let textProvider: () -> String
    /// Optional structured blocks (URL articles, OCR text). When present, words are extracted
    /// from `blocks.map(\.text).joined(separator: "\n\n")` to match `ClickableTextPreview`'s
    /// own parsing — keeps indices aligned with what the user sees on screen.
    private let blocksProvider: () -> [TextBlock]?
    private let onUpdate: (_ matchIndices: [Int], _ activeMatch: Int) -> Void

    private var matchIndices: [Int] = []
    private var activeIdx: Int = -1

    init(
        textProvider: @escaping () -> String,
        blocksProvider: @escaping () -> [TextBlock]? = { nil },
        onUpdate: @escaping (_ matchIndices: [Int], _ activeMatch: Int) -> Void
    ) {
        self.textProvider = textProvider
        self.blocksProvider = blocksProvider
        self.onUpdate = onUpdate
    }

    func find(query: String) async -> Int {
        guard !query.isEmpty else {
            matchIndices = []
            activeIdx = -1
            onUpdate([], -1)
            return 0
        }
        let q = query.lowercased()
        let words = Self.extractWords(text: textProvider(), blocks: blocksProvider())
        matchIndices = words.enumerated().compactMap { i, w in
            w.lowercased().contains(q) ? i : nil
        }
        activeIdx = matchIndices.isEmpty ? -1 : 0
        onUpdate(matchIndices, activeIdx)
        return matchIndices.count
    }

    func next() async -> Int {
        guard !matchIndices.isEmpty else { return -1 }
        activeIdx = (activeIdx + 1) % matchIndices.count
        onUpdate(matchIndices, activeIdx)
        return activeIdx
    }

    func prev() async -> Int {
        guard !matchIndices.isEmpty else { return -1 }
        activeIdx = (activeIdx - 1 + matchIndices.count) % matchIndices.count
        onUpdate(matchIndices, activeIdx)
        return activeIdx
    }

    func clear() {
        matchIndices = []
        activeIdx = -1
        onUpdate([], -1)
    }

    func activeWordIndex() async -> Int {
        guard activeIdx >= 0, activeIdx < matchIndices.count else { return -1 }
        return matchIndices[activeIdx]
    }

    // MARK: - Helpers

    /// Splits `text` (or `blocks` joined the same way `ClickableTextPreview` does) using
    /// `RSVPEngine.wordPattern`. The resulting indices match the `WordInfo.index` the preview
    /// view assigns, which is also what `RSVPEngine.words` will use once reading starts.
    static func extractWords(text: String, blocks: [TextBlock]?) -> [String] {
        let source: String
        if let blocks, !blocks.isEmpty {
            source = blocks.map(\.text).joined(separator: "\n\n")
        } else {
            source = text
        }
        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern) else {
            return source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        let nsRange = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: nsRange).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }
}
