//
//  ReaderSettings.swift
//  SpeedReader
//
//  Created on 20.02.2026.
//

import SwiftUI
import AppKit

// MARK: - Reading Mode

enum ReadingMode: String, CaseIterable, Identifiable {
    case mainWindow
    case notch
    case separateWindow
    case zen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mainWindow: return "Main Window"
        case .notch: return "Notch"
        case .separateWindow: return "Separate"
        case .zen: return "Zen"
        }
    }

    var icon: String {
        switch self {
        case .mainWindow: return "rectangle.inset.filled"
        case .notch: return "rectangle.topthird.inset.filled"
        case .separateWindow: return "macwindow"
        case .zen: return "leaf.fill"
        }
    }

    var description: String {
        switch self {
        case .mainWindow: return "Read in the main app window"
        case .notch: return "Minimal widget around the notch"
        case .separateWindow: return "Floating window, always on top"
        case .zen: return "Full-screen distraction-free reading"
        }
    }
}

// MARK: - Font Size Preset

enum FontSizePreset: String, CaseIterable, Identifiable {
    case sm, md, lg, xl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sm: return "SM"
        case .md: return "MD"
        case .lg: return "LG"
        case .xl: return "XL"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .sm: return 24
        case .md: return 32
        case .lg: return 40
        case .xl: return 48
        }
    }

    var notchPointSize: CGFloat {
        switch self {
        case .sm: return 20
        case .md: return 26
        case .lg: return 32
        case .xl: return 38
        }
    }
}

// MARK: - Font Family Preset

enum FontFamilyPreset: String, CaseIterable, Identifiable {
    case sans, serif, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans: return "Sans"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        switch self {
        case .sans:
            return .system(size: size, weight: weight, design: .default)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .mono:
            return .system(size: size, weight: weight, design: .monospaced)
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch self {
        case .sans:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .serif:
            return NSFont(name: "NewYork", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

}

// MARK: - ORP Color Preset

enum ORPColorPreset: String, CaseIterable, Identifiable {
    case accent, red, yellow, green, blue, purple

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .accent: return Color.accentColor
        case .red: return Color(red: 0.92, green: 0.26, blue: 0.24)
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.04)
        case .green: return Color(red: 0.2, green: 0.78, blue: 0.35)
        case .blue: return Color(red: 0.0, green: 0.48, blue: 1.0)
        case .purple: return Color(red: 0.69, green: 0.32, blue: 0.87)
        }
    }

    var label: String {
        switch self {
        case .accent: return "Accent"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }
}

// MARK: - Highlight Color Preset

enum HighlightColorPreset: String, CaseIterable, Identifiable {
    case accent, red, yellow, green, blue, purple

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .accent: return Color.accentColor
        case .red: return Color(red: 0.92, green: 0.26, blue: 0.24)
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.04)
        case .green: return Color(red: 0.2, green: 0.78, blue: 0.35)
        case .blue: return Color(red: 0.0, green: 0.48, blue: 1.0)
        case .purple: return Color(red: 0.69, green: 0.32, blue: 0.87)
        }
    }

    var label: String {
        switch self {
        case .accent: return "Accent"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    /// Alpha applied to the preset's base color when used as a background fill.
    /// Yellow needs more opacity than the others to read on a white page.
    var backgroundAlpha: CGFloat {
        switch self {
        case .yellow: return 0.45
        default: return 0.35
        }
    }

    /// sRGB components of the preset's base color, in `0…1`. For `.accent` reads the
    /// current `NSColor.controlAccentColor` so the value tracks macOS appearance.
    var sRGBComponents: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .accent:
            let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
            return (c.redComponent, c.greenComponent, c.blueComponent)
        case .red: return (0.92, 0.26, 0.24)
        case .yellow: return (1.0, 0.84, 0.04)
        case .green: return (0.2, 0.78, 0.35)
        case .blue: return (0.0, 0.48, 1.0)
        case .purple: return (0.69, 0.32, 0.87)
        }
    }

    var cssRGBA: String {
        let c = sRGBComponents
        return "rgba(\(Int(c.r * 255)),\(Int(c.g * 255)),\(Int(c.b * 255)),\(backgroundAlpha))"
    }

    var nsColor: NSColor {
        let c = sRGBComponents
        return NSColor(red: c.r, green: c.g, blue: c.b, alpha: backgroundAlpha)
    }
}

