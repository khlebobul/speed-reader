import SwiftUI

struct PreviousContextLine: View {
    @ObservedObject var engine: RSVPEngine
    var dark = false
    var limit = 5

    var body: some View {
        Text(engine.previousWords(limit: limit).joined(separator: " "))
            .font(.system(size: 13))
            .foregroundColor(dark ? .white.opacity(0.45) : .secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity)
            .opacity(engine.currentIndex > 0 ? 1 : 0)
    }
}

struct ORPWordView: View {
    let word: String
    var baseSize: CGFloat = 48
    var fontFamily: FontFamilyPreset = .sans
    var highlightColor: Color = .red
    var maxWidth: CGFloat = 500
    var showIndicators: Bool = true
    var indicatorColor: Color = .red

    private var fontSize: CGFloat {
        guard !word.isEmpty else { return baseSize }
        let font = fontFamily.nsFont(size: baseSize)
        let textWidth = (word as NSString).size(withAttributes: [.font: font]).width
        if textWidth > maxWidth {
            return max(20, baseSize * (maxWidth / textWidth))
        }
        return baseSize
    }

    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let centerY = geometry.size.height / 2

            ZStack {
                // Indicators (fixed at center)
                if showIndicators {
                    VStack(spacing: 0) {
                        // Top indicator
                        Rectangle()
                            .fill(indicatorColor)
                            .frame(width: 2, height: 16)

                        Spacer()
                            .frame(height: min(baseSize * 1.8, max(0, geometry.size.height - 32)))

                        // Bottom indicator
                        Rectangle()
                            .fill(indicatorColor)
                            .frame(width: 2, height: 16)
                    }
                    .position(x: centerX, y: centerY)
                }

                // Word display
                if word.isEmpty {
                    Text("Ready")
                        .font(.system(size: baseSize * 0.7, weight: .light))
                        .foregroundColor(.secondary)
                        .position(x: centerX, y: centerY)
                } else {
                    WordAlignedToPivot(
                        word: word,
                        fontSize: fontSize,
                        fontFamily: fontFamily,
                        highlightColor: highlightColor,
                        centerX: centerX,
                        centerY: centerY
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

// MARK: - Word Aligned to Pivot

private struct WordAlignedToPivot: View {
    let word: String
    let fontSize: CGFloat
    let fontFamily: FontFamilyPreset
    let highlightColor: Color
    let centerX: CGFloat
    let centerY: CGFloat

    @State private var beforeWidth: CGFloat = 0
    @State private var pivotWidth: CGFloat = 0
    @State private var totalWidth: CGFloat = 0

    private var pivot: Int {
        calculatePivot(for: word)
    }

    // X position: center minus (beforeWidth + half of pivotWidth)
    // This places the pivot character exactly at centerX
    private var wordX: CGFloat {
        centerX - beforeWidth - (pivotWidth / 2) + (totalWidth / 2)
    }

    var body: some View {
        let chars = Array(word)
        let beforeChars = String(chars.prefix(pivot))
        let pivotChar = pivot < chars.count ? String(chars[pivot]) : ""
        let afterChars = String(chars.dropFirst(pivot + 1))

        HStack(spacing: 0) {
            // Before pivot
            Text(beforeChars)
                .font(fontFamily.font(size: fontSize, weight: .regular))
                .foregroundColor(.primary)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: BeforeWidthKey.self, value: geo.size.width)
                    }
                )

            // Pivot character (highlighted)
            Text(pivotChar)
                .font(fontFamily.font(size: fontSize, weight: .bold))
                .foregroundColor(highlightColor)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: PivotWidthKey.self, value: geo.size.width)
                    }
                )

            // After pivot
            Text(afterChars)
                .font(fontFamily.font(size: fontSize, weight: .regular))
                .foregroundColor(.primary)
        }
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TotalWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(BeforeWidthKey.self) { beforeWidth = $0 }
        .onPreferenceChange(PivotWidthKey.self) { pivotWidth = $0 }
        .onPreferenceChange(TotalWidthKey.self) { totalWidth = $0 }
        .position(x: wordX, y: centerY)
    }

    private func calculatePivot(for word: String) -> Int {
        let chars = Array(word)
        guard !chars.isEmpty else { return 0 }

        // Find the core letter/digit range (skip leading and trailing punctuation)
        let firstLetterIndex = chars.firstIndex(where: { $0.isLetter || $0.isNumber }) ?? 0
        let lastLetterIndex = chars.lastIndex(where: { $0.isLetter || $0.isNumber }) ?? (chars.count - 1)

        let coreLength = lastLetterIndex - firstLetterIndex + 1
        guard coreLength > 0 else { return 0 }

        // Calculate pivot based on core (letters only) length
        let corePivot: Int
        switch coreLength {
        case 1: corePivot = 0
        case 2...5: corePivot = 1
        case 6...8: corePivot = 2
        case 9...12: corePivot = 3
        case 13...17: corePivot = 4
        case 18: corePivot = 5
        case 19...25: corePivot = coreLength / 2
        default: corePivot = Int(Double(coreLength) * 0.6)
        }

        // Offset by leading punctuation to get actual index in full word
        let pivot = firstLetterIndex + corePivot

        // Safety: ensure pivot lands on a letter/digit, not punctuation
        if pivot < chars.count, !chars[pivot].isLetter && !chars[pivot].isNumber {
            // Search nearby for the closest letter
            for offset in 1..<chars.count {
                if pivot - offset >= 0 && (chars[pivot - offset].isLetter || chars[pivot - offset].isNumber) {
                    return pivot - offset
                }
                if pivot + offset < chars.count && (chars[pivot + offset].isLetter || chars[pivot + offset].isNumber) {
                    return pivot + offset
                }
            }
        }

        return min(pivot, chars.count - 1)
    }
}

// MARK: - Preference Keys

private struct BeforeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PivotWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TotalWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Convenience initializers

extension ORPWordView {
    init(word: String, settings: ReaderSettings, maxWidth: CGFloat = 500) {
        self.word = word
        self.baseSize = settings.fontSizePreset.pointSize
        self.fontFamily = settings.fontFamilyPreset
        self.highlightColor = settings.orpColor
        self.indicatorColor = settings.orpColor
        self.maxWidth = maxWidth
        self.showIndicators = settings.showORPIndicators
    }

    init(word: String, notchSettings: ReaderSettings, showIndicators: Bool = true) {
        self.word = word
        self.baseSize = notchSettings.fontSizePreset.notchPointSize
        self.fontFamily = notchSettings.fontFamilyPreset
        self.highlightColor = notchSettings.orpColor
        self.indicatorColor = notchSettings.orpColor
        self.maxWidth = 340
        self.showIndicators = showIndicators
    }
}

#Preview {
    VStack(spacing: 40) {
        ORPWordView(word: "Reading")
            .frame(width: 500, height: 120)
            .border(Color.gray.opacity(0.3))

        ORPWordView(word: "Speed", highlightColor: .blue, indicatorColor: .blue)
            .frame(width: 500, height: 120)
            .border(Color.gray.opacity(0.3))

        ORPWordView(word: "Comprehensive", highlightColor: .orange, indicatorColor: .orange)
            .frame(width: 500, height: 120)
            .border(Color.gray.opacity(0.3))
    }
    .padding()
}
