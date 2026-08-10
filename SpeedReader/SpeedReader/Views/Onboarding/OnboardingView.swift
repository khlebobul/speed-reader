import SwiftUI

/// Full-screen interactive onboarding shown on first launch or via the Guide menu.
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    @State private var appearAnimated = false

    private let totalPages = 5

    var body: some View {
        ZStack {
            // Full-screen background
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content
                Group {
                    switch currentPage {
                    case 0: OnboardingWelcomePage()
                    case 1: OnboardingProblemPage()
                    case 2: OnboardingDemoPage()
                    case 3: OnboardingComparisonPage()
                    case 4: OnboardingGetStartedPage()
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom bar
                HStack {
                    // Page dots
                    HStack(spacing: 8) {
                        ForEach(0..<totalPages, id: \.self) { i in
                            Capsule()
                                .fill(i == currentPage ? Color.accentColor : Color.primary.opacity(0.15))
                                .frame(width: i == currentPage ? 24 : 8, height: 8)
                        }
                    }

                    Spacer()

                    if currentPage < totalPages - 1 {
                        Button("Close", action: dismiss)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                    }

                    Button(action: advance) {
                        Text(currentPage == totalPages - 1 ? "Get Started" : "Continue")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 8)

                Spacer().frame(height: 24)
            }
        }
        .opacity(appearAnimated ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: currentPage)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appearAnimated = true
            }
        }
    }

    private func advance() {
        if currentPage < totalPages - 1 {
            currentPage += 1
        } else {
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isPresented = false
        }
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
    }
}

// MARK: - Page 1: Welcome

private struct OnboardingWelcomePage: View {
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var statsVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero icon
            Image(systemName: "bolt.fill")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .opacity(titleVisible ? 1 : 0)
                .scaleEffect(titleVisible ? 1 : 0.5)
                .padding(.bottom, 24)

            Text("Read 3x Faster")
                .font(.system(size: 44, weight: .bold))
                .opacity(titleVisible ? 1 : 0)
                .offset(y: titleVisible ? 0 : 20)

            Text("Without losing comprehension")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .opacity(subtitleVisible ? 1 : 0)
                .offset(y: subtitleVisible ? 0 : 10)

            // Stats row
            HStack(spacing: 40) {
                StatBadge(value: "250", label: "avg reading", unit: "WPM")
                StatBadge(value: "600+", label: "with RSVP", unit: "WPM", highlighted: true)
            }
            .padding(.top, 40)
            .opacity(statsVisible ? 1 : 0)
            .offset(y: statsVisible ? 0 : 15)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) { titleVisible = true }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) { subtitleVisible = true }
            withAnimation(.easeOut(duration: 0.5).delay(0.5)) { statsVisible = true }
        }
    }
}

private struct StatBadge: View {
    let value: String
    let label: String
    let unit: String
    var highlighted: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(highlighted ? Color.accentColor : .primary)
                Text(unit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Page 2: The Problem

private struct OnboardingProblemPage: View {
    @State private var highlightLine = -1
    @State private var showExplanation = false

    private let sampleLines = [
        "The quick brown fox jumps over the lazy dog.",
        "Your eyes constantly jump back and forth across",
        "each line, wasting time on eye movements instead",
        "of actually processing the words you read.",
        "This is called saccadic movement — and it slows",
        "you down significantly every single day."
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Traditional Reading is Slow")
                .font(.system(size: 32, weight: .bold))
                .padding(.bottom, 8)

            Text("Your eyes waste time jumping across each line")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(.bottom, 40)

            // Simulated paragraph with scanning animation
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sampleLines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 0) {
                        Text(line)
                            .font(.system(size: 16, weight: .regular, design: .serif))
                            .foregroundColor(index <= highlightLine ? .primary : .primary.opacity(0.3))
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )
            )
            .overlay(alignment: .topLeading) {
                // Animated scanning eye indicator
                if highlightLine >= 0 && highlightLine < sampleLines.count {
                    ScanningIndicator(lineIndex: highlightLine)
                }
            }

            // Explanation
            HStack(spacing: 8) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                Text("6 lines = ~50 eye jumps, each taking 20-30ms")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .opacity(showExplanation ? 1 : 0)

            Spacer()
        }
        .onAppear {
            animateScanning()
        }
    }

    private func animateScanning() {
        for i in 0..<sampleLines.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    highlightLine = i
                }
                if i == sampleLines.count - 1 {
                    withAnimation(.easeOut(duration: 0.3).delay(0.3)) {
                        showExplanation = true
                    }
                }
            }
        }
    }
}

private struct ScanningIndicator: View {
    let lineIndex: Int

