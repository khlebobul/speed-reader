import SwiftUI

/// Routes a `PauseableBlock` to the right preview renderer. New block kinds (formula,
/// table, code) currently fall back to a stub that shows the block kind name + caption
/// — enough to exercise the UI plumbing until dedicated producers and renderers
/// land in later phases.
struct RSVPBlockPreviewView: View {
    let block: PauseableBlock
    var style: RSVPImagePreviewView.Style = .full
    var dark: Bool = false
    var maxWidth: CGFloat = 380
    var maxHeight: CGFloat = 220
    var compactWordSize: CGFloat = 32
    /// When non-nil, the preview shows a countdown to auto-continue instead of the
    /// "Press Space to continue" hint. Caller passes `engine.autoContinueDeadline`.
    var autoContinueDeadline: Date? = nil
    var onContinue: () -> Void
    /// When non-nil and the style is `.full`, a tap on the thumbnail opens the
    /// lightbox via this callback instead of continuing playback. The caller is
    /// responsible for cancelling the engine's auto-continue timer at that point —
    /// otherwise the countdown will fire while the lightbox is open.
    var onOpen: (() -> Void)? = nil

    var body: some View {
        switch block {
        case .image(let ref):
            RSVPImagePreviewView(
                image: ref,
                style: style,
                dark: dark,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                compactWordSize: compactWordSize,
                autoContinueDeadline: autoContinueDeadline,
                onContinue: onContinue,
                onOpen: onOpen
            )
        case .formula(let latex, let caption):
            FormulaPreview(
                latex: latex,
                caption: caption,
                style: style,
                dark: dark,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                compactWordSize: compactWordSize,
                autoContinueDeadline: autoContinueDeadline,
                onContinue: onContinue,
                onOpen: onOpen
            )
        case .table(let html, _, let caption):
            TablePreview(
                html: html,
                caption: caption,
                style: style,
                dark: dark,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                compactWordSize: compactWordSize,
                autoContinueDeadline: autoContinueDeadline,
                onContinue: onContinue,
                onOpen: onOpen
            )
        case .code(let language, let source):
            CodePreview(
                source: source,
                language: language,
                style: style,
                dark: dark,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                compactWordSize: compactWordSize,
                autoContinueDeadline: autoContinueDeadline,
                onContinue: onContinue,
                onOpen: onOpen
            )
        }
    }
}

/// Code-block renderer for the paused-block area. Mirrors `FormulaPreview` /
/// `TablePreview` — `.full` shows the syntax-highlighted source via
/// `CodePreviewView` (highlight.js), `.compact` falls back to the stub for
/// Notch / Separate. Default toggle for code is off (Phase 1 design — code
/// pauses are opt-in because most code blocks are short).
struct CodePreview: View {
    let source: String
    let language: String?
    var style: RSVPImagePreviewView.Style
    var dark: Bool
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var compactWordSize: CGFloat
    var autoContinueDeadline: Date?
    var onContinue: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        switch style {
        case .full:    fullBody
        case .compact: compactBody
        }
    }

    private var fullBody: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                CodePreviewView(source: source, language: language, dark: dark)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(strokeColor, lineWidth: 1)
                    )

                if onOpen != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { handleTap() }
            .help(onOpen != nil ? "Click to enlarge · Space to continue" : "Press Space to continue")

            ContinueHint(deadline: autoContinueDeadline, dark: dark, showOpenAffordance: onOpen != nil)

            AutoContinueProgressBar(
                deadline: autoContinueDeadline,
                totalDuration: ReaderSettings.shared.pauseDuration,
                dark: dark
            )
            .frame(maxWidth: maxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactBody: some View {
        BlockKindStubPreview(
            kind: .code,
            caption: language,
            dark: dark,
            wordSize: compactWordSize,
            autoContinueDeadline: autoContinueDeadline,
            onContinue: onContinue
        )
    }

    private func handleTap() {
        if let onOpen { onOpen() } else { onContinue() }
    }

    private var strokeColor: Color {
        dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.08)
    }
}

/// Table renderer for the paused-block area. `.full` shows the HTML via
/// `TablePreviewView`; `.compact` falls back to the stub (Notch / Separate /
/// "Show block preview in reader area" off). Mirrors `FormulaPreview` in
/// shape — keeping the two parallel keeps the inline-card sizing consistent
/// across kinds.
struct TablePreview: View {
    let html: String
    let caption: String?
    var style: RSVPImagePreviewView.Style
    var dark: Bool
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var compactWordSize: CGFloat
    var autoContinueDeadline: Date?
    var onContinue: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        switch style {
        case .full:    fullBody
        case .compact: compactBody
        }
    }

    private var fullBody: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                TablePreviewView(html: html, dark: dark)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(strokeColor, lineWidth: 1)
                    )

                if onOpen != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { handleTap() }
            .help(onOpen != nil ? "Click to enlarge · Space to continue" : "Press Space to continue")

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondaryColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: maxWidth)
            }

            ContinueHint(deadline: autoContinueDeadline, dark: dark, showOpenAffordance: onOpen != nil)

            AutoContinueProgressBar(
                deadline: autoContinueDeadline,
                totalDuration: ReaderSettings.shared.pauseDuration,
                dark: dark
            )
            .frame(maxWidth: maxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactBody: some View {
        BlockKindStubPreview(
            kind: .table,
            caption: caption,
            dark: dark,
            wordSize: compactWordSize,
            autoContinueDeadline: autoContinueDeadline,
            onContinue: onContinue
        )
    }

    private func handleTap() {
        if let onOpen { onOpen() } else { onContinue() }
    }

    private var strokeColor: Color {
        dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.08)
    }

    private var secondaryColor: Color {
        dark ? Color.white.opacity(0.65) : .secondary
    }
}

