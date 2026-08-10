import Foundation
import WebKit

/// `SearchTarget` implementation backed by a `WKWebView`.
/// Requires the JS bundle in the view's HTML shell to expose
/// `_searchFind / _searchNext / _searchPrev / _searchClear / _searchActiveWordIndex`.
@MainActor
final class WKWebViewSearchTarget: SearchTarget {
    weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func find(query: String) async -> Int {
        guard let webView else { return 0 }
        let escaped = jsEscape(query)
        let js = "_searchFind(\"\(escaped)\")"
        return (try? await webView.evaluateJavaScript(js) as? Int) ?? 0
    }

    func next() async -> Int {
        guard let webView else { return -1 }
        return (try? await webView.evaluateJavaScript("_searchNext()") as? Int) ?? -1
    }

    func prev() async -> Int {
        guard let webView else { return -1 }
        return (try? await webView.evaluateJavaScript("_searchPrev()") as? Int) ?? -1
    }

    func clear() {
        webView?.evaluateJavaScript("_searchClear()", completionHandler: nil)
    }

    func activeWordIndex() async -> Int {
        guard let webView else { return -1 }
        return (try? await webView.evaluateJavaScript("_searchActiveWordIndex()") as? Int) ?? -1
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
