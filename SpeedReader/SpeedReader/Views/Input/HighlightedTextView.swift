import SwiftUI

/// View that displays text with the current word highlighted and auto-scrolls.
/// Supports rich block formatting (headings, quotes, code, lists) when blocks are provided.
@available(macOS 13.0, *)
struct HighlightedTextView: View {
    let text: String
    @ObservedObject var engine: RSVPEngine
    var blocks: [TextBlock]?

    @State private var paragraphs: [ParagraphInfo] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs) { para in
                        if para.words.isEmpty {
                            Color.clear.frame(height: 10)
                        } else {
                            blockView(for: para)
                                // Per-paragraph scroll anchor: LazyVStack can find and
                                // materialize this id even when the row is off-screen.
                                .id(ScrollAnchor.paragraph(para.firstWordIndex ?? -1))
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: engine.currentIndex) { _, newIndex in
                guard let target = paragraphs.scrollTargetID(for: newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(ScrollAnchor.paragraph(target), anchor: .center)
                }
            }
        }
        .onAppear { parseText() }
        .onChange(of: text) { _, _ in parseText() }
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func blockView(for para: ParagraphInfo) -> some View {
        switch para.blockType {
        case .image(let src, let altText):
            ImageBlockView(
                src: src,
                altText: altText,
                wordIndex: para.words.first?.index,
                isHighlighted: para.words.first?.index == engine.currentIndex
            )
            .id(para.words.first?.index ?? -1)

        case .heading(let level):
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(para.words) { wordInfo in
                    HeadingWordView(
                        word: wordInfo.word,
                        isHighlighted: wordInfo.index == engine.currentIndex,
                        level: level
                    )
                    .id(wordInfo.index)
                }
            }
            .padding(.top, level <= 2 ? 16 : 10)
            .padding(.bottom, 4)

        case .quote:
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 3)

                FlowLayout(spacing: 4, lineSpacing: 6) {
                    ForEach(para.words) { wordInfo in
                        QuoteWordView(
                            word: wordInfo.word,
                            isHighlighted: wordInfo.index == engine.currentIndex
                        )
                        .id(wordInfo.index)
                    }
                }
                .padding(.leading, 12)
            }
            .padding(.vertical, 4)

        case .code(let language, let source):
            // RSVP no longer reads code word-by-word — the block contributes a
            // single placeholder beat the engine can auto-pause on (Phase 5).
            // Render the source as a monospace pre with optional language tag.
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(source)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
            .padding(.vertical, 4)

        case .list:
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(para.words) { wordInfo in
                    WordView(
                        word: wordInfo.word,
                        isHighlighted: wordInfo.index == engine.currentIndex
                    )
                    .id(wordInfo.index)
                }
            }
            .padding(.leading, 8)

        case .caption:
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(para.words) { wordInfo in
                    CaptionWordView(
                        word: wordInfo.word,
                        isHighlighted: wordInfo.index == engine.currentIndex
                    )
                    .id(wordInfo.index)
                }
            }
            .padding(.vertical, 2)

        default:
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(para.words) { wordInfo in
                    WordView(
                        word: wordInfo.word,
                        isHighlighted: wordInfo.index == engine.currentIndex
                    )
                    .id(wordInfo.index)
                }
            }
        }
    }

    // MARK: - Parsing

    private func parseText() {
        // Tokenizing the whole article off the main thread keeps a large URL
        // article from freezing the UI on load. Result is published on the main
        // actor, guarded against a stale `text`.
        let snapshotBlocks = blocks
        let snapshotText = text
        Task.detached(priority: .userInitiated) {
            let parsed = TextBlockParser.parse(blocks: snapshotBlocks, plainText: snapshotText)
            await MainActor.run {
                guard snapshotText == self.text else { return }
                self.paragraphs = parsed.paragraphs
            }
        }
    }
}

// MARK: - Models

/// Distinct id namespace for `ScrollViewReader` paragraph anchors so they never
/// collide with the per-word `.id(wordInfo.index)` used for highlighting inside
/// each `FlowLayout`.
enum ScrollAnchor: Hashable {
    case paragraph(Int)
}

struct ParagraphInfo: Identifiable {
    let id = UUID()
    let words: [WordInfo]
    var blockType: BlockType = .paragraph

    /// Word index of the first word in this paragraph, or `nil` for spacer rows.
    var firstWordIndex: Int? { words.first?.index }

    /// Word index of the last word in this paragraph, or `nil` for spacer rows.
    var lastWordIndex: Int? { words.last?.index }