// MARK: - Highlight Role / Style

/// Visual roles for word-level highlights. Mapped to a concrete background, border,
/// and weight by `HighlightStyle` — single source of truth across SwiftUI, AppKit,
/// WKWebView CSS, and PDFKit.
enum HighlightRole {
    /// The word currently shown by the RSVP engine (live reading).
    case readingActive
    /// The word selected as the start position (Read-from-here / TOC click / mouse click).
    case startMarker
    /// A non-active ⌘F search hit.
    case searchMatch
    /// The active ⌘F search hit (N of M).
    case searchActive
}

/// Resolves a `HighlightRole` to platform-specific style primitives. Geometry is
/// shared; colors come from the user's `HighlightColorPreset` for reading/start
/// roles and a fixed yellow/orange for search roles so a search hit never collides
/// with the reading highlight — even when the user picks the yellow preset.
enum HighlightStyle {
    /// Shared geometry, used by every backend that can render a rounded background
    /// (SwiftUI, WKWebView CSS, PDFKit annotation insets). NSTextView opts out —
    /// `addTemporaryAttribute(.backgroundColor)` can only paint a flat fill.
    static let cornerRadius: CGFloat = 3
    static let paddingH: CGFloat = 2
    static let paddingV: CGFloat = 1

    // Fixed search palette — independent of the user's highlight preset.
    private static let searchMatchRGB: (r: Int, g: Int, b: Int) = (255, 214, 10)
    private static let searchActiveRGB: (r: Int, g: Int, b: Int) = (255, 140, 0)
    private static let searchMatchAlpha: CGFloat = 0.55
    private static let searchActiveAlpha: CGFloat = 0.55
    /// Saturation applied to the preset's hue for the start-marker outline and to
    /// the orange used for the active search border — high enough to read as a
    /// "frame," not as another translucent fill.
    private static let borderAlpha: CGFloat = 0.95

    // MARK: - SwiftUI

    static func color(for role: HighlightRole) -> Color {
        switch role {
        case .readingActive, .startMarker:
            let preset = ReaderSettings.shared.highlightColorPreset
            return preset.color.opacity(preset.backgroundAlpha)
        case .searchMatch:
            return swiftUIColor(rgb: searchMatchRGB, alpha: searchMatchAlpha)
        case .searchActive:
            return swiftUIColor(rgb: searchActiveRGB, alpha: searchActiveAlpha)
        }
    }

    static func swiftUIBorder(for role: HighlightRole) -> (color: Color, width: CGFloat)? {
        switch role {
        case .readingActive, .searchMatch:
            return nil
        case .startMarker:
            let preset = ReaderSettings.shared.highlightColorPreset
            return (preset.color.opacity(borderAlpha), 1)
        case .searchActive:
            return (swiftUIColor(rgb: searchActiveRGB, alpha: 1), 1.5)
        }
    }

    // MARK: - AppKit

    static func nsColor(for role: HighlightRole) -> NSColor {
        switch role {
        case .readingActive, .startMarker:
            return ReaderSettings.shared.highlightColorPreset.nsColor
        case .searchMatch:
            return nsColor(rgb: searchMatchRGB, alpha: searchMatchAlpha)
        case .searchActive:
            return nsColor(rgb: searchActiveRGB, alpha: searchActiveAlpha)
        }
    }

    /// Solid (alpha-1 within `borderAlpha` saturation) variant of the role's
    /// colour. Used by PDFKit's `.square` annotation, where stroke is the only
    /// way to draw a real border on a page — see `PDFSearchTarget`.
    static func nsBorderColor(for role: HighlightRole) -> NSColor {
        switch role {
        case .readingActive, .searchMatch:
            return nsColor(for: role)
        case .startMarker:
            let c = ReaderSettings.shared.highlightColorPreset.sRGBComponents
            return NSColor(red: c.r, green: c.g, blue: c.b, alpha: borderAlpha)
        case .searchActive:
            return nsColor(rgb: searchActiveRGB, alpha: 1)
        }
    }

