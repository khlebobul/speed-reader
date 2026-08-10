import SwiftUI

struct ReaderView: View {
    @ObservedObject var engine: RSVPEngine
    @Binding var wpm: Double
    var onClose: () -> Void

    private let settings = ReaderSettings.shared
    @State private var showConfetti: Bool = false
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }

                Spacer()

                // Word Display with ORP or Finish
                if engine.isFinished {
                    Text("Finish!")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                } else {
                    ORPWordView(word: engine.currentWord, settings: settings)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                }

                Spacer()

                // Progress
                VStack(spacing: 8) {
                    ProgressView(value: engine.progress, total: 100)
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(engine.currentIndex + 1) / \(engine.totalWords)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(engine.remainingTime)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 32)

                // Pre-reading time estimate
                if !engine.isPlaying && !engine.isFinished && engine.totalWords > 0 {
                    TimeSavingsEstimateView(
                        totalWords: engine.totalWords,
                        wpm: Int(wpm),
                        isDark: false
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Controls
                VStack(spacing: 16) {
                // Playback controls
                HStack(spacing: 0) {
                    HStack(spacing: 24) {
                        Button(action: engine.restart) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("r", modifiers: [])

                        Button(action: engine.previousWord) {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    Button(action: engine.togglePlayPause) {
                        Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .padding(.horizontal, 24)

                    HStack(spacing: 24) {
                        Button(action: engine.nextWord) {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.rightArrow, modifiers: [])

                        Button(action: onClose) {
                            Image(systemName: "stop.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Speed control
                HStack {
                    Text("Speed:")
                        .foregroundColor(.secondary)

                    Slider(value: $wpm, in: 100...1000, step: 50) { _ in
                        engine.setWPM(Int(wpm))
                    }
                    .frame(width: 200)

                    Text("\(Int(wpm)) WPM")
                        .monospacedDigit()
                        .frame(width: 80, alignment: .leading)
                }
            }
                .padding(32)
            }

            // Confetti overlay
            if showConfetti {
                ReaderConfettiView()
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 49: // Space — play/pause
                    engine.togglePlayPause()
                    return nil
                case 123: // Left arrow — previous word
                    engine.previousWord()
                    return nil
                case 124: // Right arrow — next word
                    engine.nextWord()
                    return nil
                case 126: // Up arrow — speed up
                    wpm = min(1000, wpm + 50)
                    engine.setWPM(Int(wpm))
                    return nil
                case 125: // Down arrow — speed down
                    wpm = max(100, wpm - 50)
                    engine.setWPM(Int(wpm))
                    return nil
                case 15: // R — restart
                    engine.restart()
                    return nil
                case 53: // Escape — close
                    onClose()
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .onChange(of: engine.isFinished) { _, finished in
            if finished {
                showConfetti = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    showConfetti = false
                }
            }
        }
    }
}

// MARK: - Confetti View for Reader

struct ReaderConfettiView: View {
    @State private var particles: [ReaderConfettiParticle] = []

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
        particles = (0..<80).map { _ in
            ReaderConfettiParticle(
                position: CGPoint(x: CGFloat.random(in: 0...size.width), y: -20),
                color: colors.randomElement() ?? .blue,
                size: CGFloat.random(in: 6...12),
                opacity: 1.0,
                velocity: CGPoint(x: CGFloat.random(in: -3...3), y: CGFloat.random(in: 4...8))
            )
        }
    }

    private func animateParticles() {
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            for i in particles.indices {
                particles[i].position.x += particles[i].velocity.x
                particles[i].position.y += particles[i].velocity.y
                particles[i].velocity.y += 0.15
                particles[i].opacity -= 0.006
            }
            particles.removeAll { $0.opacity <= 0 }
            if particles.isEmpty {
                timer.invalidate()
            }
        }
    }
}

struct ReaderConfettiParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var color: Color
    var size: CGFloat
    var opacity: Double
    var velocity: CGPoint
}