    /// True if `wordIndex` falls within this paragraph's word range.
    func contains(wordIndex: Int) -> Bool {
        guard let first = firstWordIndex, let last = lastWordIndex else { return false }
        return wordIndex >= first && wordIndex <= last
    }
}

extension Array where Element == ParagraphInfo {
    /// The `firstWordIndex` of the paragraph that contains `wordIndex`, used as a
    /// stable `ScrollViewReader` target. `LazyVStack` only registers ids of rows
    /// it has materialized, so we scroll to the paragraph (a direct child of the
    /// stack) rather than to an individual word inside an off-screen `FlowLayout`.
    func scrollTargetID(for wordIndex: Int) -> Int? {
        first { $0.contains(wordIndex: wordIndex) }?.firstWordIndex
    }
}

struct WordInfo: Identifiable {
    let index: Int
    let word: String
    var id: Int { index }
}

// MARK: - Text Block Parser

/// Shared word-tokenizer for the block previews. Walks the same word pattern as
/// `RSVPEngine` so word indices line up with the engine's tokenization, and is
/// pure / `Sendable` so it can run off the main thread.
enum TextBlockParser {
    struct Result {
        let paragraphs: [ParagraphInfo]
        let totalWords: Int
    }

    static func parse(blocks: [TextBlock]?, plainText: String) -> Result {
        if let blocks, !blocks.isEmpty {
            return parseBlocks(blocks)
        }
        return parsePlainText(plainText)
    }

    private static func parseBlocks(_ blocks: [TextBlock]) -> Result {
        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern) else {
            return parsePlainText(blocks.map(\.text).joined(separator: "\n\n"))
        }

        var result: [ParagraphInfo] = []
        var wordOffset = 0

        for block in blocks {
            let blockLines = block.text.components(separatedBy: "\n")

            for line in blockLines {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(ParagraphInfo(words: [], blockType: block.type))
                    continue
                }

                var words: [WordInfo] = []
                let nsRange = NSRange(line.startIndex..., in: line)
                let matches = regex.matches(in: line, range: nsRange)

                for match in matches {
                    guard let range = Range(match.range, in: line) else { continue }
                    let word = String(line[range])
                    guard !word.isEmpty else { continue }
                    words.append(WordInfo(index: wordOffset, word: word))
                    wordOffset += 1
                }

                if !words.isEmpty {
                    result.append(ParagraphInfo(words: words, blockType: block.type))
                }
            }

            result.append(ParagraphInfo(words: [], blockType: .paragraph))
        }

        if let last = result.last, last.words.isEmpty {
            result.removeLast()
        }

        return Result(paragraphs: result, totalWords: wordOffset)
    }

    private static func parsePlainText(_ text: String) -> Result {
        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern) else {
            return Result(paragraphs: [], totalWords: 0)
        }

        let lines = text.components(separatedBy: "\n")
        var globalIndex = 0
        var result: [ParagraphInfo] = []

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(ParagraphInfo(words: []))
                continue
            }

            var words: [WordInfo] = []
            let nsRange = NSRange(line.startIndex..., in: line)
            let matches = regex.matches(in: line, range: nsRange)

            for match in matches {
                guard let range = Range(match.range, in: line) else { continue }
                let word = String(line[range])
                guard !word.isEmpty else { continue }
                words.append(WordInfo(index: globalIndex, word: word))
                globalIndex += 1
            }

            if !words.isEmpty {
                result.append(ParagraphInfo(words: words))
            }
        }

        return Result(paragraphs: result, totalWords: globalIndex)
    }
}

// MARK: - Word Views

struct WordView: View {
    let word: String
    let isHighlighted: Bool
    @ObservedObject private var settings = ReaderSettings.shared

    var body: some View {
        Text(word)
            .font(.system(size: 14))
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHighlighted && settings.highlightEnabled ? HighlightStyle.color(for: .readingActive) : Color.clear)
                    .padding(.horizontal, -HighlightStyle.paddingH)
                    .padding(.vertical, -HighlightStyle.paddingV)
            )
            .foregroundColor(.primary)
            .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }
}

struct HeadingWordView: View {
    let word: String
    let isHighlighted: Bool
    let level: Int
    @ObservedObject private var settings = ReaderSettings.shared

