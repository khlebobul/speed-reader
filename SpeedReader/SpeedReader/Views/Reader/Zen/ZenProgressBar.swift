import SwiftUI

struct ZenProgressBar: View {
    let progress: Double          // 0...100
    let totalWords: Int
    let currentIndex: Int
    let wpm: Int
    var onSeekStart: () -> Void
    var onSeek: (Double) -> Void  // ratio 0...1
    var onSeekEnd: () -> Void

    @State private var isDragging = false
    @State private var hoverRatio: Double?

    private let trackHeight: CGFloat = 3
    private let handleSize: CGFloat = 14
    private let touchHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let fillWidth = geo.size.width * CGFloat(progress / 100)
            let displayRatio = hoverRatio ?? Double(progress / 100)

            ZStack {
                // Track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: trackHeight)

                // Fill
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: trackHeight / 2)
                        .fill(Color.accentColor)
                        .frame(width: fillWidth, height: trackHeight)
                    Spacer(minLength: 0)
                }

                // Handle
                Circle()
                    .fill(Color.primary)
                    .frame(width: handleSize, height: handleSize)
                    .position(x: fillWidth, y: touchHeight / 2)

                // Tooltip
                if let _ = hoverRatio {
                    Text(tooltipText(for: displayRatio))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.85))
                        )
                        .position(
                            x: max(40, min(geo.size.width - 40, geo.size.width * CGFloat(displayRatio))),
                            y: -10
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(height: touchHeight, alignment: .center)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let r = max(0, min(1, Double(location.x / geo.size.width)))
                    hoverRatio = r
                case .ended:
                    if !isDragging { hoverRatio = nil }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onSeekStart()
                        }
                        let r = max(0, min(1, Double(value.location.x / geo.size.width)))
                        hoverRatio = r
                        onSeek(r)
                    }
                    .onEnded { _ in
                        isDragging = false
                        hoverRatio = nil
                        onSeekEnd()
                    }
            )
        }
        .frame(height: touchHeight)
    }

    private func tooltipText(for ratio: Double) -> String {
        let percent = Int((ratio * 100).rounded())
        let targetIndex = Int(ratio * Double(max(0, totalWords - 1)))
        let remaining = max(0, totalWords - targetIndex)
        let minutes = Double(remaining) / Double(max(1, wpm))
        let timeStr: String
        if minutes < 1 {
            timeStr = "< 1 min"
        } else {
            timeStr = "~\(Int(ceil(minutes))) min"
        }
        return "\(percent)% · \(timeStr)"
    }
}
