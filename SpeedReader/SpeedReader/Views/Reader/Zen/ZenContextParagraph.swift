import SwiftUI

struct ZenContextParagraph: View {
    let words: [String]
    let startIndex: Int
    var maxWords: Int = 60

    var body: some View {
        let upcoming = upcomingText
        Text(upcoming)
            .font(.system(size: 16))
            .lineSpacing(8)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 800)
            .frame(maxHeight: 87, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.55),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .opacity(upcoming.isEmpty ? 0 : 1)
    }

    private var upcomingText: String {
        guard startIndex < words.count else { return "" }
        let end = min(startIndex + maxWords, words.count)
        return words[startIndex..<end].joined(separator: " ")
    }
}

#Preview {
    ZenContextParagraph(
        words: Array(repeating: "lorem ipsum dolor sit amet consectetur adipiscing elit", count: 8)
            .joined(separator: " ")
            .split(separator: " ")
            .map(String.init),
        startIndex: 0
    )
    .padding()
    .frame(width: 800, height: 100)
}
