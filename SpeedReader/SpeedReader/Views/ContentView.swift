import SwiftUI

struct ContentView: View {
    @State private var inputText: String = """
        Speed Reader uses RSVP (Rapid Serial Visual Presentation) to show you one word at a time. Your eyes stay fixed on one spot and you read faster without scanning left to right.

        How to use:
        1. Replace this text with anything you want to read — article, book, or notes
        2. Set your reading speed (start at 300 WPM and go up as you get comfortable)
        3. Press Start Reading — words will flash one at a time

        You can also press ⌘⇧V to instantly paste anything from your clipboard and start reading right away.
        """
    @State private var textInputFormat: TextInputFormat = .plain
    @State private var fileText: String = ""
    @State private var filePauseableBlocks: [Int: PauseableBlock] = [:]
    @State private var areaText: String = ""
    @State private var urlText: String = ""
    @State private var urlLoadedText: String = ""
    @State private var urlPauseableBlocks: [Int: PauseableBlock] = [:]
    @State private var urlBlocks: [TextBlock]? = nil
    @State private var urlTOC: TableOfContents? = nil
    @State private var selectedItem: SidebarItem = .text
    @State private var isReadingInline: Bool = false
    @State private var isReadingExternal: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingStatistics: Bool = false
    @State private var showingOnboarding: Bool = !UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
    @State private var selectedSettingsTab: SettingsTab = .general
    @State private var isLoadingURL: Bool = false
    @State private var urlError: String?
    @State private var sidebarCollapsed: Bool = false
    @State private var sessionProgress: [SidebarItem: Int] = [:]
    @State private var sessionTotalWords: [SidebarItem: Int] = [:]
    @State private var showContinuePrompt: Bool = false
    @State private var userStartIndex: [SidebarItem: Int] = [:]
    @StateObject private var urlFetcher = URLTextFetcher()
    @ObservedObject private var settings = ReaderSettings.shared

    private var engine: RSVPEngine {
        AppDelegate.shared?.engine ?? RSVPEngine()
    }

    private var activeText: String {
        switch selectedItem {
        case .url: return urlLoadedText
        case .file: return fileText
        case .text:
            switch textInputFormat {
            case .plain: return inputText
            case .markdown: return MarkdownReader.plainText(fromMarkdown: inputText)
            }
        case .area: return areaText
        }
    }

    private var activeMarkdownSource: String? {
        selectedItem == .text && textInputFormat == .markdown ? inputText : nil
    }

    private var activePauseableBlocks: [Int: PauseableBlock] {
        switch selectedItem {
        case .url: return urlPauseableBlocks
        case .file: return filePauseableBlocks
        case .text, .area: return [:]
        }
    }

    private var hasText: Bool {
        !activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isReading: Bool {
        isReadingInline || isReadingExternal
    }

    private var wpmBinding: Binding<Double> {
        Binding(
            get: { Double(settings.wpm) },
            set: { settings.wpm = max(100, min(1000, Int($0))) }
        )
    }

    private let sidebarExpandedWidth: CGFloat = 170
    private let sidebarCollapsedWidth: CGFloat = 52
    @State private var escMonitor: Any?

    /// Block currently shown in the full-window lightbox overlay. Hoisted here (not
    /// in `InlineReaderView`) so the overlay covers sidebar + content, not just the
    /// floating reader card.
    @State private var lightboxBlock: PauseableBlock?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Sidebar
                sidebar
                    .frame(width: sidebarCollapsed ? sidebarCollapsedWidth : sidebarExpandedWidth)
                    .background(Color(NSColor.windowBackgroundColor))

                // Soft divider
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 1)

