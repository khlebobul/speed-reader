//
//  SettingsContentView.swift
//  SpeedReader
//
//  Settings view displayed as overlay in the main window
//

import SwiftUI
import ServiceManagement

struct SettingsContentView: View {
    @ObservedObject private var settings = ReaderSettings.shared
    @Binding var selectedTab: SettingsTab
    @State private var showResetConfirmation = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content
            HStack(spacing: 0) {
                // Settings Sidebar
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 16)
                                Text(tab.label)
                                    .font(.system(size: 13, weight: .regular))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(12)
                .frame(width: 150)
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(0.03))

                Divider()

                // Tab Content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        switch selectedTab {
                        case .general:
                            generalTab
                        case .appearance:
                            appearanceTab
                        case .notchWidget:
                            notchWidgetTab
                        case .separateWindow:
                            separateWindowTab
                        case .zenMode:
                            zenModeTab
                        }
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Footer
            HStack {
                Button("Reset All") {
                    showResetConfirmation = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Done") {
                    onDismiss?()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(12)
        }
        .onChange(of: selectedTab) { _, newTab in
            updatePreview(for: newTab)
        }
        .onAppear { updatePreview(for: selectedTab) }
        .onDisappear {
            AppDelegate.shared.hideNotchPreview()
            AppDelegate.shared.hideSeparateWindowPreview()
        }
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settings.resetToDefaults()
                }
            }
        } message: {
            Text("This will restore all settings to their defaults.")
        }
    }

    // MARK: - Preview

    private func updatePreview(for tab: SettingsTab) {
        switch tab {
        case .appearance, .notchWidget:
            AppDelegate.shared.hideSeparateWindowPreview()
            AppDelegate.shared.showNotchPreview()
        case .separateWindow:
            AppDelegate.shared.hideNotchPreview()
            AppDelegate.shared.showSeparateWindowPreview()
        default:
            AppDelegate.shared.hideNotchPreview()
            AppDelegate.shared.hideSeparateWindowPreview()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App Info
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Speed Reader")
                    .font(.system(size: 14, weight: .semibold))
                Text("Version \(Bundle.main.appVersionString) (\(Bundle.main.appBuildString))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Launch at Login
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Startup")
                        .font(.system(size: 13, weight: .medium))
                    Text("Automatically open Speed Reader when you log in.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            }

            Divider()

            // Speed
            VStack(alignment: .leading, spacing: 12) {
                Text("Reading Speed")
                    .font(.system(size: 13, weight: .medium))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Slider(value: Binding(
                            get: { Double(settings.wpm) },
                            set: { settings.wpm = Int($0) }
                        ), in: 100...1000, step: 50)

                        Text("\(settings.wpm)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 46, alignment: .trailing)

                        Text("WPM")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Slower")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("Faster")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Divider()

            // Reading Flow
            VStack(alignment: .leading, spacing: 12) {
                Text("Reading Flow")
                    .font(.system(size: 13, weight: .medium))

                Text("Pause on visual blocks the eye can't read at RSVP speed so you can study them before continuing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                pauseKindToggle(
                    title: "Images & diagrams",
                    subtitle: "Figures, charts, embedded pictures.",
                    isOn: $settings.autoPauseOnImages
                )

                pauseKindToggle(
                    title: "Formulas",
                    subtitle: "Math expressions in LaTeX or MathML.",
                    isOn: $settings.autoPauseOnFormulas
                )

                pauseKindToggle(
                    title: "Tables",
                    subtitle: "Tabular data that doesn't read sequentially.",
                    isOn: $settings.autoPauseOnTables
                )

                pauseKindToggle(
                    title: "Code blocks",
                    subtitle: "Source-code snippets. Off by default — many code blocks are short.",
                    isOn: $settings.autoPauseOnCode
                )

                Divider().padding(.vertical, 2)

                // Continue mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue mode")
                        .font(.system(size: 12, weight: .medium))

                    Picker("", selection: $settings.pauseContinueMode) {
                        ForEach(PauseContinueMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(settings.pauseContinueMode == .manual
                         ? "The player waits for Space (or a tap) before continuing."
                         : "The player resumes automatically after the view time below. Space still skips the wait.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if settings.pauseContinueMode == .timed {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("View time")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(settings.pauseDuration)) s")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Slider(
                            value: $settings.pauseDuration,
                            in: ReaderSettings.pauseDurationRange,
                            step: 1
                        )
                    }
                }

                Divider().padding(.vertical, 2)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show block in reader area")
                            .font(.system(size: 13, weight: .medium))
                        Text("Replace the placeholder word with a preview of the block during the pause.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.showImagePreviewInReader)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }

            Divider()

            // Updates
            Text("Updates")
                .font(.system(size: 13, weight: .medium))

            Button {
                UpdateManager.shared.checkForUpdates()
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 16)
                    Text("Check for Updates")
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!UpdateManager.shared.canCheckForUpdates)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic update notifications")
                        .font(.system(size: 13, weight: .medium))
                    Text("Get notified when a new version is available.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { UpdateManager.shared.updater.automaticallyChecksForUpdates },
                    set: { UpdateManager.shared.updater.automaticallyChecksForUpdates = $0 }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            footerLinks
                .padding(.top, 4)

            Spacer()
        }
    }

    private var footerLinks: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button("Email") {
                    openMailto(subject: "Speed Reader — Contact")
                }
                .buttonStyle(.link)

                Text("·").foregroundStyle(.tertiary)

                Button("Website") {
                    if let url = URL(string: "https://speed-reader.pro") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }

            HStack(spacing: 3) {
                Text("Made by").foregroundStyle(.secondary)
                Button("@khlebobul") {
                    if let url = URL(string: "https://x.com/khlebobul") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity)
    }

    private func openMailto(subject: String) {
        if let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "mailto:khlebobul@gmail.com?subject=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func pauseKindToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    // MARK: - Appearance Tab

    private var fontFamilySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font")
                .font(.system(size: 13, weight: .medium))

            HStack(spacing: 8) {
                ForEach(FontFamilyPreset.allCases) { preset in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.fontFamilyPreset = preset
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Text("Ag")
                                .font(preset.font(size: 18))
                                .foregroundStyle(settings.fontFamilyPreset == preset ? Color.accentColor : .primary)
                            Text(preset.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(settings.fontFamilyPreset == preset ? Color.accentColor : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(settings.fontFamilyPreset == preset ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.fontFamilyPreset == preset ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Size")
                .font(.system(size: 13, weight: .medium))

            HStack(spacing: 8) {
                ForEach(FontSizePreset.allCases) { preset in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.fontSizePreset = preset
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Text("Ag")
                                .font(settings.fontFamilyPreset.font(size: preset.pointSize * 0.5))
                                .foregroundStyle(settings.fontSizePreset == preset ? Color.accentColor : .primary)
                            Text(preset.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(settings.fontSizePreset == preset ? Color.accentColor : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(settings.fontSizePreset == preset ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.fontSizePreset == preset ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var orpColorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ORP Highlight Color")
                .font(.system(size: 13, weight: .medium))

            HStack(spacing: 8) {
                ForEach(ORPColorPreset.allCases) { preset in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.orpColorPreset = preset
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                                .overlay(
                                    settings.orpColorPreset == preset
                                        ? Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                        : nil
                                )
                            Text(preset.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(settings.orpColorPreset == preset ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(settings.orpColorPreset == preset ? preset.color.opacity(0.1) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.orpColorPreset == preset ? preset.color.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var highlightColorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlight Color")
                .font(.system(size: 13, weight: .medium))

            HStack(spacing: 8) {
                ForEach(HighlightColorPreset.allCases) { preset in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.highlightColorPreset = preset
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                                .overlay(
                                    settings.highlightColorPreset == preset
                                        ? Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                        : nil
                                )
                            Text(preset.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(settings.highlightColorPreset == preset ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(settings.highlightColorPreset == preset ? preset.color.opacity(0.1) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.highlightColorPreset == preset ? preset.color.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            fontFamilySection

            Divider()

            fontSizeSection

            Divider()

            orpColorSection

            Divider()

            // Text Highlight
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text highlight")
                        .font(.system(size: 13, weight: .medium))
                    Text("Highlight the current word in the source text during reading.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.highlightEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if settings.highlightEnabled {
                highlightColorSection
            }

            Divider()

            // ORP Indicators
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ORP indicators")
                        .font(.system(size: 13, weight: .medium))
                    Text("Show top and bottom guide lines aligned to the pivot letter.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.showORPIndicators)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            // Theme
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme")
                    .font(.system(size: 13, weight: .medium))

                Picker("", selection: $settings.themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Spacer()
        }
    }

    // MARK: - Notch Widget Tab

    private var notchWidgetTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure how the notch widget behaves during reading.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            // Dimensions
            VStack(alignment: .leading, spacing: 10) {
                Text("Dimensions")
                    .font(.system(size: 13, weight: .medium))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Width")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(settings.notchExpandedWidth)) pt")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Slider(
                        value: $settings.notchExpandedWidth,
                        in: ReaderSettings.notchMinWidth...ReaderSettings.notchMaxWidth,
                        step: 10
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Height")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(settings.notchExpandedHeight)) pt")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Slider(
                        value: $settings.notchExpandedHeight,
                        in: ReaderSettings.notchMinHeight...ReaderSettings.notchMaxHeight,
                        step: 10
                    )
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show progress bar")
                        .font(.system(size: 13, weight: .medium))
                    Text("Display reading progress at the bottom of the widget.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.showProgressBar)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Celebration on finish")
                        .font(.system(size: 13, weight: .medium))
                    Text("Show confetti animation when reading completes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.celebrationOnFinish)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Spacer()
        }
    }

    // MARK: - Separate Window Tab

    private var separateWindowTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure the floating reader window behavior.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always on top")
                        .font(.system(size: 13, weight: .medium))
                    Text("Keep the reader window above other windows.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.separateWindowAlwaysOnTop)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Window opacity")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(settings.separateWindowOpacity * 100))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Slider(
                    value: $settings.separateWindowOpacity,
                    in: 0.5...1.0,
                    step: 0.05
                )

                HStack {
                    Text("Translucent")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("Opaque")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember position")
                        .font(.system(size: 13, weight: .medium))
                    Text("Restore window position when reopening.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.separateWindowRememberPosition)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Spacer()
        }
    }

    // MARK: - Zen Mode Tab

    private var zenModeTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure the full-screen distraction-free reading mode.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font size")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(settings.zenFontSize)) pt")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Slider(
                    value: $settings.zenFontSize,
                    in: ReaderSettings.zenMinFontSize...ReaderSettings.zenMaxFontSize,
                    step: 2
                )
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Words at a time")
                        .font(.system(size: 13, weight: .medium))
                    Text("Show 1–7 words per beat. ORP applies only to the first word of each chunk.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(
                    value: $settings.zenWordsPerChunk,
                    in: 1...7,
                    step: 1
                ) {
                    Text("\(settings.zenWordsPerChunk)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 16, alignment: .trailing)
                }
                .controlSize(.small)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show upcoming words")
                        .font(.system(size: 13, weight: .medium))
                    Text("Display the next ~60 words below the current word.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.zenShowContext)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show previous words")
                        .font(.system(size: 13, weight: .medium))
                    Text("Display the five words before the current RSVP position.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.zenShowPreviousContext)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-hide UI")
                        .font(.system(size: 13, weight: .medium))
                    Text("Hide controls after 2 seconds of inactivity while reading.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.zenAutoHideUI)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loop")
                        .font(.system(size: 13, weight: .medium))
                    Text("When the article ends, restart from the beginning instead of stopping.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.zenLoop)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Spacer()
        }
    }
}

#Preview {
    SettingsContentView(selectedTab: .constant(.general), onDismiss: {})
        .frame(width: SettingsConstants.width, height: SettingsConstants.height)
        .background(.ultraThinMaterial)
}
