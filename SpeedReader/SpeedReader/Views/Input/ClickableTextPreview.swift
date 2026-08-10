import SwiftUI

/// A read-only text preview where each word is tappable.
/// Tapping a word selects it as the starting point for reading.
@available(macOS 13.0, *)
struct ClickableTextPreview: View {
    let text: String
    @Binding var selectedWordIndex: Int?
    var blocks: [TextBlock]? = nil
    /// RSVP word indices that match the current ⌘F query — painted with a light-yellow background.
    /// Empty when search is closed or has no matches.
    var searchMatchIndices: [Int] = []
    /// Index in `searchMatchIndices` of the currently active match (painted orange).
    /// Use `-1` when there is no active match.
    var activeSearchIndex: Int = -1
    /// When false, words can still show search/start highlights but taps won't change
    /// `selectedWordIndex`. Used by read-only file previews outside "Set start position".
    var selectionEnabled: Bool = true

    @State private var paragraphs: [ParagraphInfo] = []
    @State private var totalWords: Int = 0

    /// O(1) hit set rebuilt whenever `searchMatchIndices` changes — avoids `Array.contains`
    /// scanning per word render when the user types a frequent query.
    @State private var searchMatchSet: Set<Int> = []

    private var activeWordIndex: Int? {
        guard activeSearchIndex >= 0, activeSearchIndex < searchMatchIndices.count else { return nil }
        return searchMatchIndices[activeSearchIndex]
    }

    private func hitState(for wordIndex: Int) -> WordSearchHit {
        if wordIndex == activeWordIndex { return .active }
        if searchMatchSet.contains(wordIndex) { return .hit }
        return .none
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs) { para in
                        if para.words.isEmpty {
                            Color.clear.frame(height: 10)
                        } else {
                            blockView(for: para)
                                // Per-paragraph scroll anchor so LazyVStack can locate
                                // and materialize off-screen rows for scrollTo.
                                .id(ScrollAnchor.paragraph(para.firstWordIndex ?? -1))
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: selectedWordIndex) { _, newIndex in
                guard let newIndex,
                      let target = paragraphs.scrollTargetID(for: newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(ScrollAnchor.paragraph(target), anchor: .center)
                }
            }
            .onChange(of: activeWordIndex) { _, newIndex in
                guard let newIndex,
                      let target = paragraphs.scrollTargetID(for: newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(ScrollAnchor.paragraph(target), anchor: .center)
                }
            }
        }
        .onAppear {
            parseText()
            searchMatchSet = Set(searchMatchIndices)
        }
        .onChange(of: text) { _, _ in parseText() }
        .onChange(of: searchMatchIndices) { _, new in
            searchMatchSet = Set(new)
        }
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
                isHighlighted: para.words.first?.index == selectedWordIndex
            )
            .id(para.words.first?.index ?? -1)
            .contentShape(Rectangle())
            .onTapGesture {
                guard selectionEnabled else { return }
                if let idx = para.words.first?.index {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedWordIndex = (selectedWordIndex == idx) ? nil : idx
                    }
                }
            }

        case .heading(let level):
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(para.words) { wordInfo in
                    Text(wordInfo.word)
                        .font(.system(size: headingSize(level), weight: .bold))
                        .foregroundColor(.primary)
                        .selectableWord(index: wordInfo.index, selectedIndex: $selectedWordIndex, searchHit: hitState(for: wordInfo.index), isEnabled: selectionEnabled)
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
                        Text(wordInfo.word)
                            .font(.system(size: 14))
                            .italic()
                            .foregroundColor(.secondary)
                            .selectableWord(index: wordInfo.index, selectedIndex: $selectedWordIndex, searchHit: hitState(for: wordInfo.index), isEnabled: selectionEnabled)
                            .id(wordInfo.index)
                    }
                }
                .padding(.leading, 12)
            }
            .padding(.vertical, 4)

        case .code:
            // Code is now a single placeholder beat (Phase 5) — there's only one
            // word in `para.words` ("code") and the actual source lives on the
            // associated value. Render it inline so click-to-select-start still
            // anchors on the one beat the engine sees.
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(para.words) { wordInfo in
                    Text(wordInfo.word)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .selectableWord(index: wordInfo.index, selectedIndex: $selectedWordIndex, searchHit: hitState(for: wordInfo.index), isEnabled: selectionEnabled)
                        .id(wordInfo.index)
                }
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
                    Text(wordInfo.word)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .selectableWord(index: wordInfo.index, selectedIndex: $selectedWordIndex, searchHit: hitState(for: wordInfo.index), isEnabled: selectionEnabled)
                        .id(wordInfo.index)
                }
            }
            .padding(.leading, 8)

        case .caption:
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(para.words) { wordInfo in
                    Text(wordInfo.word)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .selectableWord(index: wordInfo.index, selectedIndex: $selectedWordIndex, searchHit: hitState(for: wordInfo.index), isEnabled: selectionEnabled)
                        .id(wordInfo.index)
                }
            }
            .padding(.vertical, 2)

        default:
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(para.words) { wordInfo in
                    Text(wordInfo.word)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .selectableWord(index: wordInfo.index, selectedIndex: $selectedWordIndex, searchHit: hitState(for: wordInfo.index), isEnabled: selectionEnabled)
                        .id(wordInfo.index)
                }
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 16
        default: return 15
        }
    }

    // MARK: - Parsing (same logic as HighlightedTextView)

    private func parseText() {
        // Parsing runs a regex over the whole article and allocates one
        // `WordInfo` per word — for an 18k-char article that's thousands of
        // allocations that must not block the main thread. Hop to a background
        // task, then publish the result back on the main actor.
        let snapshotBlocks = blocks
        let snapshotText = text
        Task.detached(priority: .userInitiated) {
            let parsed = TextBlockParser.parse(blocks: snapshotBlocks, plainText: snapshotText)
            await MainActor.run {
                // Guard against a stale result if `text` changed while parsing.
                guard snapshotText == self.text else { return }
                self.totalWords = parsed.totalWords
                self.paragraphs = parsed.paragraphs
            }
        }
    }
}

