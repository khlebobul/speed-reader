import AppKit
import Foundation

/// `SearchTarget` for the editable plain-text input. Uses `NSTextView` temporary
/// attributes so search can highlight matches without mutating the user's text.
@MainActor
final class EditableTextSearchTarget: SearchTarget {
    weak var textView: NSTextView?

    private var matches: [NSRange] = []
    private var activeIdx: Int = -1

    init(textView: NSTextView) {
        self.textView = textView
    }

    func find(query: String) async -> Int {
        clearHighlights()
        guard !query.isEmpty, let textView else {
            matches = []
            activeIdx = -1
            return 0
        }

        let source = textView.string as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var found: [NSRange] = []

        while searchRange.length > 0 {
            let range = source.range(of: query, options: [.caseInsensitive], range: searchRange)
            guard range.location != NSNotFound else { break }
            found.append(range)

            let nextLocation = range.location + max(range.length, 1)
            guard nextLocation <= source.length else { break }
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }

        matches = found
        activeIdx = matches.isEmpty ? -1 : 0
        paintHighlights()
        activateCurrentMatch()
        return matches.count
    }

    func next() async -> Int {
        guard !matches.isEmpty else { return -1 }
        activeIdx = (activeIdx + 1) % matches.count
        paintHighlights()
        activateCurrentMatch()
        return activeIdx
    }

    func prev() async -> Int {
        guard !matches.isEmpty else { return -1 }
        activeIdx = (activeIdx - 1 + matches.count) % matches.count
        paintHighlights()
        activateCurrentMatch()
        return activeIdx
    }

    func clear() {
        clearHighlights()
        matches = []
        activeIdx = -1
    }

    func activeWordIndex() async -> Int {
        guard let textView,
              activeIdx >= 0,
              activeIdx < matches.count
        else { return -1 }

        return wordIndex(containing: matches[activeIdx], in: textView.string)
    }

    // MARK: - Highlighting

    private func paintHighlights() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        clearHighlights()

        let hitColor = HighlightStyle.nsColor(for: .searchMatch)
        let activeColor = HighlightStyle.nsColor(for: .searchActive)
        let activeBorderAttrs = HighlightStyle.nsBorderAttributes(for: .searchActive)

        for (index, range) in matches.enumerated() {
            let isActive = index == activeIdx
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: isActive ? activeColor : hitColor,
                forCharacterRange: range
            )
            // NSTextView can't draw a real character-range border without a custom
            // layout manager, so the active match wears a thick underline instead.
            if isActive {
                for (key, value) in activeBorderAttrs {
                    layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: range)
                }
            }
        }
    }

    private func clearHighlights() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        // Only clear our own match ranges — clearing `.backgroundColor` over the whole
        // document would also wipe the "Read from here" start-word highlight that
        // `EditableTextView` paints with the same attribute.
        let length = (textView.string as NSString).length
        for range in matches where NSMaxRange(range) <= length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
    }

    private func activateCurrentMatch() {
        guard let textView,
              activeIdx >= 0,
              activeIdx < matches.count
        else { return }

        let range = matches[activeIdx]
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
    }

    private func wordIndex(containing activeRange: NSRange, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern) else {
            let prefix = (text as NSString).substring(to: min(activeRange.location, (text as NSString).length))
            return prefix.split(whereSeparator: { $0.isWhitespace }).count
        }

        let nsRange = NSRange(location: 0, length: (text as NSString).length)
        let wordMatches = regex.matches(in: text, range: nsRange)

        for (index, wordMatch) in wordMatches.enumerated()
        where NSIntersectionRange(wordMatch.range, activeRange).length > 0 {
            return index
        }

        return wordMatches.filter { $0.range.location < activeRange.location }.count
    }
}