    /// Attributes for NSTextView temporary-attribute paths that can't draw a
    /// real border on a character range without a custom layout manager — the
    /// border role is conveyed via a thick coloured underline instead.
    static func nsBorderAttributes(for role: HighlightRole) -> [NSAttributedString.Key: Any] {
        switch role {
        case .readingActive, .searchMatch:
            return [:]
        case .startMarker:
            let preset = ReaderSettings.shared.highlightColorPreset
            let c = preset.sRGBComponents
            let solid = NSColor(red: c.r, green: c.g, blue: c.b, alpha: borderAlpha)
            return [
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: solid,
            ]
        case .searchActive:
            return [
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: nsColor(rgb: searchActiveRGB, alpha: 1),
            ]
        }
    }

    // MARK: - WKWebView CSS

    static func cssBackground(for role: HighlightRole) -> String {
        switch role {
        case .readingActive, .startMarker:
            return ReaderSettings.shared.highlightColorPreset.cssRGBA
        case .searchMatch:
            return cssRGBA(rgb: searchMatchRGB, alpha: searchMatchAlpha)
        case .searchActive:
            return cssRGBA(rgb: searchActiveRGB, alpha: searchActiveAlpha)
        }
    }

    static func cssBorder(for role: HighlightRole) -> String? {
        switch role {
        case .readingActive, .searchMatch:
            return nil
        case .startMarker:
            let preset = ReaderSettings.shared.highlightColorPreset
            let c = preset.sRGBComponents
            let rgb = (r: Int(c.r * 255), g: Int(c.g * 255), b: Int(c.b * 255))
            return "1px solid \(cssRGBA(rgb: rgb, alpha: borderAlpha))"
        case .searchActive:
            return "1.5px solid \(cssRGBA(rgb: searchActiveRGB, alpha: 1))"
        }
    }

    static func isBold(for role: HighlightRole) -> Bool {
        role == .searchActive
    }

    /// Inline-style declaration ready to drop into `el.style.cssText = '...'`
    /// inside Swift-generated JS. Composes background, geometry, optional border,
    /// and bold weight so every WK-preview paint path shares one source of truth.
    static func cssDeclaration(for role: HighlightRole) -> String {
        var parts = [
            "background:\(cssBackground(for: role))",
            "border-radius:\(Int(cornerRadius))px",
            "padding:\(Int(paddingV))px \(Int(paddingH))px",
        ]
        if let border = cssBorder(for: role) {
            parts.append("border:\(border)")
        }
        if isBold(for: role) {
            parts.append("font-weight:600")
        }
        return parts.joined(separator: ";")
    }

    /// CSS class name used to mark a word-level highlight in the WK preview DOM.
    /// One class per role keeps cleanup queries unambiguous.
    static func cssClass(for role: HighlightRole) -> String {
        switch role {
        case .readingActive: return "rsvp-hl"
        case .startMarker: return "rsvp-start-word"
        case .searchMatch, .searchActive: return "rsvp-search"
        }
    }

    /// Selector that matches every word-level highlight span produced by Swift,
    /// regardless of role — used by cleanup paths in the WK preview JS.
    static let highlightSpanSelector = ".rsvp-hl, .rsvp-start-word"

    // MARK: - Private helpers

    private static func swiftUIColor(rgb: (r: Int, g: Int, b: Int), alpha: CGFloat) -> Color {
        Color(red: Double(rgb.r) / 255,
              green: Double(rgb.g) / 255,
              blue: Double(rgb.b) / 255)
            .opacity(alpha)
    }

    private static func nsColor(rgb: (r: Int, g: Int, b: Int), alpha: CGFloat) -> NSColor {
        NSColor(red: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: alpha)
    }

    private static func cssRGBA(rgb: (r: Int, g: Int, b: Int), alpha: CGFloat) -> String {
        "rgba(\(rgb.r),\(rgb.g),\(rgb.b),\(alpha))"
    }
}

// MARK: - Pause Continue Mode

