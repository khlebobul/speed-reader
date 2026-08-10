import SwiftUI
import WebKit

/// Renders a `<table>` (already-built HTML) inside a transparent WKWebView with
/// theme-aware styling. Used when the engine auto-pauses on a `.table` block —
/// see `RSVPBlockPreviewView` + `BlockLightboxOverlay`.
///
/// Why WKWebView and not native SwiftUI `Table`/`Grid`: the input is arbitrary
/// HTML from DOCX or web articles (nested cells, `colspan`/`rowspan`, inline
/// formatting, `<br>` in cells). Re-parsing that into a SwiftUI table tree is
/// a separate project; punting through the platform's HTML renderer gets us
/// pixel-correct results with one line of `loadHTMLString`.
///
/// Background is transparent so it composites cleanly over both the light
/// reader card and the dark Zen / lightbox canvas. The dark flag switches
/// font + border colors to readable values.
struct TablePreviewView: NSViewRepresentable {
    let html: String
    var dark: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.enableInspectorInDebug()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.fullHTML(html: html, dark: dark), baseURL: nil)
        context.coordinator.lastHTML = html
        context.coordinator.lastDark = dark
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the inputs actually changed — reloading on every
        // SwiftUI body invalidation thrashes the WebView and flashes a blank
        // frame between renders.
        guard context.coordinator.lastHTML != html || context.coordinator.lastDark != dark else { return }
        webView.loadHTMLString(Self.fullHTML(html: html, dark: dark), baseURL: nil)
        context.coordinator.lastHTML = html
        context.coordinator.lastDark = dark
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var lastDark: Bool?
    }

    private static func fullHTML(html: String, dark: Bool) -> String {
        let textColor   = dark ? "#f0f0f0" : "#111"
        let headerBg    = dark ? "#2a2a2a" : "#f6f8fa"
        let borderColor = dark ? "#3a3a3a" : "#d0d7de"
        let mutedColor  = dark ? "rgba(240,240,240,0.6)" : "#57606a"

        return """
        <!DOCTYPE html>
        <html><head>
          <meta charset="UTF-8">
          <style>
            html, body { margin: 0; padding: 0; background: transparent; color: \(textColor); }
            body {
              font-family: -apple-system, system-ui, BlinkMacSystemFont, sans-serif;
              font-size: 13px;
              padding: 12px;
              overflow: auto;
            }
            table {
              border-collapse: collapse;
              width: 100%;
              max-width: 100%;
            }
            th, td {
              border: 1px solid \(borderColor);
              padding: 6px 10px;
              text-align: left;
              vertical-align: top;
            }
            th {
              background: \(headerBg);
              font-weight: 600;
            }
            tr:nth-child(even) td {
              background: \(dark ? "rgba(255,255,255,0.03)" : "rgba(0,0,0,0.02)");
            }
            caption {
              caption-side: bottom;
              color: \(mutedColor);
              font-size: 11px;
              padding-top: 6px;
              text-align: center;
            }
            /* Defensive: hide anything that snuck in from the source HTML and
               shouldn't render inside the preview (script tags should already
               have been stripped on the JS side, but belt + suspenders). */
            script, style, link { display: none !important; }
          </style>
        </head><body>
          \(html)
        </body></html>
        """
    }
}
