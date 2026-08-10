import Foundation
import Combine

class RSVPEngine: ObservableObject {
    /// Shared word-splitting regex used by RSVP engine and OCR word location builder.
    /// Handles: URLs, words, numbers, currency ($9.56), decimals (3.14), emoji, hyphenated words, quotes.
    static let wordPattern = #"https?://\S+|["'«»„""''‚‹›]*[$€£¥₹₽¢]?[\p{L}\p{N}\p{Extended_Pictographic}]+(?:[.,]\d+)*(?:[-']\p{L}+)*[%.,!?;:…"'«»„""''‚‹›]*"#

    /// Placeholder words injected by `MarkdownPreviewView` for formula/image/code blocks.
    /// Single source of truth so `MarkdownPreviewView`'s JS, PDF highlight views, and any future
    /// consumer agree on what counts as a placeholder beat.
    static let placeholderFormula = "formula"
    static let placeholderImage = "image"
    static let placeholderCode = "code"
    static let placeholderTable = "table"

    /// Set used by PDF highlight views to skip highlighting on placeholder beats — these words
    /// don't correspond to PDF text so `findString` would either fail (wasted work) or land on a
    /// stray match. Keeping the previous highlight is the right behavior on the Original tab.
    static let placeholderWords: Set<String> = [placeholderFormula, placeholderImage, placeholderCode, placeholderTable]

    @Published var currentWord: String = ""
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var isFinished: Bool = false
    @Published var progress: Double = 0
    @Published var remainingTime: String = "0:00"
    @Published var readingStats: ReadingSessionStats?

    /// When true, finishing the stream restarts from index 0 and keeps playing instead of stopping.
    /// Currently only the Zen reader exposes a UI for it; other modes leave this at the default.
    var loopEnabled: Bool = false

    /// How many words are shown at once during automatic playback. ORP is applied only to the
    /// first word of the chunk; trailing words read normally. Currently only the Zen reader
    /// exposes a UI; other modes leave this at the default of 1 (single-word RSVP).
    @Published var wordsPerChunk: Int = 1

    private var words: [String] = []
    private(set) var wordRanges: [Range<String.Index>] = []
    private(set) var sourceText: String = ""
    private(set) var markdownSource: String?
    private var timer: Timer?
    private var wpm: Int = ReaderSettings.shared.wpm
    private var settingsCancellables = Set<AnyCancellable>()

    /// Maps RSVP word index → `PauseableBlock` for placeholder beats (image / formula
    /// / table / code). Populated by `loadText(_:pauseableBlocks:)`; empty for sources
    /// without structured blocks.
    private(set) var pauseableBlocks: [Int: PauseableBlock] = [:]

    /// True while the engine is paused on a placeholder beat by auto-pause.
    /// On the next `play()` the engine advances past the placeholder *before* showing
    /// it again, so Space → continue feels instant instead of re-flashing the placeholder.
    private var pausedAtPlaceholder: Bool = false

    /// Auto-continue timer state. Set when the engine pauses on a placeholder and
    /// `pauseContinueMode == .timed`. `nil` when not paused or in `.manual` mode.
    /// Views observe this to render a countdown.
    @Published private(set) var autoContinueDeadline: Date?
    private var autoContinueTimer: Timer?

    /// `PauseableBlock` for the current beat when it's a placeholder *and* the user
    /// has auto-pause enabled for that block kind. Returns `nil` if the kind is
    /// disabled in settings — that way the engine simply doesn't pause for that kind.
    var currentPauseableBlock: PauseableBlock? {
        guard let block = pauseableBlocks[currentIndex] else { return nil }
        guard ReaderSettings.shared.isAutoPauseEnabled(for: block.kind) else { return nil }
        return block
    }

    /// Convenience for views that only care about image blocks.
    var currentImage: ImageRef? {
        if case .image(let ref) = currentPauseableBlock { return ref }
        return nil
    }

    // Source tracking
    var currentSource: String = "Text"

    // Time tracking
    private var readingStartTime: Date?
    private var accumulatedReadingTime: TimeInterval = 0
    private var lastResumeTime: Date?

    var totalWords: Int { words.count }

    var currentWordRange: Range<String.Index>? {
        guard currentIndex < wordRanges.count else { return nil }
        return wordRanges[currentIndex]
    }

    /// Word indices visible at once for the current beat — `[currentIndex, currentIndex+wordsPerChunk)`,
    /// clamped to the end of the array. Always non-empty when `words` is non-empty.
    var currentChunkRange: Range<Int> {
        guard !words.isEmpty else { return 0..<0 }
        let lower = max(0, min(currentIndex, words.count - 1))
        let upper = min(words.count, lower + max(1, wordsPerChunk))
        return lower..<upper
    }

