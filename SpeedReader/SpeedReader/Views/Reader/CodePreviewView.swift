import SwiftUI
import WebKit

/// Renders a code snippet with syntax highlighting via highlight.js (bundled
/// offline). Used when the engine auto-pauses on a `.code` block.
///
/// Why WKWebView and not native Swift: highlight.js covers ~35 common languages
/// (Swift, Python, JS/TS, Go, Rust, C/C++/Java/Kotlin, HTML/CSS, SQL, Bash,
/// JSON, YAML, etc.) with mature lexers and themes — re-implementing that in
/// Swift would be a multi-week project for parity with one of those languages,
/// let alone all of them. The bundle adds ~120 KB.
///
/// Theme: light/dark variants of github.css applied at runtime via the `dark`
/// flag. Background is transparent so the surrounding reader card / lightbox
/// chrome shows through. Long lines wrap horizontally with overflow-scroll
/// since wrapping arbitrary code is usually worse than scrolling.
struct CodePreviewView: NSViewRepresentable {
    let source: String
    var language: String?
    var dark: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.enableInspectorInDebug()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadTemplate(into: webView)
        context.coordinator.pending = (source, language, dark)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pending = (source, language, dark)
        context.coordinator.flushIfReady(in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pageLoaded = false
        var pending: (source: String, language: String?, dark: Bool)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            flushIfReady(in: webView)
        }

        func flushIfReady(in webView: WKWebView) {
            guard pageLoaded, let p = pending else { return }
            pending = nil
            let lang = p.language.map(jsonString) ?? "null"
            let js = "setCode(\(jsonString(p.source)), \(lang), \(p.dark));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

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

    private func loadTemplate(into webView: WKWebView) {
        // highlight.js + both themes ship in `Reader/Resources/Highlight`. Flat
        // bundle layout (same as KaTeX) — we look up one asset to get the
        // resources dir and use it as the WebView's baseURL.
        guard let asset = Bundle.main.url(forResource: "highlight.min", withExtension: "js") else {
            webView.loadHTMLString("<body style='color:red'>highlight.js not bundled</body>", baseURL: nil)
            return
        }
        let baseURL = asset.deletingLastPathComponent()
        webView.loadHTMLString(Self.htmlTemplate, baseURL: baseURL)
    }

    private static let htmlTemplate = """
    <!DOCTYPE html>
    <html><head>
      <meta charset="UTF-8">
      <link id="theme-light" rel="stylesheet" href="github.min.css">
      <link id="theme-dark"  rel="stylesheet" href="github-dark.min.css" disabled>
      <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 12px;
          color: #111;
        }
        body.dark { color: #f0f0f0; }
        pre { margin: 0; padding: 12px 14px; overflow: auto; }
        code.hljs { background: transparent !important; padding: 0 !important; }
        #lang {
          position: sticky; top: 0; right: 0;
          float: right;
          font-size: 10px;
          font-weight: 500;
          padding: 2px 6px;
          margin: 8px 8px 0 0;
          border-radius: 4px;
          background: rgba(0,0,0,0.06);
          color: rgba(0,0,0,0.55);
        }
        body.dark #lang {
          background: rgba(255,255,255,0.1);
          color: rgba(255,255,255,0.55);
        }
        #lang:empty { display: none; }
      </style>
    </head><body>
      <div id="lang"></div>
      <pre><code id="m" class="hljs"></code></pre>
      <script src="highlight.min.js"></script>
      <script>
        function setCode(source, language, dark) {
          // Toggle theme stylesheets (the `disabled` attribute is faster than
          // swapping `<link>` href — no fetch, no flash).
          document.body.className = dark ? 'dark' : '';
          document.getElementById('theme-light').disabled = dark;
          document.getElementById('theme-dark').disabled  = !dark;

          var code = document.getElementById('m');
          code.textContent = source;
          // Reset previously-applied highlight classes so re-render is clean.
          code.className = 'hljs';

          var langTag = document.getElementById('lang');
          try {
            var result;
            if (language && hljs.getLanguage(language)) {
              result = hljs.highlight(source, { language: language, ignoreIllegals: true });
              code.innerHTML = result.value;
              langTag.textContent = language;
            } else {
              // Auto-detect when no explicit language or the hint is unknown.
              result = hljs.highlightAuto(source);
              code.innerHTML = result.value;
              langTag.textContent = result.language || '';
            }
          } catch (e) {
            // On any highlighter error, fall back to plain monospace.
            code.textContent = source;
            langTag.textContent = '';
          }
        }
      </script>
    </body></html>
    """
}