// MARK: - Selectable Word Modifier

/// Search-hit state for a single word — drives the ⌘F highlight color in `SelectableWordModifier`.
enum WordSearchHit {
    case none
    /// Matches the current ⌘F query but isn't the active match.
    case hit
    /// The active match (N out of M) — orange, scrolled into view by the parent.
    case active
}

private struct SelectableWordModifier: ViewModifier {
    let wordIndex: Int
    @Binding var selectedIndex: Int?
    var searchHit: WordSearchHit = .none
    var isEnabled: Bool = true

    private var isSelected: Bool { wordIndex == selectedIndex }

    /// Search wins over selection visually — an active ⌘F match is what the user
    /// just jumped to, the start-position underline still shows underneath when
    /// both apply via the overlay border below.
    private var role: HighlightRole? {
        switch searchHit {
        case .active: return .searchActive
        case .hit: return .searchMatch
        case .none: return isSelected ? .startMarker : nil
        }
    }

    func body(content: Content) -> some View {
        let cornerRadius = HighlightStyle.cornerRadius
        let padH = HighlightStyle.paddingH
        let padV = HighlightStyle.paddingV
        return content
            .background(
                Group {
                    if let role {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(HighlightStyle.color(for: role))
                            .padding(.horizontal, -padH)
                            .padding(.vertical, -padV)
                    }
                }
            )
            .overlay {
                if let role, let border = HighlightStyle.swiftUIBorder(for: role) {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(border.color, lineWidth: border.width)
                        .padding(.horizontal, -padH)
                        .padding(.vertical, -padV)
                }
            }
            .fontWeight(role.map(HighlightStyle.isBold(for:)) == true ? .semibold : nil)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedIndex = (selectedIndex == wordIndex) ? nil : wordIndex
                }
            }
    }
}

extension View {
    func selectableWord(
        index: Int,
        selectedIndex: Binding<Int?>,
        searchHit: WordSearchHit = .none,
        isEnabled: Bool = true
    ) -> some View {
        modifier(SelectableWordModifier(
            wordIndex: index,
            selectedIndex: selectedIndex,
            searchHit: searchHit,
            isEnabled: isEnabled
        ))
    }
}