/// Formula renderer for the paused-block area. `.full` shows the rendered math via
/// `MathRenderView`; `.compact` falls back to the standard stub (just the word
/// "Formula" with a hint) since modes that use compact (Notch, Separate, off-toggle)
/// aren't a good fit for an interactive WebView preview.
struct FormulaPreview: View {
    let latex: String
    let caption: String?
    var style: RSVPImagePreviewView.Style
    var dark: Bool
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var compactWordSize: CGFloat
    var autoContinueDeadline: Date?
    var onContinue: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        switch style {
        case .full:    fullBody
        case .compact: compactBody
        }
    }

    private var fullBody: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                MathRenderView(latex: latex, displayMode: true, dark: dark)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(strokeColor, lineWidth: 1)
                    )

                if onOpen != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { handleTap() }
            .help(onOpen != nil ? "Click to enlarge · Space to continue" : "Press Space to continue")

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondaryColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: maxWidth)
            }

            ContinueHint(deadline: autoContinueDeadline, dark: dark, showOpenAffordance: onOpen != nil)

            AutoContinueProgressBar(
                deadline: autoContinueDeadline,
                totalDuration: ReaderSettings.shared.pauseDuration,
                dark: dark
            )
            .frame(maxWidth: maxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactBody: some View {
        BlockKindStubPreview(
            kind: .formula,
            caption: caption,
            dark: dark,
            wordSize: compactWordSize,
            autoContinueDeadline: autoContinueDeadline,
            onContinue: onContinue
        )
    }

    private func handleTap() {
        if let onOpen { onOpen() } else { onContinue() }
    }

    private var strokeColor: Color {
        dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.08)
    }

    private var secondaryColor: Color {
        dark ? Color.white.opacity(0.65) : .secondary
    }
}

/// Fallback preview shown when a `PauseableBlock` of a kind other than `.image`
/// is reached. There are no producers for those kinds today; once formula/table/
/// code producers land, replace cases with dedicated renderers.
struct BlockKindStubPreview: View {
    let kind: BlockKind
    let caption: String?
    var dark: Bool = false
    var wordSize: CGFloat = 32
    var autoContinueDeadline: Date? = nil
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: kind.iconName)
                    .font(.system(size: wordSize * 0.7))
                Text(kind.displayName)
                    .font(.system(size: wordSize, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .foregroundColor(dark ? .white : .primary)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(dark ? .white.opacity(0.6) : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            ContinueHint(deadline: autoContinueDeadline, dark: dark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onContinue)
    }
}

/// Single source of truth for the "Press Space to continue" / "Resuming in Xs"
/// hint shown under every pause-worthy block preview. Polls every 100ms when a
/// deadline is active so the user sees a live countdown. When `showOpenAffordance`
/// is true, the hint also surfaces the click-to-enlarge gesture so users discover
/// the lightbox.
struct ContinueHint: View {
    let deadline: Date?
    var dark: Bool = false
    var showOpenAffordance: Bool = false

    var body: some View {
        Group {
            if let deadline {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    countdownView(remaining: max(0, deadline.timeIntervalSince(context.date)))
                }
            } else {
                manualView
            }
        }
        .foregroundColor(dark ? Color.white.opacity(0.7) : .secondary)
    }

    private var manualView: some View {
        HStack(spacing: 8) {
            if showOpenAffordance {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Click to enlarge")
                        .font(.system(size: 11))
                }
                Text("·").opacity(0.5)
            }
            HStack(spacing: 4) {
                Image(systemName: "space")
                    .font(.system(size: 10, weight: .semibold))
                Text("Press Space to continue")
                    .font(.system(size: 11))
            }
        }
    }

    private func countdownView(remaining: TimeInterval) -> some View {
        HStack(spacing: 8) {
            if showOpenAffordance {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Click to enlarge")
                        .font(.system(size: 11))
                }
                Text("·").opacity(0.5)
            }
            Text("Resuming in \(Int(ceil(remaining)))s")
                .font(.system(size: 11))
                .monospacedDigit()
            Text("·")
                .opacity(0.5)
            HStack(spacing: 3) {
                Image(systemName: "space")
                    .font(.system(size: 10, weight: .semibold))
                Text("Skip")
                    .font(.system(size: 11))
            }
        }
    }
}

/// Thin progress bar drawn under a block preview while the auto-continue timer
/// is ticking. Renders nothing when `deadline` is nil. Used in the `.full` style
/// previews where there's room for a visual signal beneath the content.
struct AutoContinueProgressBar: View {
    let deadline: Date?
    let totalDuration: TimeInterval
    var dark: Bool = false

    var body: some View {
        Group {
            if let deadline, totalDuration > 0 {
                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    let remaining = max(0, deadline.timeIntervalSince(context.date))
                    let progress = max(0, min(1, remaining / totalDuration))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(barTrackColor)
                                .frame(height: 2)
                            Capsule()
                                .fill(barFillColor)
                                .frame(width: geo.size.width * progress, height: 2)
                        }
                    }
                    .frame(height: 2)
                }
            }
        }
    }

    private var barTrackColor: Color {
        dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.08)
    }

    private var barFillColor: Color {
        dark ? Color.white.opacity(0.4) : Color.accentColor.opacity(0.7)
    }
}