    /// The chunk's words as an array (1..N elements).
    var currentChunkWords: [String] {
        let r = currentChunkRange
        guard r.lowerBound < r.upperBound else { return [] }
        return Array(words[r])
    }

    init() {
        ReaderSettings.shared.$wpm
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newWPM in
                self?.applyWPM(newWPM, persistToSettings: false)
            }
            .store(in: &settingsCancellables)
    }

    func wordAt(_ index: Int) -> String {
        guard index >= 0, index < words.count else { return "" }
        return words[index]
    }

    func upcomingWords(after index: Int, limit: Int) -> [String] {
        let start = max(0, index + 1)
        guard start < words.count else { return [] }
        let end = min(start + limit, words.count)
        return Array(words[start..<end])
    }

    func previousWords(before index: Int? = nil, limit: Int = 5) -> [String] {
        let end = min(max(0, index ?? currentIndex), words.count)
        return Array(words[max(0, end - limit)..<end])
    }

    // MARK: - Public Methods

    func loadText(_ text: String, markdownSource: String? = nil) {
        loadText(text, pauseableBlocks: [:], markdownSource: markdownSource)
    }

    /// Same as `loadText(_:)` but installs the word-index → block map used by
    /// the auto-pause-on-blocks flow. Pass `[:]` for sources that don't carry
    /// structured block info.
    func loadText(_ text: String, pauseableBlocks: [Int: PauseableBlock], markdownSource: String? = nil) {
        let (extractedWords, extractedRanges) = splitText(text)
        words = extractedWords
        wordRanges = extractedRanges
        sourceText = text
        self.markdownSource = markdownSource
        self.pauseableBlocks = pauseableBlocks
        currentIndex = 0
        isFinished = false
        pausedAtPlaceholder = false
        cancelAutoContinueTimer()
        resetTimingState()
        updateCurrentWord()
        updateProgress()
        updateRemainingTime()
    }

    /// Back-compat overload for the original image-only API. New callers should pass
    /// `PauseableBlock.image(ref)` values via `loadText(_:pauseableBlocks:)` directly.
    func loadText(_ text: String, imageRefs: [Int: ImageRef]) {
        let blocks = imageRefs.mapValues { PauseableBlock.image($0) }
        loadText(text, pauseableBlocks: blocks)
    }

    func play() {
        guard !words.isEmpty else { return }

        // If at the end, restart from beginning
        if currentIndex >= words.count - 1 {
            currentIndex = 0
            isFinished = false
            pausedAtPlaceholder = false
            resetTimingState()
            updateCurrentWord()
            updateProgress()
            updateRemainingTime()
        }

        // Cancel any pending auto-continue timer — the user just resumed (manually
        // or via the timer firing); either way the timer is no longer needed.
        cancelAutoContinueTimer()

        // Resuming from an auto-pause on a placeholder: jump past it so the user
        // doesn't see the placeholder re-flash for a full beat before the stream
        // moves on.
        if pausedAtPlaceholder, currentIndex < words.count - 1 {
            pausedAtPlaceholder = false
            currentIndex += 1
            updateCurrentWord()
            updateProgress()
            updateRemainingTime()
        }

        let isFirstPlay = readingStartTime == nil
        if isFirstPlay {
            readingStartTime = Date()
        }
        lastResumeTime = Date()

        isPlaying = true
        if autoPauseOnCurrentPlaceholderIfNeeded() {
            return
        }
        // On resume after a pause, give the eye a brief moment to re-fixate on the current word
        // before the stream starts flowing again. First-ever play uses the regular per-word delay.
        scheduleNextWord(initialDelay: isFirstPlay ? nil : 0.6)
    }

    func pause() {
        if let resumeTime = lastResumeTime {
            accumulatedReadingTime += Date().timeIntervalSince(resumeTime)
            lastResumeTime = nil
        }
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    /// Cancel a pending auto-continue countdown. Used by:
    /// - The internal pause/seek/nav path (so the timer doesn't fire after a
    ///   manual action).
    /// - The lightbox UI when the user opens it to study a block — the timer
    ///   shouldn't fire while the user is inspecting; resuming is an explicit
    ///   Space afterwards.
    func cancelAutoContinueTimer() {
        autoContinueTimer?.invalidate()
        autoContinueTimer = nil
        autoContinueDeadline = nil
    }

    /// Starts the auto-continue countdown if the user has `.timed` continue mode.
    /// Called from the auto-pause path after `pause()`. In `.manual` mode this is
    /// a no-op so the engine just waits for an explicit Space.
    private func scheduleAutoContinueIfNeeded() {
        cancelAutoContinueTimer()
        let settings = ReaderSettings.shared
        guard settings.pauseContinueMode == .timed else { return }
        let delay = settings.pauseDuration
        autoContinueDeadline = Date().addingTimeInterval(delay)
        autoContinueTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.handleAutoContinueFired()
        }
    }

    private func handleAutoContinueFired() {
        cancelAutoContinueTimer()
        // The user didn't intervene — play through. `play()` will see
        // `pausedAtPlaceholder` and skip past the placeholder beat automatically.
        play()
    }

    func togglePlayPause() {
        if isPlaying {
            cancelAutoContinueTimer()
            pause()
        } else {
            play()
        }
    }

    func restart() {
        cancelAutoContinueTimer()
        pause()
        currentIndex = 0
        isFinished = false
        pausedAtPlaceholder = false
        resetTimingState()
        updateCurrentWord()
        updateProgress()
        updateRemainingTime()
    }

    func nextWord() {
        guard currentIndex < words.count - 1 else { return }
        cancelAutoContinueTimer()
        currentIndex += 1
        isFinished = false
        pausedAtPlaceholder = false
        updateCurrentWord()
        updateProgress()
        updateRemainingTime()
    }

    func previousWord() {
        guard currentIndex > 0 else { return }
        cancelAutoContinueTimer()
        currentIndex -= 1
        isFinished = false
        pausedAtPlaceholder = false
        updateCurrentWord()
        updateProgress()
        updateRemainingTime()
    }

    func seekTo(_ index: Int) {
        guard !words.isEmpty else { return }
        cancelAutoContinueTimer()
        currentIndex = max(0, min(index, words.count - 1))
        isFinished = false
        pausedAtPlaceholder = false
        updateCurrentWord()
        updateProgress()
        updateRemainingTime()

        if autoPauseOnCurrentPlaceholderIfNeeded() {
            return
        }

        if isPlaying {
            timer?.invalidate()
            scheduleNextWord()
        }
    }

    func seekByWords(_ delta: Int) {
        seekTo(currentIndex + delta)
    }

    func setWPM(_ newWPM: Int) {
        applyWPM(newWPM, persistToSettings: true)
    }

    func getWPM() -> Int {
        return wpm
    }

    /// Set chunk size (1–7). Reschedules the next beat if currently playing so the new size
    /// takes effect immediately rather than only at the next beat.
    func setWordsPerChunk(_ n: Int) {
        let clamped = max(1, min(7, n))
        guard clamped != wordsPerChunk else { return }
        wordsPerChunk = clamped
        if isPlaying {
            timer?.invalidate()
            scheduleNextWord()
        }
        updateRemainingTime()
    }

    // MARK: - Private Methods

    private func applyWPM(_ newWPM: Int, persistToSettings: Bool) {
        let clampedWPM = max(100, min(1000, newWPM))
        let changed = wpm != clampedWPM

        wpm = clampedWPM

        if persistToSettings, ReaderSettings.shared.wpm != clampedWPM {
            ReaderSettings.shared.wpm = clampedWPM
        }

        if changed, isPlaying {
            timer?.invalidate()
            scheduleNextWord()
        }
        updateRemainingTime()
    }

    private func scheduleNextWord(initialDelay: TimeInterval? = nil) {
        let delay = initialDelay ?? calculateDelay(forChunk: currentChunkWords)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.advanceWord()
        }
    }

    private func advanceWord() {
        currentIndex += max(1, wordsPerChunk)

        if currentIndex >= words.count {
            if loopEnabled {
                // Loop: jump back to the start and keep playing. Don't generate stats or fire the
                // finish state — the session is one continuous loop until the user pauses or closes.
                currentIndex = 0
                updateCurrentWord()
                updateProgress()
                updateRemainingTime()
                if isPlaying {
                    scheduleNextWord()
                }
                return
            }

            // Accumulate final reading time before pausing
            if let resumeTime = lastResumeTime {
                accumulatedReadingTime += Date().timeIntervalSince(resumeTime)
                lastResumeTime = nil
            }
            isPlaying = false
            timer?.invalidate()
            timer = nil
            currentIndex = words.count - 1
            isFinished = true
            generateReadingStats()
            return
        }

        updateCurrentWord()
        updateProgress()
        updateRemainingTime()

        // Auto-pause on placeholder beats (image / formula / table / code). Fires when
        // the freshly-advanced word maps to a `PauseableBlock` whose kind is enabled
        // in settings. We pause instead of scheduling the next beat; `play()` reads
        // `pausedAtPlaceholder` and skips past the placeholder when the user presses
        // Space (or when the auto-continue timer fires).
        if autoPauseOnCurrentPlaceholderIfNeeded() {
            return
        }

        if isPlaying {
            scheduleNextWord()
        }
    }

    /// Auto-pause on the current placeholder beat. Used both by normal playback
    /// (`advanceWord`) and by direct positioning (`play` after selecting a start
    /// word, `seekTo` via TOC/search) so starting exactly on a block still shows
    /// the block preview instead of skipping past it.
    private func autoPauseOnCurrentPlaceholderIfNeeded() -> Bool {
        guard isPlaying, currentPauseableBlock != nil else { return false }
        pausedAtPlaceholder = true
        pause()
        scheduleAutoContinueIfNeeded()
        return true
    }

    private func updateCurrentWord() {
        guard currentIndex < words.count else {
            currentWord = ""
            return
        }
        currentWord = words[currentIndex]
    }

    private func updateProgress() {
        guard !words.isEmpty else {
            progress = 0
            return
        }
        // Handle single word case (avoid division by zero)
        if words.count == 1 {
            progress = currentIndex == 0 ? 0 : 100
        } else {
            progress = Double(currentIndex) / Double(words.count - 1) * 100
        }
    }

    private func updateRemainingTime() {
        let remaining = words.count - 1 - currentIndex
        guard remaining > 0 else {
            remainingTime = "0:00"
            return
        }
        // Chunked playback covers N words per beat in (1 + 0.3*(N-1)) per-word delays — sub-linear
        // scaling. Effective WPM = wpm * N / (1 + 0.3*(N-1)). For chunk size 1 this collapses to wpm.
        let n = max(1, wordsPerChunk)
        let effectiveWPM = Double(wpm) * Double(n) / (1.0 + 0.3 * Double(n - 1))
        let seconds = Double(remaining) / effectiveWPM * 60.0
        let totalSeconds = Int(ceil(seconds))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        remainingTime = String(format: "%d:%02d", mins, secs)
    }

    private func calculateDelay(for word: String) -> TimeInterval {
        let baseDelay = 60.0 / Double(wpm)
        var multiplier = 1.0

        // Long words
        if word.count > 8 {
            multiplier += Double(word.count - 8) * 0.04
        }

        // Punctuation delays
        if word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") {
            multiplier += 1.0
        } else if word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") {
            multiplier += 0.4
        } else if word.hasSuffix("—") || word.hasSuffix("–") {
            multiplier += 0.4
        } else if word.hasSuffix("...") || word.hasSuffix("…") {
            multiplier += 0.5
        }

        return baseDelay * multiplier
    }

    /// Delay for a chunk of words shown together. Falls back to single-word timing when the chunk
    /// has one element. For larger chunks: pick the slowest per-word delay (so a long word or
    /// punctuation in the middle of the chunk still pauses correctly), then scale by `1 + 0.3*(N-1)`
    /// so each extra word stretches the beat sub-linearly — the eye doesn't need 2× time for 2 words.
    private func calculateDelay(forChunk chunk: [String]) -> TimeInterval {
        guard !chunk.isEmpty else { return 60.0 / Double(wpm) }
        if chunk.count == 1 { return calculateDelay(for: chunk[0]) }
        let perWordMax = chunk.map { calculateDelay(for: $0) }.max() ?? (60.0 / Double(wpm))
        let chunkMultiplier = 1.0 + 0.3 * Double(chunk.count - 1)
        return perWordMax * chunkMultiplier
    }

    private func resetTimingState() {
        readingStartTime = nil
        accumulatedReadingTime = 0
        lastResumeTime = nil
        readingStats = nil
    }

    private func generateReadingStats() {
        let now = Date()
        let stats = ReadingSessionStats(
            totalWords: words.count,
            readingTimeSeconds: accumulatedReadingTime,
            configuredWPM: wpm,
            startedAt: readingStartTime ?? now,
            finishedAt: now
        )
        readingStats = stats
        ReadingHistoryManager.shared.add(stats, source: currentSource)
        ReadingStreakTracker.shared.record(seconds: stats.readingTimeSeconds, on: now)
    }

    private func splitText(_ text: String) -> ([String], [Range<String.Index>]) {
        // Pattern includes:
        // 1. Words with optional quotes and punctuation
        // 2. Standalone emojis (Extended_Pictographic covers all emoji)
        // Opening quotes: " ' « „ ‚ ‹ ' "
        // Closing quotes: " ' » " › ' "
        let pattern = Self.wordPattern

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            let fallback = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            return (fallback, [])
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        var resultWords: [String] = []
        var resultRanges: [Range<String.Index>] = []

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            if !word.isEmpty {
                resultWords.append(word)
                resultRanges.append(range)
            }
        }

        return (resultWords, resultRanges)
    }
}
