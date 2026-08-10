import SwiftUI
import WebKit

/// Renders a LaTeX formula via KaTeX (bundled offline) inside a transparent WKWebView.
///
/// Architecture: one WKWebView per instance, initialized with a static HTML template
/// that loads `katex.min.css` + `katex.min.js` and defines a `setLatex(s, display, dark)`
/// JS function. When `latex` / `displayMode` / `dark` change, the view evaluates
/// `setLatex(...)` against the loaded page. The first render is queued via a
/// coordinator until `didFinish` fires, so we never call setLatex before KaTeX exists.
///
/// Background is transparent so it composites cleanly over both the reader card
/// (light) and the dark Zen / Notch / Separate canvases. KaTeX glyphs inherit
/// `currentColor`, which we drive from the `dark` flag.
///
/// Why WKWebView and not native Core Text: there is no production-quality native
/// math typesetter for macOS, and writing one is its own multi-month project. KaTeX
/// is already battle-tested and a ~600KB bundle. The cost is one WebView per
/// auto-paused formula beat, but those beats are infrequent and short-lived.
struct MathRenderView: NSViewRepresentable {
    let latex: String
    var displayMode: Bool = true
    var dark: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.enableInspectorInDebug()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        // Disable the bounce / overscroll — math renders fit-to-content; no need to scroll.
        if let scrollView = webView.enclosingScrollView {
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none
        }
        loadTemplate(into: webView, coordinator: context.coordinator)
        context.coordinator.pending = (latex, displayMode, dark)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pending = (latex, displayMode, dark)
        context.coordinator.flushIfReady(in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pageLoaded = false
        var pending: (latex: String, display: Bool, dark: Bool)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            flushIfReady(in: webView)
        }

        func flushIfReady(in webView: WKWebView) {
            guard pageLoaded, let p = pending else { return }
            pending = nil
            let js = "setLatex(\(jsonString(p.latex)), \(p.display), \(p.dark));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// JSON-encodes a string so it can be inlined as a JS literal without
        /// dealing with backslash / quote / control-char escaping ourselves.
        private func jsonString(_ s: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
                  let str = String(data: data, encoding: .utf8),
                  let start = str.firstIndex(of: "\""),
                  let end = str.lastIndex(of: "\"") else {
                return "\"\""
            }
            return String(str[start...end])
        }
    }

    // MARK: - Template loading

    private func loadTemplate(into webView: WKWebView, coordinator: Coordinator) {
        guard let katexCSS = Bundle.main.url(forResource: "katex.min", withExtension: "css") else {
            webView.loadHTMLString("<body style='color:red'>KaTeX assets not bundled</body>", baseURL: nil)
            return
        }
        let baseURL = katexCSS.deletingLastPathComponent()
        webView.loadHTMLString(Self.htmlTemplate, baseURL: baseURL)
    }

    private static let htmlTemplate = """
    <!DOCTYPE html>
    <html><head>
      <meta charset="UTF-8">
      <link rel="stylesheet" href="katex.min.css">
      <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          display: flex; align-items: center; justify-content: center;
          min-height: 100vh; font-family: -apple-system, system-ui, sans-serif;
          color: #111;
        }
        body.dark { color: #f0f0f0; }
        #m { padding: 12px 16px; max-width: 100%; overflow: auto; line-height: 1.4; }
        .katex-display { margin: 0 !important; }
        .katex { font-size: 1.4em; }
        #m.err {
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 11px; color: #c0392b; padding: 8px;
        }
        body.dark #m.err { color: #ff7b6b; }
      </style>
    </head><body>
      <div id="m"></div>
      <script src="katex.min.js"></script>
      <script>
        function setLatex(s, display, dark) {
          document.body.className = dark ? 'dark' : '';
          var el = document.getElementById('m');
          el.className = '';
          try {
            katex.render(s, el, { displayMode: display, throwOnError: false });
          } catch (e) {
            el.className = 'err';
            el.textContent = String(e && e.message || e);
          }
        }
      </script>
    </body></html>
    """
}
