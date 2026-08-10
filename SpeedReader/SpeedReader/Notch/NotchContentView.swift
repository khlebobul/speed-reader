import SwiftUI
import AppKit

// MARK: - Notch Control Button

struct NotchControlButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    init(icon: String, size: CGFloat = 24, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main Notch Content View

struct NotchContentView: View {
    @ObservedObject var engine: RSVPEngine
    @ObservedObject private var settings = ReaderSettings.shared
    @Binding var isExpanded: Bool
    @Binding var countdown: Int?
    let onPlayPause: () -> Void
    let onClose: () -> Void

    // Animation state
    @State private var expansion: CGFloat = 0
    @State private var contentVisible: Bool = false

    // Collapsed size is fixed; expanded size comes from settings for live resize
    private let collapsedWidth: CGFloat = 210
    private let collapsedHeight: CGFloat = 36
    private var expandedWidth: CGFloat { settings.notchExpandedWidth }
    private var expandedHeight: CGFloat { settings.notchExpandedHeight }

    // Shape constants
    private let collapsedTopInset: CGFloat = 6
    private let expandedTopInset: CGFloat = 16
    private let collapsedBottomRadius: CGFloat = 14
    private let expandedBottomRadius: CGFloat = 24

    // Dark theme colors
    private let backgroundColor = Color.black

    // Interpolated values based on expansion
    private var currentWidth: CGFloat {
        collapsedWidth + (expandedWidth - collapsedWidth) * expansion
    }

    private var currentHeight: CGFloat {
        collapsedHeight + (expandedHeight - collapsedHeight) * expansion
    }

    private var currentTopInset: CGFloat {
        collapsedTopInset + (expandedTopInset - collapsedTopInset) * expansion
    }

    private var currentBottomRadius: CGFloat {
        collapsedBottomRadius + (expandedBottomRadius - collapsedBottomRadius) * expansion
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / expandedWidth
            let scaledCollapsedWidth = collapsedWidth * scale
            let scaledCollapsedHeight = collapsedHeight * scale
            let actualWidth = scaledCollapsedWidth + (geometry.size.width - scaledCollapsedWidth) * expansion
            let actualHeight = scaledCollapsedHeight + (geometry.size.height - scaledCollapsedHeight) * expansion

            ZStack(alignment: .top) {
                // Solid dark background with Dynamic Island shape
                backgroundColor
                    .clipShape(
                        DynamicIslandShape(
                            topInset: currentTopInset * scale,
                            bottomRadius: currentBottomRadius * scale
                        )
                    )

                // Content with smooth transitions
                if contentVisible && expansion > 0.5 {
                    ExpandedNotchView(
                        engine: engine,
                        countdown: countdown,
                        onPlayPause: onPlayPause,
                        onClose: onClose
                    )
                    .padding(.top, 20 * scale)
                    .padding(.horizontal, 20 * scale)
                    .padding(.bottom, 12 * scale)
                    .opacity(contentVisible ? 1 : 0)
                    .scaleEffect(contentVisible ? 1 : 0.95, anchor: .top)
                } else if expansion < 0.5 {
                    CollapsedNotchView(engine: engine, onToggle: { toggleExpansion() })
                        .padding(.horizontal, 12 * scale)
                        .opacity(Double(1.0 - expansion * 2.0))
                }
            }
            .frame(width: actualWidth, height: actualHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: isExpanded) { _, newValue in
            if newValue {
                expandAnimation()
            } else {
                collapseAnimation()
            }
        }
        .onAppear {
            expansion = 0
            contentVisible = false
            // isExpanded may already be true if expand() was called before the view appeared
            if isExpanded {
                expandAnimation()
            }
        }
    }

    private func toggleExpansion() {
        isExpanded.toggle()
    }

    private func expandAnimation() {
        // Phase 1: Expand the shape
        withAnimation(.easeOut(duration: 0.35)) {
            expansion = 1
        }
        // Phase 2: Show content after shape expands
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.2)) {
                contentVisible = true
            }
        }
    }

    private func collapseAnimation() {
        // Phase 1: Hide content first
        withAnimation(.easeIn(duration: 0.15)) {
            contentVisible = false
        }
        // Phase 2: Collapse shape after content hides
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeIn(duration: 0.25)) {
                expansion = 0
            }
        }
    }
}

// MARK: - Dynamic Island Shape