    private var fontSize: CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 16
        default: return 15
        }
    }

    var body: some View {
        Text(word)
            .font(.system(size: fontSize, weight: .bold))
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHighlighted && settings.highlightEnabled ? HighlightStyle.color(for: .readingActive) : Color.clear)
                    .padding(.horizontal, -HighlightStyle.paddingH)
                    .padding(.vertical, -HighlightStyle.paddingV)
            )
            .foregroundColor(.primary)
            .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }
}

struct QuoteWordView: View {
    let word: String
    let isHighlighted: Bool
    @ObservedObject private var settings = ReaderSettings.shared

    var body: some View {
        Text(word)
            .font(.system(size: 14))
            .italic()
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHighlighted && settings.highlightEnabled ? HighlightStyle.color(for: .readingActive) : Color.clear)
                    .padding(.horizontal, -HighlightStyle.paddingH)
                    .padding(.vertical, -HighlightStyle.paddingV)
            )
            .foregroundColor(.secondary)
            .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }
}

struct CodeWordView: View {
    let word: String
    let isHighlighted: Bool
    @ObservedObject private var settings = ReaderSettings.shared

    var body: some View {
        Text(word)
            .font(.system(size: 13, design: .monospaced))
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHighlighted && settings.highlightEnabled ? HighlightStyle.color(for: .readingActive) : Color.clear)
                    .padding(.horizontal, -HighlightStyle.paddingH)
                    .padding(.vertical, -HighlightStyle.paddingV)
            )
            .foregroundColor(.primary.opacity(0.85))
            .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }
}

struct ImageBlockView: View {
    let src: String
    let altText: String?
    let wordIndex: Int?
    let isHighlighted: Bool
    @ObservedObject private var settings = ReaderSettings.shared

    private var url: URL? { URL(string: src) }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        fallback
                    case .empty:
                        ZStack {
                            Color.secondary.opacity(0.08)
                            ProgressView()
                                .controlSize(.small)
                        }
                        .frame(height: 120)
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(maxWidth: 600)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isHighlighted && settings.highlightEnabled ? settings.highlightColor : Color.clear,
                    lineWidth: 2
                )
        )
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }

    @ViewBuilder
    private var fallback: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            Text(altText?.isEmpty == false ? altText! : "Image unavailable")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
    }
}

struct CaptionWordView: View {
    let word: String
    let isHighlighted: Bool
    @ObservedObject private var settings = ReaderSettings.shared

    var body: some View {
        Text(word)
            .font(.system(size: 12))
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHighlighted && settings.highlightEnabled ? HighlightStyle.color(for: .readingActive) : Color.clear)
                    .padding(.horizontal, -HighlightStyle.paddingH)
                    .padding(.vertical, -HighlightStyle.paddingV)
            )
            .foregroundColor(.secondary)
            .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }
}

// MARK: - Flow Layout

@available(macOS 13.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)

            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }

        return LayoutResult(
            size: CGSize(width: maxWidth, height: y + lineHeight),
            positions: positions,
            sizes: sizes
        )
    }

    struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
        var sizes: [CGSize]
    }
}

// MARK: - Article Blocks View (static, non-reading display)

struct ArticleBlocksView: View {
    let blocks: [TextBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(for block: TextBlock) -> some View {
        switch block.type {
        case .image(let src, let altText):
            ImageBlockView(
                src: src,
                altText: altText,
                wordIndex: nil,
                isHighlighted: false
            )

        case .heading(let level):
            Text(block.text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundColor(.primary)
                .padding(.top, level <= 2 ? 18 : 12)
                .padding(.bottom, 6)

        case .quote:
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 3)

                Text(block.text)
                    .font(.system(size: 15))
                    .italic()
                    .foregroundColor(.secondary)
                    .padding(.leading, 12)
            }
            .padding(.vertical, 6)

        case .code(_, let source):
            Text(source)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.primary.opacity(0.85))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
                .padding(.vertical, 6)

        case .list:
            Text(block.text)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .padding(.leading, 8)
                .padding(.vertical, 2)

        case .caption:
            Text(block.text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.vertical, 4)

        case .table(_, let columnCount, let caption):
            // Static preview placeholder. The actual structured table renders
            // inside `TablePreviewView` when the engine auto-pauses on this
            // beat during reading — rendering full HTML tables inline in a
            // scrollable preview risks layout thrash and slow scroll, and the
            // "see real data" path is already available via the lightbox.
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(columnCount > 0 ? "Table · \(columnCount) columns" : "Table")
                        .font(.system(size: 13, weight: .medium))
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
            )
            .padding(.vertical, 6)

        default:
            Text(block.text)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 17
        default: return 16
        }
    }
}