/// How the RSVP engine continues after auto-pausing on a pause-worthy block.
/// `.manual` waits for an explicit Space/tap. `.timed` waits for `pauseDuration`
/// seconds and continues automatically; Space still works as a "skip the wait" shortcut.
enum PauseContinueMode: String, CaseIterable, Identifiable {
    case manual, timed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Wait for me"
        case .timed:  return "Auto-continue"
        }
    }
}

// MARK: - Theme Mode

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Reader Settings

class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    // MARK: - Reading Mode

    @Published var readingMode: ReadingMode {
        didSet { UserDefaults.standard.set(readingMode.rawValue, forKey: "readingMode") }
    }

    // MARK: - Reading

    @Published var wpm: Int {
        didSet { UserDefaults.standard.set(wpm, forKey: "wpm") }
    }

    @Published var fontSizePreset: FontSizePreset {
        didSet { UserDefaults.standard.set(fontSizePreset.rawValue, forKey: "fontSizePreset") }
    }

    @Published var fontFamilyPreset: FontFamilyPreset {
        didSet { UserDefaults.standard.set(fontFamilyPreset.rawValue, forKey: "fontFamilyPreset") }
    }

    @Published var orpColorPreset: ORPColorPreset {
        didSet { UserDefaults.standard.set(orpColorPreset.rawValue, forKey: "orpColorPreset") }
    }

    @Published var highlightEnabled: Bool {
        didSet { UserDefaults.standard.set(highlightEnabled, forKey: "highlightEnabled") }
    }

    @Published var highlightColorPreset: HighlightColorPreset {
        didSet { UserDefaults.standard.set(highlightColorPreset.rawValue, forKey: "highlightColorPreset") }
    }

    // MARK: - Reading Flow

    /// When true, the RSVP engine pauses on every image-placeholder beat that has a
    /// known image ref so the user can study the figure before pressing Space to
    /// continue. Affects every reading mode.
    @Published var autoPauseOnImages: Bool {
        didSet { UserDefaults.standard.set(autoPauseOnImages, forKey: "autoPauseOnImages") }
    }

    /// Same as `autoPauseOnImages` for math formulas. No producer wired today —
    /// flag persists for forward compatibility (Phase 3).
    @Published var autoPauseOnFormulas: Bool {
        didSet { UserDefaults.standard.set(autoPauseOnFormulas, forKey: "autoPauseOnFormulas") }
    }

    /// Same as `autoPauseOnImages` for tables. No producer wired today —
    /// flag persists for forward compatibility (Phase 4).
    @Published var autoPauseOnTables: Bool {
        didSet { UserDefaults.standard.set(autoPauseOnTables, forKey: "autoPauseOnTables") }
    }

    /// Same as `autoPauseOnImages` for code blocks. Defaults off — code blocks
    /// are often short and pausing on each is noisy (Phase 5).
    @Published var autoPauseOnCode: Bool {
        didSet { UserDefaults.standard.set(autoPauseOnCode, forKey: "autoPauseOnCode") }
    }

    /// When true, during an image auto-pause the reader area replaces the ORP word
    /// display with a thumbnail of the image. When false, the placeholder word
    /// "image" stays visible — useful in modes where the thumbnail wouldn't fit
    /// (notch, very small windows).
    @Published var showImagePreviewInReader: Bool {
        didSet { UserDefaults.standard.set(showImagePreviewInReader, forKey: "showImagePreviewInReader") }
    }

    /// Whether the engine waits for an explicit Space/tap to continue after an
    /// auto-pause, or auto-continues after `pauseDuration` seconds.
    @Published var pauseContinueMode: PauseContinueMode {
        didSet { UserDefaults.standard.set(pauseContinueMode.rawValue, forKey: "pauseContinueMode") }
    }

    /// Seconds the engine waits before auto-continuing in `.timed` mode.
    /// Clamped to `pauseDurationRange` on read/write.
    @Published var pauseDuration: Double {
        didSet {
            let clamped = Self.clampPauseDuration(pauseDuration)
            if clamped != pauseDuration {
                pauseDuration = clamped
                return
            }
            UserDefaults.standard.set(pauseDuration, forKey: "pauseDuration")
        }
    }

    /// Whether the engine should auto-pause on a given block kind. Single source of
    /// truth used by `RSVPEngine.currentPauseableBlock` so views and the engine agree.
    func isAutoPauseEnabled(for kind: BlockKind) -> Bool {
        switch kind {
        case .image:   return autoPauseOnImages
        case .formula: return autoPauseOnFormulas
        case .table:   return autoPauseOnTables
        case .code:    return autoPauseOnCode
        }
    }

    static let pauseDurationRange: ClosedRange<Double> = 2...15
    static let defaultPauseDuration: Double = 5

    private static func clampPauseDuration(_ value: Double) -> Double {
        min(max(value, pauseDurationRange.lowerBound), pauseDurationRange.upperBound)
    }

    // MARK: - Notch Widget

    @Published var notchExpandedWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(notchExpandedWidth), forKey: "notchExpandedWidth") }
    }

    @Published var notchExpandedHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(notchExpandedHeight), forKey: "notchExpandedHeight") }
    }

    static let notchDefaultWidth: CGFloat = 400
    static let notchDefaultHeight: CGFloat = 260
    static let notchMinWidth: CGFloat = 300
    static let notchMaxWidth: CGFloat = 520
    static let notchMinHeight: CGFloat = 180
    static let notchMaxHeight: CGFloat = 400

    @Published var showProgressBar: Bool {
        didSet { UserDefaults.standard.set(showProgressBar, forKey: "showProgressBar") }
    }

    @Published var celebrationOnFinish: Bool {
        didSet { UserDefaults.standard.set(celebrationOnFinish, forKey: "celebrationOnFinish") }
    }

    // MARK: - Separate Window

    @Published var separateWindowAlwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(separateWindowAlwaysOnTop, forKey: "separateWindowAlwaysOnTop") }
    }

    @Published var separateWindowOpacity: Double {
        didSet { UserDefaults.standard.set(separateWindowOpacity, forKey: "separateWindowOpacity") }
    }

    @Published var separateWindowRememberPosition: Bool {
        didSet { UserDefaults.standard.set(separateWindowRememberPosition, forKey: "separateWindowRememberPosition") }
    }

    // MARK: - Zen Mode

    @Published var zenFontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(zenFontSize), forKey: "zenFontSize") }
    }

    @Published var zenShowContext: Bool {
        didSet { UserDefaults.standard.set(zenShowContext, forKey: "zenShowContext") }
    }

    @Published var zenShowPreviousContext: Bool {
        didSet { UserDefaults.standard.set(zenShowPreviousContext, forKey: "zenShowPreviousContext") }
    }

    @Published var zenAutoHideUI: Bool {
        didSet { UserDefaults.standard.set(zenAutoHideUI, forKey: "zenAutoHideUI") }
    }

    @Published var zenLoop: Bool {
        didSet { UserDefaults.standard.set(zenLoop, forKey: "zenLoop") }
    }

    @Published var zenWordsPerChunk: Int {
        didSet {
            let clamped = max(1, min(7, zenWordsPerChunk))
            if clamped != zenWordsPerChunk {
                zenWordsPerChunk = clamped
                return
            }
            UserDefaults.standard.set(zenWordsPerChunk, forKey: "zenWordsPerChunk")
        }
    }

    static let zenDefaultFontSize: CGFloat = 56
    static let zenMinFontSize: CGFloat = 24
    static let zenMaxFontSize: CGFloat = 96

    // MARK: - OCR

    @Published var ocrQuality: OCREngine.Options.Quality {
        didSet { UserDefaults.standard.set(ocrQuality.rawValue, forKey: "ocrQuality") }
    }

    @Published var ocrAutoRecognize: Bool {
        didSet { UserDefaults.standard.set(ocrAutoRecognize, forKey: "ocrAutoRecognize") }
    }

    var ocrOptions: OCREngine.Options {
        var opts = OCREngine.Options()
        opts.quality = ocrQuality
        return opts
    }

    // MARK: - Appearance

    @Published var showORPIndicators: Bool {
        didSet { UserDefaults.standard.set(showORPIndicators, forKey: "showORPIndicators") }
    }

    @Published var themeMode: ThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: "themeMode")
            applyTheme()
        }
    }

    // MARK: - Computed Properties

    var font: Font {
        fontFamilyPreset.font(size: fontSizePreset.pointSize)
    }

    var notchFont: Font {
        fontFamilyPreset.font(size: fontSizePreset.notchPointSize)
    }

    var orpColor: Color {
        orpColorPreset.color
    }

    var highlightColor: Color {
        highlightColorPreset.color
    }

    // MARK: - Defaults

    static let defaultWPM = 300
    static let defaultFontSize: FontSizePreset = .md
    static let defaultFontFamily: FontFamilyPreset = .sans
    static let defaultORPColor: ORPColorPreset = .accent
    static let defaultHighlightColor: HighlightColorPreset = .accent
    static let defaultTheme: ThemeMode = .system
    static let defaultReadingMode: ReadingMode = .mainWindow

    // MARK: - Init

    init() {
        // Reading Mode
        let savedMode = UserDefaults.standard.string(forKey: "readingMode") ?? ""
        self.readingMode = ReadingMode(rawValue: savedMode) ?? Self.defaultReadingMode

        // Reading
        let savedWPM = UserDefaults.standard.integer(forKey: "wpm")
        self.wpm = savedWPM > 0 ? savedWPM : Self.defaultWPM

        let savedFontSize = UserDefaults.standard.string(forKey: "fontSizePreset") ?? ""
        self.fontSizePreset = FontSizePreset(rawValue: savedFontSize) ?? Self.defaultFontSize

        let savedFontFamily = UserDefaults.standard.string(forKey: "fontFamilyPreset") ?? ""
        self.fontFamilyPreset = FontFamilyPreset(rawValue: savedFontFamily) ?? Self.defaultFontFamily

        let savedORPColor = UserDefaults.standard.string(forKey: "orpColorPreset") ?? ""
        self.orpColorPreset = ORPColorPreset(rawValue: savedORPColor) ?? Self.defaultORPColor

        self.highlightEnabled = UserDefaults.standard.object(forKey: "highlightEnabled") as? Bool ?? true
        let savedHighlightColor = UserDefaults.standard.string(forKey: "highlightColorPreset") ?? ""
        self.highlightColorPreset = HighlightColorPreset(rawValue: savedHighlightColor) ?? Self.defaultHighlightColor
        // Reading Flow
        self.autoPauseOnImages = UserDefaults.standard.object(forKey: "autoPauseOnImages") as? Bool ?? true
        self.autoPauseOnFormulas = UserDefaults.standard.object(forKey: "autoPauseOnFormulas") as? Bool ?? true
        self.autoPauseOnTables = UserDefaults.standard.object(forKey: "autoPauseOnTables") as? Bool ?? true
        self.autoPauseOnCode = UserDefaults.standard.object(forKey: "autoPauseOnCode") as? Bool ?? false
        self.showImagePreviewInReader = UserDefaults.standard.object(forKey: "showImagePreviewInReader") as? Bool ?? true
        let savedContinueMode = UserDefaults.standard.string(forKey: "pauseContinueMode") ?? ""
        self.pauseContinueMode = PauseContinueMode(rawValue: savedContinueMode) ?? .manual
        let savedDuration = UserDefaults.standard.object(forKey: "pauseDuration") as? Double
        self.pauseDuration = Self.clampPauseDuration(savedDuration ?? Self.defaultPauseDuration)

        // Notch Widget
        let savedNotchW = UserDefaults.standard.double(forKey: "notchExpandedWidth")
        self.notchExpandedWidth = savedNotchW > 0 ? CGFloat(savedNotchW) : Self.notchDefaultWidth
        let savedNotchH = UserDefaults.standard.double(forKey: "notchExpandedHeight")
        self.notchExpandedHeight = savedNotchH > 0 ? CGFloat(savedNotchH) : Self.notchDefaultHeight
        self.showProgressBar = UserDefaults.standard.object(forKey: "showProgressBar") as? Bool ?? true
        self.celebrationOnFinish = UserDefaults.standard.object(forKey: "celebrationOnFinish") as? Bool ?? true

        // Zen Mode
        let savedZenFontSize = UserDefaults.standard.double(forKey: "zenFontSize")
        self.zenFontSize = savedZenFontSize > 0 ? CGFloat(savedZenFontSize) : Self.zenDefaultFontSize
        self.zenShowContext = UserDefaults.standard.object(forKey: "zenShowContext") as? Bool ?? true
        self.zenShowPreviousContext = UserDefaults.standard.object(forKey: "zenShowPreviousContext") as? Bool ?? true
        self.zenAutoHideUI = UserDefaults.standard.object(forKey: "zenAutoHideUI") as? Bool ?? false
        self.zenLoop = UserDefaults.standard.object(forKey: "zenLoop") as? Bool ?? false
        let savedZenChunk = UserDefaults.standard.integer(forKey: "zenWordsPerChunk")
        self.zenWordsPerChunk = savedZenChunk > 0 ? max(1, min(7, savedZenChunk)) : 1

        // OCR
        let savedOCRQuality = UserDefaults.standard.string(forKey: "ocrQuality") ?? ""
        self.ocrQuality = OCREngine.Options.Quality(rawValue: savedOCRQuality) ?? .accurate
        self.ocrAutoRecognize = UserDefaults.standard.object(forKey: "ocrAutoRecognize") as? Bool ?? false

        // Separate Window
        self.separateWindowAlwaysOnTop = UserDefaults.standard.object(forKey: "separateWindowAlwaysOnTop") as? Bool ?? true
        let savedOpacity = UserDefaults.standard.double(forKey: "separateWindowOpacity")
        self.separateWindowOpacity = savedOpacity > 0 ? savedOpacity : 1.0
        self.separateWindowRememberPosition = UserDefaults.standard.object(forKey: "separateWindowRememberPosition") as? Bool ?? true

        // Appearance
        self.showORPIndicators = UserDefaults.standard.object(forKey: "showORPIndicators") as? Bool ?? true
        let savedTheme = UserDefaults.standard.string(forKey: "themeMode") ?? ""
        self.themeMode = ThemeMode(rawValue: savedTheme) ?? Self.defaultTheme

        // Migrate old defaultWPM if exists
        migrateOldSettings()

        // Apply saved theme
        applyTheme()
    }

    // MARK: - Theme

    func applyTheme() {
        NSApp.appearance = themeMode.nsAppearance
    }

    // MARK: - Migration

    private func migrateOldSettings() {
        // Migrate from old "defaultWPM" key
        if UserDefaults.standard.object(forKey: "wpm") == nil {
            let oldWPM = UserDefaults.standard.integer(forKey: "defaultWPM")
            if oldWPM > 0 {
                self.wpm = oldWPM
            }
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        readingMode = Self.defaultReadingMode
        wpm = Self.defaultWPM
        fontSizePreset = Self.defaultFontSize
        fontFamilyPreset = Self.defaultFontFamily
        orpColorPreset = Self.defaultORPColor
        highlightEnabled = true
        highlightColorPreset = Self.defaultHighlightColor
        autoPauseOnImages = true
        autoPauseOnFormulas = true
        autoPauseOnTables = true
        autoPauseOnCode = false
        showImagePreviewInReader = true
        pauseContinueMode = .manual
        pauseDuration = Self.defaultPauseDuration
        notchExpandedWidth = Self.notchDefaultWidth
        notchExpandedHeight = Self.notchDefaultHeight
        showProgressBar = true
        celebrationOnFinish = true
        zenFontSize = Self.zenDefaultFontSize
        zenShowContext = true
        zenAutoHideUI = false
        zenLoop = false
        zenWordsPerChunk = 1
        separateWindowAlwaysOnTop = true
        separateWindowOpacity = 1.0
        separateWindowRememberPosition = true
        ocrQuality = .accurate
        ocrAutoRecognize = false
        showORPIndicators = true
        themeMode = Self.defaultTheme
        // themeMode didSet will call applyTheme()
    }
}