struct DynamicIslandShape: Shape {
    var topInset: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, bottomRadius) }
        set {
            topInset = newValue.first
            bottomRadius = newValue.second
        }
    }

    init(topInset: CGFloat, bottomRadius: CGFloat) {
        self.topInset = topInset
        self.bottomRadius = bottomRadius
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let t = topInset
        let br = min(bottomRadius, h / 2) // Prevent radius from exceeding height

        var p = Path()

        // Start at top-left corner (at the top edge)
        p.move(to: CGPoint(x: 0, y: 0))

        // Top-left concave curve: curves DOWN and RIGHT
        // Control point at (t, 0) creates the "notch wrap" effect
        p.addQuadCurve(
            to: CGPoint(x: t, y: t),
            control: CGPoint(x: t, y: 0)
        )

        // Left edge going down
        p.addLine(to: CGPoint(x: t, y: h - br))

        // Bottom-left convex corner
        p.addQuadCurve(
            to: CGPoint(x: t + br, y: h),
            control: CGPoint(x: t, y: h)
        )

        // Bottom edge
        p.addLine(to: CGPoint(x: w - t - br, y: h))

        // Bottom-right convex corner
        p.addQuadCurve(
            to: CGPoint(x: w - t, y: h - br),
            control: CGPoint(x: w - t, y: h)
        )

        // Right edge going up
        p.addLine(to: CGPoint(x: w - t, y: t))

        // Top-right concave curve: curves UP and RIGHT
        p.addQuadCurve(
            to: CGPoint(x: w, y: 0),
            control: CGPoint(x: w - t, y: 0)
        )

        p.closeSubpath()
        return p
    }
}

// MARK: - Collapsed View

struct CollapsedNotchView: View {
    @ObservedObject var engine: RSVPEngine
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.isPlaying ? Color.green : Color.white.opacity(0.4))
                .frame(width: 6, height: 6)

            Text(engine.currentWord.isEmpty ? "Speed Reader" : engine.currentWord)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

// MARK: - Expanded View

struct ExpandedNotchView: View {
    @ObservedObject var engine: RSVPEngine
    let countdown: Int?
    let onPlayPause: () -> Void
    let onClose: () -> Void

    @ObservedObject private var settings = ReaderSettings.shared
    @State private var closeButtonScale: CGFloat = 1.0
    private let buttonSize: CGFloat = 24
    private var isPreview: Bool { AppDelegate.shared.isSettingsPreviewActive }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Countdown or word display
            if let count = countdown {
                CountdownView(value: count)
            } else {
                NotchReaderView(engine: engine)
            }

            Spacer()

            // Bottom bar: controls + progress
            HStack(spacing: 12) {
                if !isPreview {
                    // Back 10 words / Play–Pause / Forward 10 words trio
                    NotchControlButton(
                        icon: "gobackward.10",
                        size: buttonSize,
                        action: { engine.seekByWords(-10) }
                    )
                    .help("Back 10 words (Shift+←)")

                    NotchControlButton(
                        icon: engine.isPlaying ? "pause.fill" : "play.fill",
                        size: buttonSize,
                        action: onPlayPause
                    )

                    NotchControlButton(
                        icon: "goforward.10",
                        size: buttonSize,
                        action: { engine.seekByWords(10) }
                    )
                    .help("Forward 10 words (Shift+→)")
                }

                // Progress bar (conditional)
                if settings.showProgressBar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 4)

                            Capsule()
                                .fill(Color.white.opacity(0.5))
                                .frame(width: max(0, geo.size.width * CGFloat(engine.progress / 100)), height: 4)
                        }
                    }
                    .frame(height: 4)
                } else {
                    Spacer()
                }

                if isPreview {
                    // Preview label
                    Text("Preview")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }

                // Settings button
                NotchControlButton(
                    icon: "gearshape.fill",
                    size: buttonSize,
                    action: {
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    }
                )

                // Close button
                NotchControlButton(
                    icon: "xmark",
                    size: buttonSize,
                    action: onClose
                )
                .scaleEffect(closeButtonScale)
                .help("Stop reading (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .highlightCloseButton)) { _ in
            animateCloseButton()
        }
    }

    private func animateCloseButton() {
        withAnimation(.easeInOut(duration: 0.15)) {
            closeButtonScale = 1.35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.15)) {
                closeButtonScale = 0.9
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.15)) {
                closeButtonScale = 1.15
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeInOut(duration: 0.15)) {
                closeButtonScale = 1.0
            }
        }
    }
}

// MARK: - Reader View (Simplified - Focus on Word)

struct NotchReaderView: View {
    @ObservedObject var engine: RSVPEngine
    @State private var showConfetti: Bool = false

    @ObservedObject private var settings = ReaderSettings.shared

    var body: some View {
        ZStack {
            if engine.isFinished {
                VStack(spacing: 6) {
                    Text("Finish!")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    if let stats = engine.readingStats {
                        TimeSavedText(stats: stats, isDark: true)
                    }
                }
            } else if let block = engine.currentPauseableBlock {
                RSVPBlockPreviewView(
                    block: block,
                    style: .compact,
                    dark: true,
                    compactWordSize: settings.fontSizePreset.notchPointSize,
                    autoContinueDeadline: engine.autoContinueDeadline,
                    onContinue: engine.togglePlayPause
                )
            } else {
                NotchORPWordView(word: engine.currentWord)
            }

            if showConfetti && settings.celebrationOnFinish {
                ConfettiView()
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: engine.isFinished) { _, finished in
            if finished && settings.celebrationOnFinish {
                showConfetti = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    showConfetti = false
                }
            }
        }
    }
}

