import SwiftUI
import AppKit

/// Full-screen overlay for studying a `PauseableBlock` at its native size, with
/// pinch-zoom and pan. Shown when the user clicks the block thumbnail in a `.full`
/// preview. Esc, the × button, or click on the dimmed background dismisses.
///
/// Today only `.image` has a real content path; the other block kinds render a stub
/// label so the architecture is in place for Phase 3–5 producers.
struct BlockLightboxOverlay: View {
    let block: PauseableBlock
    var onDismiss: () -> Void

    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var keyMonitor: Any?

    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 6.0

    var body: some View {
        ZStack {
            // Dimmed backdrop — taps outside the content close the overlay.
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            content
                .scaleEffect(zoom)
                .offset(pan)
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                // Double-tap to reset zoom/pan when the user has explored and wants
                // to recenter without closing.
                .onTapGesture(count: 2) { resetTransform() }
                .padding(40)

            VStack {
                HStack {
                    if let caption = block.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .padding(.leading, 20)
                            .padding(.top, 16)
                    }
                    Spacer()
                    closeButton
                        .padding(.trailing, 20)
                        .padding(.top, 16)
                }
                Spacer()
                hintBar
                    .padding(.bottom, 20)
            }
        }
        .transition(.opacity)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .image(let ref):
            LightboxImageContent(ref: ref)
        case .formula(let latex, let caption):
            LightboxFormulaContent(latex: latex, caption: caption)
        case .table(let html, _, let caption):
            LightboxTableContent(html: html, caption: caption)
        case .code(let language, let source):
            LightboxCodeContent(source: source, language: language)
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.white.opacity(0.9))
                .background(Circle().fill(Color.black.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
    }

    private var hintBar: some View {
        HStack(spacing: 14) {
            hintItem(icon: "escape", label: "Close")
            hintItem(icon: "arrow.up.left.and.arrow.down.right", label: "Pinch to zoom")
            hintItem(icon: "hand.draw", label: "Drag to pan")
            hintItem(icon: "rectangle.compress.vertical", label: "Double-tap to reset")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private func hintItem(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundColor(.white.opacity(0.75))
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = clampedZoom(lastZoom * value)
            }
            .onEnded { _ in
                lastZoom = zoom
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                pan = CGSize(
                    width: lastPan.width + value.translation.width,
                    height: lastPan.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastPan = pan
            }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minZoom), maxZoom)
    }

    private func resetTransform() {
        withAnimation(.easeOut(duration: 0.18)) {
            zoom = 1.0
            pan = .zero
        }
        lastZoom = 1.0
        lastPan = .zero
    }

    // MARK: - Keyboard

    /// A local key monitor installed for the overlay's lifetime. We don't reuse the
    /// reader's monitor because Esc semantics differ — here it closes only the
    /// overlay, not the underlying reader. Adding the monitor LIFO means it sees
    /// events before the reader's monitor, so we can `return nil` to consume Esc.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                onDismiss()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Image content

private struct LightboxImageContent: View {
    let ref: ImageRef

    var body: some View {
        Group {
            switch ref {
            case .url(let url, _):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    case .success(let img):
                        img.resizable().scaledToFit()
                    case .failure:
                        unavailable
                    @unknown default:
                        unavailable
                    }
                }
            case .dataURL(let s, _):
                if let nsImage = RSVPImagePreviewView.decodeDataURL(s) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    unavailable
                }
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 44))
            Text("Image unavailable")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.7))
    }
}

// MARK: - Formula content

/// Lightbox renderer for `.formula` blocks. Reuses `MathRenderView` so the math
/// renders identically to the inline preview, just at a larger scale. KaTeX runs
/// inside a transparent WebView; we set `dark: true` because the lightbox always
/// dims the background to black.
private struct LightboxFormulaContent: View {
    let latex: String
    let caption: String?

    var body: some View {
        VStack(spacing: 14) {
            MathRenderView(latex: latex, displayMode: true, dark: true)
                .frame(maxWidth: 900, maxHeight: 540)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }
        }
    }
}

// MARK: - Table content

/// Lightbox renderer for `.table` blocks. Reuses `TablePreviewView` (the same
/// WebView-based renderer the inline preview uses) at lightbox scale. Dark mode
/// is forced on because the lightbox always dims to black.
private struct LightboxTableContent: View {
    let html: String
    let caption: String?

    var body: some View {
        VStack(spacing: 14) {
            TablePreviewView(html: html, dark: true)
                .frame(maxWidth: 1000, maxHeight: 620)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }
        }
    }
}

// MARK: - Code content

/// Lightbox renderer for `.code` blocks. Same `CodePreviewView` as the inline
/// preview, scaled up. Caption row shows the language tag when one was
/// supplied or auto-detected.
private struct LightboxCodeContent: View {
    let source: String
    let language: String?

    var body: some View {
        VStack(spacing: 14) {
            CodePreviewView(source: source, language: language, dark: true)
                .frame(maxWidth: 1000, maxHeight: 620)

            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

// MARK: - Stub for non-image kinds (currently unused — keep for future block kinds)

private struct LightboxStubContent: View {
    let kind: BlockKind
    let caption: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: kind.iconName)
                .font(.system(size: 56))
            Text(kind.displayName)
                .font(.system(size: 24, weight: .semibold))
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            Text("Full-size preview coming with the \(kind.displayName.lowercased()) producer.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .foregroundColor(.white)
    }
}
