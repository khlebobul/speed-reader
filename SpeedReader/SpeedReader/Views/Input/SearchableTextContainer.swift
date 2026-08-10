import SwiftUI

/// Wraps a text-based preview (`ClickableTextPreview`, `HighlightedTextView`, …) with a
/// top-right always-visible `SearchBarView`. ⌘F (routed via the `.openSearch` notification from
/// `ContentView`) focuses the field; the content closure receives the current
/// `(matchIndices, activeMatch)` so it can paint search highlights and auto-scroll.
@available(macOS 14.0, *)
struct SearchableTextContainer<Content: View>: View {
    /// Plain source text — used when `blocks` is nil/empty.
    let text: String
    /// Structured blocks (e.g. URL article paragraphs). When present they take precedence
    /// over `text` for word extraction, matching what `ClickableTextPreview` actually renders.
    var blocks: [TextBlock]? = nil
    var isEnabled: Bool = true
    /// Called with the active match's RSVP word index when the user clicks "Read from here".
    var onStartFromHere: ((Int) -> Void)? = nil
    /// Leading content of the unified top toolbar (e.g. file chip, URL field).
    var toolbarLeading: AnyView = AnyView(EmptyView())
    /// Trailing controls of the unified top toolbar (e.g. "Set start position").
    var toolbarTrailing: AnyView = AnyView(EmptyView())
    /// Keep the toolbar row visible even when search is unavailable.
    var alwaysShowsToolbar: Bool = false
    /// Receives the current match state on every render so the wrapped view can highlight hits.
    @ViewBuilder var content: (_ matchIndices: [Int], _ activeMatch: Int) -> Content

    @State private var focusRequest = 0
    @State private var matches: [Int] = []
    @State private var active: Int = -1
    @State private var target: TextSearchTarget? = nil
    @State private var isSearchOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content(matches, active)
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
                closeSearch()
            }
        }
        .onChange(of: text) { _, _ in syncTarget() }
        .onChange(of: blocks) { _, _ in syncTarget() }
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
        target = TextSearchTarget(
            textProvider: { text },
            blocksProvider: { blocks },
            onUpdate: { newMatches, newActive in
                matches = newMatches
                active = newActive
            }
        )
    }

    private func closeSearch() {
        isSearchOpen = false
        matches = []
        active = -1
    }
}