    @State private var xOffset: CGFloat = 0
    @State private var visible = true

    var body: some View {
        Circle()
            .fill(Color.orange.opacity(0.4))
            .frame(width: 12, height: 12)
            .blur(radius: 4)
            .opacity(visible ? 1 : 0)
            .offset(x: 32 + xOffset, y: 38 + CGFloat(lineIndex) * 28)
            .onAppear {
                xOffset = 0
                visible = true
                withAnimation(.easeInOut(duration: 0.5)) {
                    xOffset = 380
                }
            }
            .onChange(of: lineIndex) {
                xOffset = 0
                withAnimation(.easeInOut(duration: 0.5)) {
                    xOffset = 380
                }
            }
    }
}

// MARK: - Page 3: RSVP Demo

private struct OnboardingDemoPage: View {
    @State private var currentWordIndex = 0
    @State private var isPlaying = false
    @State private var timer: Timer?
    @State private var showHint = true

    private let demoWords = "Speed reading works by showing you one word at a time right where your eyes already are — no scanning, no backtracking, just pure reading speed".components(separatedBy: " ")

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Try RSVP Reading")
                .font(.system(size: 32, weight: .bold))
                .padding(.bottom, 8)

            Text("Words appear one at a time — your eyes stay still")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(.bottom, 40)

            // RSVP display area
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )

                if currentWordIndex < demoWords.count && isPlaying {
                    ORPWordView(
                        word: demoWords[currentWordIndex],
                        baseSize: 40,
                        fontFamily: .sans,
                        highlightColor: .accentColor,
                        maxWidth: 400,
                        showIndicators: true,
                        indicatorColor: .accentColor
                    )
                } else if !isPlaying && currentWordIndex == 0 {
                    VStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.accentColor)
                            .opacity(showHint ? 1 : 0.7)
                            .scaleEffect(showHint ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: showHint)

                        Text("Click to start")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                } else if !isPlaying {
                    ORPWordView(
                        word: demoWords[min(currentWordIndex, demoWords.count - 1)],
                        baseSize: 40,
                        fontFamily: .sans,
                        highlightColor: .accentColor,
                        maxWidth: 400,
                        showIndicators: true,
                        indicatorColor: .accentColor
                    )
                }
            }
            .frame(maxWidth: 500, maxHeight: 120)
            .contentShape(Rectangle())
            .onTapGesture {
                togglePlayback()
            }

            // Speed indicator
            HStack(spacing: 16) {
                Text("300 WPM")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Progress
                ProgressView(value: Double(currentWordIndex), total: Double(max(demoWords.count - 1, 1)))
                    .frame(width: 200)
                    .tint(Color.accentColor)

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.accentColor.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)

            Spacer()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func togglePlayback() {
        if isPlaying {
            isPlaying = false
            timer?.invalidate()
        } else {
            if currentWordIndex >= demoWords.count - 1 {
                currentWordIndex = 0
            }
            showHint = false
            isPlaying = true
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        // 300 WPM = 200ms per word
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            if currentWordIndex < demoWords.count - 1 {
                currentWordIndex += 1
            } else {
                t.invalidate()
                isPlaying = false
            }
        }
    }
}

// MARK: - Page 4: Side-by-Side Comparison

private struct OnboardingComparisonPage: View {
    @State private var rsvpWordIndex = 0
    @State private var normalHighlightIndex = 0
    @State private var isRunning = false
    @State private var timer: Timer?
    @State private var normalTimer: Timer?
    @State private var rsvpFinished = false
    @State private var normalFinished = false
    @State private var showResult = false

    private let demoText = "Scientists have discovered that the human brain can process visual information much faster than most people typically read because traditional reading forces your eyes to physically move across and down the page wasting valuable time on mechanical eye movements rather than actual comprehension"
    private var demoWords: [String] { demoText.components(separatedBy: " ") }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("See the Difference")
                .font(.system(size: 32, weight: .bold))
                .padding(.bottom, 8)

            Text("Same text, two ways to read it")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(.bottom, 32)

            HStack(spacing: 24) {
                // Traditional reading side
                VStack(spacing: 12) {
                    Label("Traditional", systemImage: "text.alignleft")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.primary.opacity(0.06))
                            )