// MARK: - ORP Word View with Indicators (for Notch)

struct NotchORPWordView: View {
    let word: String
    @ObservedObject private var settings = ReaderSettings.shared

    private let maxWidth: CGFloat = 340

    private var baseSize: CGFloat {
        settings.fontSizePreset.notchPointSize
    }

    private var fontSize: CGFloat {
        guard !word.isEmpty else { return baseSize }
        let font = settings.fontFamilyPreset.nsFont(size: baseSize)
        let textWidth = (word as NSString).size(withAttributes: [.font: font]).width
        if textWidth > maxWidth {
            return max(16, baseSize * (maxWidth / textWidth))
        }
        return baseSize
    }

    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let centerY = geometry.size.height / 2

            ZStack {
                // Indicators (fixed at center)
                if settings.showORPIndicators {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(settings.orpColor)
                            .frame(width: 2, height: 12)

                        Spacer()
                            .frame(height: fontSize * 1.4)

                        Rectangle()
                            .fill(settings.orpColor)
                            .frame(width: 2, height: 12)
                    }
                    .position(x: centerX, y: centerY)
                }

                // Word display
                if word.isEmpty {
                    Text("Ready")
                        .font(.system(size: baseSize * 0.7, weight: .light))
                        .foregroundColor(.white.opacity(0.3))
                        .position(x: centerX, y: centerY)
                } else {
                    NotchWordAlignedToPivot(
                        word: word,
                        fontSize: fontSize,
                        fontFamily: settings.fontFamilyPreset,
                        highlightColor: settings.orpColor,
                        centerX: centerX,
                        centerY: centerY
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

// MARK: - Notch Word Aligned to Pivot

private struct NotchWordAlignedToPivot: View {
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

    private var wordX: CGFloat {
        centerX - beforeWidth - (pivotWidth / 2) + (totalWidth / 2)
    }

    var body: some View {
        let chars = Array(word)
        let beforeChars = String(chars.prefix(pivot))
        let pivotChar = pivot < chars.count ? String(chars[pivot]) : ""
        let afterChars = String(chars.dropFirst(pivot + 1))

        HStack(spacing: 0) {
            Text(beforeChars)
                .font(fontFamily.font(size: fontSize, weight: .regular))
                .foregroundColor(.white)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: NotchBeforeWidthKey.self, value: geo.size.width)
                    }
                )

            Text(pivotChar)
                .font(fontFamily.font(size: fontSize, weight: .bold))
                .foregroundColor(highlightColor)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: NotchPivotWidthKey.self, value: geo.size.width)
                    }
                )

            Text(afterChars)
                .font(fontFamily.font(size: fontSize, weight: .regular))
                .foregroundColor(.white)
        }
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: NotchTotalWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(NotchBeforeWidthKey.self) { beforeWidth = $0 }
        .onPreferenceChange(NotchPivotWidthKey.self) { pivotWidth = $0 }
        .onPreferenceChange(NotchTotalWidthKey.self) { totalWidth = $0 }
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

// MARK: - Notch Preference Keys

private struct NotchBeforeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NotchPivotWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NotchTotalWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Countdown View

struct CountdownView: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.system(size: 72, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .transition(.asymmetric(
                insertion: .scale(scale: 1.4).combined(with: .opacity),
                removal: .scale(scale: 0.6).combined(with: .opacity)
            ))
            .id(value)
    }
}

// MARK: - Confetti View

struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(particles) { particle in
                    Circle()
                        .fill(particle.color)
                        .frame(width: particle.size, height: particle.size)
                        .position(particle.position)
                        .opacity(particle.opacity)
                }
            }
            .onAppear {
                createParticles(in: geometry.size)
                animateParticles()
            }
        }
    }

    private func createParticles(in size: CGSize) {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
        particles = (0..<50).map { _ in
            ConfettiParticle(
                position: CGPoint(x: CGFloat.random(in: 0...size.width), y: -20),
                color: colors.randomElement() ?? .white,
                size: CGFloat.random(in: 4...8),
                opacity: 1.0,
                velocity: CGPoint(x: CGFloat.random(in: -2...2), y: CGFloat.random(in: 3...6))
            )
        }
    }

    private func animateParticles() {
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            for i in particles.indices {
                particles[i].position.x += particles[i].velocity.x
                particles[i].position.y += particles[i].velocity.y
                particles[i].velocity.y += 0.1 // gravity
                particles[i].opacity -= 0.008
            }
            particles.removeAll { $0.opacity <= 0 }
            if particles.isEmpty {
                timer.invalidate()
            }
        }
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var color: Color
    var size: CGFloat
    var opacity: Double
    var velocity: CGPoint
}
