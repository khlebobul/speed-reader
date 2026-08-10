import SwiftUI
import AppKit

/// Renders multiple words read together (Words-at-a-Time chunked playback) with ORP applied
/// only to the first word. Trailing words are plain text on the same baseline.
///
/// For chunk size 1: pivot character of the word lands on `centerX` (classic ORP — same as
/// `ORPWordView`).
/// For chunk size ≥ 2: the visual middle of the whole row sits on `centerX`, so the ORP
/// indicator line points at the fixation center of the chunk rather than the start of the
/// first word. The ORP highlight stays on the first word as a left-to-right reading anchor.
struct ChunkedORPView: View {
    let words: [String]
    var baseSize: CGFloat = 48
    var fontFamily: FontFamilyPreset = .sans
    var highlightColor: Color = .red
    var maxWidth: CGFloat = 900
    var showIndicators: Bool = true
    var indicatorColor: Color = .red

    private var joined: String { words.joined(separator: " ") }

    private var fontSize: CGFloat {
        guard !joined.isEmpty else { return baseSize }
        let font = fontFamily.nsFont(size: baseSize)
        let textWidth = (joined as NSString).size(withAttributes: [.font: font]).width
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
                if showIndicators {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(indicatorColor)
                            .frame(width: 2, height: 16)
                        Spacer()
                            .frame(height: min(baseSize * 1.8, max(0, geometry.size.height - 32)))
                        Rectangle()
                            .fill(indicatorColor)
                            .frame(width: 2, height: 16)
                    }
                    .position(x: centerX, y: centerY)
                }

                if words.isEmpty || joined.isEmpty {
                    Text("Ready")
                        .font(.system(size: baseSize * 0.7, weight: .light))
                        .foregroundColor(.secondary)
                        .position(x: centerX, y: centerY)
                } else {
                    ChunkAlignedToPivot(
                        words: words,
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

private struct ChunkAlignedToPivot: View {
    let words: [String]
    let fontSize: CGFloat
    let fontFamily: FontFamilyPreset
    let highlightColor: Color
    let centerX: CGFloat
    let centerY: CGFloat

    private var first: String { words.first ?? "" }
    private var trailing: [String] { Array(words.dropFirst()) }

    private var pivot: Int { calculatePivot(for: first) }

    private var beforeWidth: CGFloat {
        textWidth(beforeChars, weight: .regular)
    }

    private var pivotWidth: CGFloat {
        textWidth(pivotChar, weight: .bold)
    }

    private var totalWidth: CGFloat {
        beforeWidth
            + pivotWidth
            + textWidth(afterChars, weight: .regular)
            + textWidth(trailingText, weight: .regular)
    }

    private var beforeChars: String {
        String(firstChars.prefix(pivot))
    }

    private var pivotChar: String {
        pivot < firstChars.count ? String(firstChars[pivot]) : ""
    }

    private var afterChars: String {
        String(firstChars.dropFirst(pivot + 1))
    }

    private var trailingText: String {
        trailing.isEmpty ? "" : " " + trailing.joined(separator: " ")
    }

    private var firstChars: [Character] {
        Array(first)
    }

    private var rowX: CGFloat {
        // Single word: classic ORP — pivot letter on centerX.
        // Chunk of ≥2: visual center of the whole row on centerX so the indicator line
        // marks the eye-fixation midpoint of the group, not the start of the first word.
        if words.count <= 1 {
            return centerX - beforeWidth - (pivotWidth / 2) + (totalWidth / 2)
        }
        return centerX
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(beforeChars)
                .font(fontFamily.font(size: fontSize, weight: .regular))
                .foregroundColor(.primary)

            Text(pivotChar)
                .font(fontFamily.font(size: fontSize, weight: .bold))
                .foregroundColor(highlightColor)

            Text(afterChars)
                .font(fontFamily.font(size: fontSize, weight: .regular))
                .foregroundColor(.primary)

            // Trailing words — separated by a space, plain weight.
            if !trailing.isEmpty {
                Text(trailingText)
                    .font(fontFamily.font(size: fontSize, weight: .regular))
                    .foregroundColor(.primary)
            }
        }
        .fixedSize()
        .position(x: rowX, y: centerY)
    }

    private func textWidth(_ text: String, weight: NSFont.Weight) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = fontFamily.nsFont(size: fontSize, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func calculatePivot(for word: String) -> Int {
        let chars = Array(word)
        guard !chars.isEmpty else { return 0 }
        let firstLetterIndex = chars.firstIndex(where: { $0.isLetter || $0.isNumber }) ?? 0
        let lastLetterIndex = chars.lastIndex(where: { $0.isLetter || $0.isNumber }) ?? (chars.count - 1)
        let coreLength = lastLetterIndex - firstLetterIndex + 1
        guard coreLength > 0 else { return 0 }
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
        let p = firstLetterIndex + corePivot
        if p < chars.count, !chars[p].isLetter && !chars[p].isNumber {
            for offset in 1..<chars.count {
                if p - offset >= 0 && (chars[p - offset].isLetter || chars[p - offset].isNumber) {
                    return p - offset
                }
                if p + offset < chars.count && (chars[p + offset].isLetter || chars[p + offset].isNumber) {
                    return p + offset
                }
            }
        }
        return min(p, chars.count - 1)
    }
}
