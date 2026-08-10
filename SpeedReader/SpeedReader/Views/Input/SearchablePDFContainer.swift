import SwiftUI
import PDFKit

/// Wraps a `PDFView`-backed preview with an always-visible top-right `SearchBarView`.
/// The host view writes its `PDFView` into `pdfViewRef` (in `makeNSView`).
/// ⌘F (routed via the `.openSearch` notification from `ContentView`) focuses the field.
@available(macOS 14.0, *)
struct SearchablePDFContainer<Content: View>: View {
    @Binding var pdfViewRef: PDFView?
    /// RSVP-aligned word rects (same array as `DocumentContent.ocrWordLocations`).
    /// Needed for "Read from here" — maps an active `PDFSelection` to a word index.
    var wordLocations: [OCRWordLocation?]?
    var isEnabled: Bool = true
    var onStartFromHere: ((Int) -> Void)? = nil
    /// Leading content of the unified top toolbar (e.g. file chip, tab picker).
    var toolbarLeading: AnyView = AnyView(EmptyView())
    /// Trailing controls of the unified top toolbar.
    var toolbarTrailing: AnyView = AnyView(EmptyView())
    /// Keep the toolbar row visible even when search is unavailable.
    var alwaysShowsToolbar: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var focusRequest = 0
    @State private var target: PDFSearchTarget? = nil
    @State private var isSearchOpen: Bool = false

    private var pdfViewID: ObjectIdentifier? {
        pdfViewRef.map(ObjectIdentifier.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content()
                .overlay(alignment: .topTrailing) {
                    if isSearchOpen, let target {
                        ExpandedSearchRow(
                            target: target,
                            focusRequest: focusRequest,
                            onClose: closeSearch,
                            onStartFromHere: onStartFromHere
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
        .animation(.easeOut(duration: 0.2), value: target != nil)
        .animation(.easeOut(duration: 0.2), value: isSearchOpen)
        .onAppear(perform: syncTarget)
        .onChange(of: isEnabled) { _, enabled in
            if enabled {
                syncTarget()
            } else {
                target?.clear()
                target = nil
                isSearchOpen = false
            }
        }
        .onChange(of: pdfViewID) { _, _ in syncTarget() }
        .onChange(of: wordLocations) { _, _ in syncTarget() }
        .onReceive(NotificationCenter.default.publisher(for: .openSearch)) { _ in
            guard isEnabled else { return }
            syncTarget()
            isSearchOpen = true
            focusRequest += 1
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        if target != nil || alwaysShowsToolbar {
            PreviewToolbarRow(leading: toolbarLeading, trailing: toolbarTrailing) {
                if target != nil {
                    SearchToggleButton(isOpen: isSearchOpen) {
                        if isSearchOpen {
                            closeSearch()
                        } else {
                            isSearchOpen = true
                            focusRequest += 1
                        }
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func syncTarget() {
        guard isEnabled else { return }
        guard let pdfView = pdfViewRef else { return }
        if let existing = target, existing.pdfView === pdfView {
            existing.wordLocations = wordLocations
        } else {
            target = PDFSearchTarget(pdfView: pdfView, wordLocations: wordLocations)
        }
    }

    private func closeSearch() {
        target?.clear()
        isSearchOpen = false
    }
}
