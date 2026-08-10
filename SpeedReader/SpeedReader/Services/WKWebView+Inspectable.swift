import WebKit

extension WKWebView {
    /// Exposes this web view to Safari's Web Inspector in DEBUG builds only.
    /// Release builds stay non-inspectable so end users can't poke at the
    /// embedded markdown/KaTeX/highlight.js shells.
    ///
    /// Usage in DEBUG:
    ///   1. Run the app from Xcode.
    ///   2. Safari → Develop → Speed Reader → pick the WKWebView to inspect.
    func enableInspectorInDebug() {
        #if DEBUG
        self.isInspectable = true
        #endif
    }
}