                        // Flowing text with word-by-word highlight
                        NormalReadingView(
                            words: demoWords,
                            highlightIndex: normalHighlightIndex,
                            finished: normalFinished
                        )
                        .padding(16)
                    }
                    .frame(height: 160)

                    if normalFinished {
                        Text("~250 WPM")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    } else if isRunning {
                        Text("Reading...")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                // Divider
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 20)

                // RSVP side
                VStack(spacing: 12) {
                    Label("Speed Reader", systemImage: "bolt.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.accentColor.opacity(0.15))
                            )

                        if rsvpFinished {
                            VStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.green)
                                Text("Done!")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .transition(.scale.combined(with: .opacity))
                        } else {
                            ORPWordView(
                                word: demoWords[rsvpWordIndex],
                                baseSize: 32,
                                fontFamily: .sans,
                                highlightColor: .accentColor,
                                maxWidth: 300,
                                showIndicators: true,
                                indicatorColor: .accentColor
                            )
                        }
                    }
                    .frame(height: 160)

                    if rsvpFinished {
                        Text("~450 WPM")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else if isRunning {
                        Text("Reading...")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 40)

            // Start race button or result
            if !isRunning && !rsvpFinished {
                Button(action: startRace) {
                    Label("Start Comparison", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
            } else if showResult {
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        Text("RSVP finished ")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("1.8x faster")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                        Text(" with the same text")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Button(action: startRace) {
                        Label("Try Again", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 24)
                .transition(.opacity)
            }

            Spacer()
        }
        .onDisappear {
            timer?.invalidate()
            normalTimer?.invalidate()
        }
    }

    private func startRace() {
        rsvpWordIndex = 0
        normalHighlightIndex = 0
        rsvpFinished = false
        normalFinished = false
        showResult = false
        isRunning = true

        // RSVP at ~450 WPM = 133ms per word
        timer = Timer.scheduledTimer(withTimeInterval: 0.133, repeats: true) { t in
            if rsvpWordIndex < demoWords.count - 1 {
                rsvpWordIndex += 1
            } else {
                t.invalidate()
                withAnimation(.spring(response: 0.4)) {
                    rsvpFinished = true
                }
                checkBothFinished()
            }
        }

        // Normal at ~250 WPM = 240ms per word
        normalTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: true) { t in
            if normalHighlightIndex < demoWords.count - 1 {
                normalHighlightIndex += 1
            } else {
                t.invalidate()
                withAnimation(.spring(response: 0.4)) {
                    normalFinished = true
                }
                checkBothFinished()
            }
        }
    }

    private func checkBothFinished() {
        if rsvpFinished && normalFinished {
            withAnimation(.easeOut(duration: 0.3).delay(0.3)) {
                showResult = true
            }
        }
    }
}

private struct NormalReadingView: View {
    let words: [String]
    let highlightIndex: Int
    let finished: Bool

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.system(size: 14, design: .serif))
                    .foregroundColor(wordColor(for: index))
                    .fontWeight(index == highlightIndex && !finished ? .semibold : .regular)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index == highlightIndex && !finished ? Color.orange.opacity(0.15) : Color.clear)
                    )
            }
        }
    }

    private func wordColor(for index: Int) -> Color {
        if finished { return .primary }
        if index < highlightIndex { return .primary.opacity(0.4) }
        if index == highlightIndex { return .primary }
        return .primary.opacity(0.2)
    }
}


// MARK: - Page 5: Get Started

private struct OnboardingGetStartedPage: View {
    @State private var visible = false

    private let features: [(icon: String, color: Color, title: String, desc: String)] = [
        ("doc.text", .blue, "Paste or Drop Text", "Articles, books, PDFs, EPUB, Markdown"),
        ("link", .purple, "Load from URL", "Extract articles from any webpage"),
        ("rectangle.inset.filled", .orange, "Multiple Reading Modes", "Main window, floating panel, or notch widget"),
        ("menubar.rectangle", .green, "Menu Bar Access", "Quick access without switching windows"),
        ("gearshape", .gray, "Fully Customizable", "Speed, fonts, colors, ORP highlighting"),
        ("lock.open", .teal, "Free and Open", "No account, license, or data collection"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .padding(.bottom, 16)
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible ? 1 : 0.5)

            Text("You're Ready")
                .font(.system(size: 32, weight: .bold))
                .opacity(visible ? 1 : 0)
                .padding(.bottom, 8)

            Text("Everything you need to read faster")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .opacity(visible ? 1 : 0)
                .padding(.bottom, 32)

            // Feature list
            VStack(spacing: 12) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    HStack(spacing: 14) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(feature.color)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(feature.color.opacity(0.1))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.system(size: 14, weight: .medium))
                            Text(feature.desc)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .opacity(visible ? 1 : 0)
                    .offset(x: visible ? 0 : -20)
                    .animation(.easeOut(duration: 0.4).delay(Double(index) * 0.08 + 0.2), value: visible)
                }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                visible = true
            }
        }
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
        .frame(width: 800, height: 600)
}
