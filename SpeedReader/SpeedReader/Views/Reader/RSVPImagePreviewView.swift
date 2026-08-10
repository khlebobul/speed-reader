import SwiftUI
import AppKit

/// Replaces the ORP word display when the engine auto-pauses on an image-placeholder
/// beat. Two visual styles:
/// - `.full` shows a thumbnail and is used in modes with room for it (Main, Separate
///   when the user has the preview toggle on).
/// - `.compact` shows just the word "Image" with a visible "Press Space to continue"
///   hint, for space-constrained modes (Notch) and the toggle-off path. Skips the ORP
///   pivot highlight on the placeholder word — the user shouldn't try to "read" it.
///
/// Tapping the view continues playback in both styles.
struct RSVPImagePreviewView: View {
    enum Style {
        case full, compact
    }

    let image: ImageRef
    var style: Style = .full
    /// Use white text/icon for dark backgrounds (Notch, Separate, Zen). Defaults to
    /// the surrounding `.primary` palette which adapts to the system theme.
    var dark: Bool = false
    var maxWidth: CGFloat = 380
    var maxHeight: CGFloat = 220
    /// Font size for the "Image" label in `.compact` style. Tune per host —
    /// notch and main reader want different scales.
    var compactWordSize: CGFloat = 32
    /// When non-nil, the hint shows a live countdown (auto-continue mode) instead of
    /// "Press Space to continue". The caller passes `engine.autoContinueDeadline`.
    var autoContinueDeadline: Date? = nil
    var onContinue: () -> Void
    /// When non-nil in `.full` style, a tap on the thumbnail opens the lightbox
    /// instead of continuing playback (Space remains the continue trigger). When
    /// nil, the thumbnail tap continues playback. Has no effect in `.compact`.
    var onOpen: (() -> Void)? = nil

    var body: some View {
        switch style {
        case .full:    fullBody
        case .compact: compactBody
        }
    }

    private var fullBody: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                imageContent
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(strokeColor, lineWidth: 1)
                    )

                // Discoverability cue: small "expand" badge in the corner when the
                // tap will open a lightbox. Hidden when the tap continues playback
                // (no lightbox configured).
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
            .onTapGesture { thumbnailTapped() }
            .help(onOpen != nil ? "Click to enlarge · Space to continue" : "Press Space to continue")

            if let caption = image.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondaryColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: maxWidth)
            }

            ContinueHint(
                deadline: autoContinueDeadline,
                dark: dark,
                showOpenAffordance: onOpen != nil
            )

            AutoContinueProgressBar(
                deadline: autoContinueDeadline,
                totalDuration: ReaderSettings.shared.pauseDuration,
                dark: dark
            )
            .frame(maxWidth: maxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thumbnailTapped() {
        if let onOpen {
            onOpen()
        } else {
            onContinue()
        }
    }

    private var compactBody: some View {
        VStack(spacing: 6) {
            Text("Image")
                .font(.system(size: compactWordSize, weight: .regular))
                .foregroundColor(primaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ContinueHint(deadline: autoContinueDeadline, dark: dark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onContinue)
        .help("Press Space to continue")
    }

    private var primaryColor: Color {
        dark ? .white : .primary
    }

    private var secondaryColor: Color {
        dark ? Color.white.opacity(0.6) : .secondary
    }

    private var strokeColor: Color {
        dark ? Color.white.opacity(0.18) : Color.primary.opacity(0.12)
    }

    @ViewBuilder
    private var imageContent: some View {
        switch image {
        case .url(let url, _):
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().controlSize(.small)
                case .success(let img):
                    img.resizable().scaledToFit()
                case .failure:
                    fallback
                @unknown default:
                    fallback
                }
            }
        case .dataURL(let s, _):
            if let nsImage = Self.decodeDataURL(s) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            } else {
                fallback
            }
        }
    }

    private var fallback: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Image unavailable")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.04))
    }

    /// Decode a `data:<mime>;base64,<payload>` URL into an NSImage.
    static func decodeDataURL(_ raw: String) -> NSImage? {
        guard let commaIdx = raw.firstIndex(of: ","),
              raw.hasPrefix("data:") else { return nil }
        let header = raw[..<commaIdx]
        let payload = raw[raw.index(after: commaIdx)...]
        guard header.contains(";base64") else { return nil }
        guard let data = Data(base64Encoded: String(payload)) else { return nil }
        return NSImage(data: data)
    }
}