                // Main content
                VStack(spacing: 0) {
                    // Content area — all tabs stay alive to preserve state
                    ZStack {
                        TextInputView(
                            inputText: $inputText,
                            inputFormat: $textInputFormat,
                            selectedStartIndex: startIndexBinding(for: .text),
                            readingEngine: isReading ? engine : nil
                        )
                        .opacity(selectedItem == .text ? 1 : 0)
                        .allowsHitTesting(selectedItem == .text)

                        URLInputView(
                            urlText: $urlText,
                            inputText: $urlLoadedText,
                            blocks: $urlBlocks,
                            toc: $urlTOC,
                            isLoadingURL: $isLoadingURL,
                            urlError: $urlError,
                            selectedStartIndex: startIndexBinding(for: .url),
                            onLoadURL: loadFromURL,
                            readingEngine: isReading ? engine : nil,
                            onClose: {
                                urlLoadedText = ""
                                urlBlocks = nil
                                urlTOC = nil
                                urlError = nil
                                userStartIndex.removeValue(forKey: .url)
                            }
                        )
                        .opacity(selectedItem == .url ? 1 : 0)
                        .allowsHitTesting(selectedItem == .url)

                        FileInputView(
                            inputText: $fileText,
                            selectedStartIndex: startIndexBinding(for: .file),
                            pauseableBlocks: $filePauseableBlocks,
                            engine: isReading ? engine : nil
                        )
                        .opacity(selectedItem == .file ? 1 : 0)
                        .allowsHitTesting(selectedItem == .file)

                        AreaInputView(
                            inputText: $areaText,
                            selectedStartIndex: startIndexBinding(for: .area),
                            readingEngine: isReading ? engine : nil
                        )
                        .opacity(selectedItem == .area ? 1 : 0)
                        .allowsHitTesting(selectedItem == .area)
                    }

                    if isReadingInline {
                        InlineReaderView(
                            engine: engine,
                            wpm: wpmBinding,
                            onClose: stopInlineReading,
                            onOpenLightbox: { block in openLightbox(for: block) }
                        )
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                )
                            )
                    } else if isReadingExternal {
                        ExternalReaderBar(
                            engine: engine,
                            mode: settings.readingMode,
                            onShow: { AppDelegate.shared?.bringExternalReaderToFront() },
                            onStop: { AppDelegate.shared?.stopExternalReader() }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            )
                        )
                    }

                    // Bottom bar: reading mode selector + start button
                    if !isReading {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 1)

                        VStack(spacing: 14) {
                            ReadingModeSelector(
                                selectedMode: $settings.readingMode
                            )

                            // Start position indicator
                            if let startIdx = userStartIndex[selectedItem] {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.right.to.line")
                                        .font(.system(size: 11))
                                    Text("Starting from word \(startIdx + 1)")
                                        .font(.system(size: 12))
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            userStartIndex[selectedItem] = nil
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .foregroundColor(.secondary)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            // Pre-reading time estimate
                            if hasText, !isReading {
                                TimeSavingsEstimateView(
                                    totalWords: engine.totalWords > 0 ? engine.totalWords : estimatedWordCount(for: activeText),
                                    wpm: settings.wpm,
                                    isDark: false
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            Button(action: startReading) {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 14))
                                    Text("Start Reading")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("⌘⏎")
                                        .font(.system(size: 12, weight: .medium))
                                        .opacity(0.6)
                                }
                                .foregroundColor(hasText ? .white : .accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .padding(.horizontal, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(hasText ? Color.accentColor : Color.primary.opacity(0.04))
                                )
                                .shadow(color: hasText ? Color.accentColor.opacity(0.3) : .clear, radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!hasText)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
                .background(Color(NSColor.windowBackgroundColor))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isReadingInline)
            }
            // Dim the main content when overlay is open
            .overlay {
                if showingSettings || showingStatistics || showingOnboarding {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }

            // Continue reading dialog
            if showContinuePrompt,
               let savedIndex = sessionProgress[selectedItem],
               let totalWords = sessionTotalWords[selectedItem] {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showContinuePrompt = false
                        }
                        doStartReading(resumeFromIndex: nil, autoPlay: false)
                    }

                VStack(spacing: 16) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)

                    Text("Continue Reading?")
                        .font(.system(size: 15, weight: .semibold))

                    Text("You stopped at word \(min(savedIndex, totalWords)) of \(totalWords) (\(min(Int(Double(savedIndex) / Double(totalWords) * 100), 100))%)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showContinuePrompt = false
                            }
                            doStartReading(resumeFromIndex: nil, autoPlay: false)
                        } label: {
                            Text("Start Over")
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            let idx = savedIndex
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showContinuePrompt = false
                            }
                            doStartReading(resumeFromIndex: idx, autoPlay: false)
                        } label: {
                            Text("Continue")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(width: 260)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 30, y: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            // Statistics overlay
            if showingStatistics {
                StatisticsOverlay(isPresented: $showingStatistics)
                    .transition(.opacity)
            }

            // Settings overlay
            if showingSettings {
                SettingsOverlay(
                    isPresented: $showingSettings,
                    selectedTab: $selectedSettingsTab
                )
                    .transition(.opacity)
            }

            // Onboarding overlay
            if showingOnboarding {
                OnboardingView(isPresented: $showingOnboarding)
                .transition(.opacity)
            }

            // Lightbox sits at the top of the root ZStack so it covers sidebar +
            // content + reader card.
            if let block = lightboxBlock {
                BlockLightboxOverlay(block: block, onDismiss: closeLightbox)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.easeOut(duration: 0.18), value: lightboxBlock != nil)
        .frame(minWidth: 520, minHeight: 450)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSettingsTab = .general
                showingSettings = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showingOnboarding = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToTab)) { notification in
            guard !isReading,
                  let tab = notification.object as? SidebarItem else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedItem = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .externalReaderDidClose)) { _ in
            saveSessionProgress()
            if selectedItem == .file, let file = RecentFilesManager.shared.currentFile {
                RecentFilesManager.shared.saveProgress(for: file, wordIndex: engine.currentIndex)
            }
            isReadingExternal = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .startReading)) { _ in
            startReading()
        }
        .onReceive(NotificationCenter.default.publisher(for: .loadBrowserURL)) { notification in
            guard let url = notification.object as? String else { return }
            urlText = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                loadFromURL()
            }
        }
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                // ⌘F → open search (only over a searchable preview, never in .text or while reading/modal)
                if event.keyCode == 3,
                   event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.shift),
                   !event.modifierFlags.contains(.option),
                   selectedItem != .text,
                   !isReading,
                   !showingSettings,
                   !showingStatistics {
                    NotificationCenter.default.post(name: .openSearch, object: nil)
                    return nil
                }

                // ⌘⇧O → toggle the table of contents over a book preview (File
                // and URL tabs — both can have a non-empty TOC; works during
                // reading too so you can jump chapters mid-stream)
                if event.keyCode == 31,
                   event.modifierFlags.contains(.command),
                   event.modifierFlags.contains(.shift),
                   !event.modifierFlags.contains(.option),
                   (selectedItem == .file || selectedItem == .url),
                   !showingSettings,
                   !showingStatistics {
                    NotificationCenter.default.post(name: .toggleTOC, object: nil)
                    return nil
                }

                guard event.keyCode == 53, !isReading, !showingSettings, !showingStatistics else { return event }
                switch selectedItem {
                case .url:
                    if !urlLoadedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        urlLoadedText = ""
                        urlBlocks = nil
                        urlTOC = nil
                        urlError = nil
                        userStartIndex.removeValue(forKey: .url)
                        return nil
                    }
                case .file, .area:
                    NotificationCenter.default.post(name: .dismissDocument, object: nil)
                    return nil
                case .text:
                    break
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = escMonitor {
                NSEvent.removeMonitor(monitor)
                escMonitor = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if sidebarCollapsed {
                VStack(spacing: 8) {
                    collapseSidebarButton
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 8)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    collapseSidebarButton

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            // Tab items
            VStack(spacing: 4) {
                ForEach(SidebarItem.allCases) { item in
                    sidebarButton(item: item)
                        .keyboardShortcut(item.shortcutKey, modifiers: .command)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // Bottom actions
            VStack(spacing: 4) {
                // Help
                sidebarActionButton(
                    icon: "questionmark.circle",
                    label: "Help"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingOnboarding = true
                    }
                }

                // Statistics
                sidebarActionButton(
                    icon: "chart.bar",
                    label: "Statistics"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingStatistics = true
                    }
                }

                // Settings
                sidebarActionButton(
                    icon: "gearshape",
                    label: "Settings"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSettings = true
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var collapseSidebarButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                sidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @State private var hoveredItem: SidebarItem? = nil
    @State private var lockedTabTooltip: SidebarItem? = nil

    private func sidebarButton(item: SidebarItem) -> some View {
        let isSelected = selectedItem == item
        let isHovered = hoveredItem == item && !isSelected
        let isLocked = isReading && !isSelected

        return Button {
            if isReading {
                NotificationCenter.default.post(name: .highlightCloseButton, object: nil)
                withAnimation(.easeInOut(duration: 0.15)) {
                    lockedTabTooltip = item
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if lockedTabTooltip == item { lockedTabTooltip = nil }
                    }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedItem = item
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                    .frame(width: 22)

                if !sidebarCollapsed {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)

                    Spacer()
                }
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
            .padding(.horizontal, sidebarCollapsed ? 0 : 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.08) : .clear, radius: 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isLocked ? 0.5 : 1.0)
        .help(isLocked ? "Stop reading to switch tabs" : item.rawValue)
        .overlay(alignment: sidebarCollapsed ? .trailing : .topTrailing) {
            if lockedTabTooltip == item {
                Text("Stop reading to switch tabs")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.75))
                    )
                    .fixedSize()
                    .offset(x: sidebarCollapsed ? 8 : 0, y: sidebarCollapsed ? 0 : -4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            hoveredItem = hovering ? item : nil
        }
    }

    @State private var hoveredAction: String? = nil

    private func sidebarActionButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction == label
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)

                if !sidebarCollapsed {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Spacer()
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, sidebarCollapsed ? 0 : 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredAction = hovering ? label : nil
        }
    }

    // MARK: - Helpers

    private func startIndexBinding(for item: SidebarItem) -> Binding<Int?> {
        Binding(
            get: { userStartIndex[item] },
            set: { newValue in
                if let newValue {
                    userStartIndex[item] = newValue
                } else {
                    userStartIndex.removeValue(forKey: item)
                }
            }
        )
    }

    // MARK: - Actions

    /// Opens the full-window lightbox for the given block. Cancels any pending
    /// auto-continue timer so the countdown doesn't fire while the user is studying
    /// the block — they'll explicitly resume with Space after closing.
    private func openLightbox(for block: PauseableBlock) {
        engine.cancelAutoContinueTimer()
        lightboxBlock = block
    }

    private func closeLightbox() {
        lightboxBlock = nil
    }

    private func loadFromURL() {
        guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isLoadingURL = true
        urlError = nil

        Task {
            do {
                let content = try await urlFetcher.fetchContent(from: urlText)
                await MainActor.run {
                    // Keep the RSVP stream aligned with the article preview. The preview renders
                    // extracted body blocks only; prepending the metadata title here shifts every
                    // highlighted/read word by the title length.
                    urlLoadedText = content.plainText
                    urlPauseableBlocks = content.pauseableBlocks
                    urlBlocks = content.blocks.isEmpty ? nil : content.blocks
                    urlTOC = content.toc
                    isLoadingURL = false
                    RecentURLsManager.shared.add(urlText, title: content.title)
                }
            } catch {
                await MainActor.run {
                    urlError = error.localizedDescription
                    isLoadingURL = false
                }
            }
        }
    }

    private func startReading() {
        let text = activeText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let fileResumeIndex = RecentFilesManager.shared.resumeWordIndex
        RecentFilesManager.shared.resumeWordIndex = nil

        if let fileResumeIndex {
            doStartReading(resumeFromIndex: fileResumeIndex, autoPlay: false)
            return
        }

        if let userIndex = userStartIndex[selectedItem] {
            doStartReading(resumeFromIndex: userIndex)
            userStartIndex.removeValue(forKey: selectedItem)
            return
        }

        if let savedIndex = sessionProgress[selectedItem], savedIndex > 0 {
            // Don't prompt if reading was already completed
            let totalWords = sessionTotalWords[selectedItem] ?? Int.max
            if savedIndex >= totalWords {
                sessionProgress.removeValue(forKey: selectedItem)
                doStartReading(resumeFromIndex: nil)
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                showContinuePrompt = true
            }
            return
        }

        doStartReading(resumeFromIndex: nil)
    }

    private func doStartReading(resumeFromIndex: Int?, autoPlay: Bool = true) {
        let text = activeText
        let pauseableBlocks = activePauseableBlocks
        let markdownSource = activeMarkdownSource
        let currentWPM = settings.wpm
        engine.currentSource = selectedItem.rawValue

        switch settings.readingMode {
        case .mainWindow:
            engine.loadText(text, pauseableBlocks: pauseableBlocks, markdownSource: markdownSource)
            if let resumeFromIndex {
                engine.seekTo(resumeFromIndex)
            }
            engine.setWPM(currentWPM)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                isReadingInline = true
            }
            if autoPlay {
                engine.play()
            }

        case .notch:
            isReadingExternal = true
            AppDelegate.shared?.startInWidget(text: text, wpm: currentWPM, resumeIndex: resumeFromIndex, autoPlay: autoPlay, pauseableBlocks: pauseableBlocks, markdownSource: markdownSource)

        case .separateWindow:
            isReadingExternal = true
            AppDelegate.shared?.startInSeparateWindow(text: text, wpm: currentWPM, resumeIndex: resumeFromIndex, autoPlay: autoPlay, pauseableBlocks: pauseableBlocks, markdownSource: markdownSource)

        case .zen:
            isReadingExternal = true
            AppDelegate.shared?.startInZen(text: text, wpm: currentWPM, resumeIndex: resumeFromIndex, autoPlay: autoPlay, pauseableBlocks: pauseableBlocks, markdownSource: markdownSource)
        }

        sessionProgress.removeValue(forKey: selectedItem)
        sessionTotalWords.removeValue(forKey: selectedItem)
    }

    private func saveSessionProgress() {
        guard !engine.isFinished, engine.currentIndex > 0 else { return }
        sessionProgress[selectedItem] = engine.currentIndex
        sessionTotalWords[selectedItem] = engine.totalWords

    }

    private func estimatedWordCount(for text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern, options: []) else {
            return text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        return matches.compactMap { Range($0.range, in: text) }.count
    }

    private func stopInlineReading() {
        saveSessionProgress()

        if selectedItem == .file, let file = RecentFilesManager.shared.currentFile {
            RecentFilesManager.shared.saveProgress(for: file, wordIndex: engine.currentIndex)
        }

        engine.pause()
        engine.restart()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            isReadingInline = false
        }
    }

}

// MARK: - Settings Overlay

struct SettingsOverlay: View {
    @Binding var isPresented: Bool
    @Binding var selectedTab: SettingsTab

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }

            SettingsContentView(selectedTab: $selectedTab, onDismiss: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPresented = false
                }
            })
            .frame(width: SettingsConstants.width, height: SettingsConstants.height)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 40, x: 0, y: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

#Preview {
    ContentView()
}
