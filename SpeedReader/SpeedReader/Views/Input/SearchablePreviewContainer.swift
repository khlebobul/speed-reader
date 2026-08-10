import SwiftUI
import WebKit

/// Wraps a WKWebView-backed preview with an always-visible top-right `SearchBarView`.
/// The host view writes its `WKWebView` into `webViewRef` (in `makeNSView`).
/// ⌘F (routed via the `.openSearch` notification from `ContentView`) focuses the field.
@available(macOS 14.0, *)
struct SearchablePreviewContainer<Content: View>: View {
    @Binding var webViewRef: WKWebView?
    var isEnabled: Bool = true
    var onStartFromHere: ((Int) -> Void)? = nil
    /// Leading content of the unified top toolbar (e.g. file chip, tab picker).
    var toolbarLeading: AnyView = AnyView(EmptyView())
    /// Trailing controls of the unified top toolbar (e.g. "Set start position", TOC toggle).
    var toolbarTrailing: AnyView = AnyView(EmptyView())
    /// When true the toolbar row stays visible even while search is unavailable
    /// (during reading, before the web view is ready) so its leading/trailing
    /// controls don't disappear.
    var alwaysShowsToolbar: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var focusRequest = 0
    @State private var target: WKWebViewSearchTarget? = nil
    @State private var isSearchOpen: Bool = false

    private var webViewID: ObjectIdentifier? {
        webViewRef.map(ObjectIdentifier.init)
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
        .onChange(of: webViewID) { _, _ in syncTarget() }
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
        guard let webView = webViewRef else { return }
        if target?.webView !== webView {
            target = WKWebViewSearchTarget(webView: webView)
        }
    }

    private func closeSearch() {
        target?.clear()
        isSearchOpen = false
    }
}
