import SwiftUI
import WebKit

/// SwiftUI wrapper that observes RSVPEngine for word highlighting in DOCX view.
@available(macOS 13.0, *)
struct ObservedDOCXPreviewView: View {
    let blocks: [TextBlock]
    let title: String?
    @ObservedObject var engine: RSVPEngine
    var webViewRef: Binding<WKWebView?>? = nil

    var body: some View {
        DOCXPreviewView(blocks: blocks, title: title, wordIndex: engine.currentIndex, webViewRef: webViewRef)
    }
}

/// `BookPreviewWithTOC` driven by an `RSVPEngine` for DOCX — observes
/// `currentIndex` for the active-section highlight and seeks the engine when
/// the user taps a TOC entry. Mirrors `ObservedBookPreviewWithTOC` so the
/// DOCX branch of `FilePreviewView` gets the same sidebar wiring as EPUB/FB2.
@available(macOS 13.0, *)
struct ObservedDOCXPreviewWithTOC: View {
    let blocks: [TextBlock]
    let title: String?
    let toc: TableOfContents?
    @ObservedObject var engine: RSVPEngine
    var webViewRef: Binding<WKWebView?>? = nil

    var body: some View {
        BookPreviewWithTOC(
            toc: toc,
            currentIndex: engine.currentIndex,
            onSelect: { entry in engine.seekTo(entry.wordIndex) }
        ) {
            ObservedDOCXPreviewView(blocks: blocks, title: title, engine: engine, webViewRef: webViewRef)
        }
    }
}

/// Renders parsed DOCX blocks as vertically scrollable pages in WKWebView.
/// Page-like layout with vertical scrolling (similar to PDF viewer).
/// When isSelectingStart is true, clicking a word calls onWordSelected with its index.
@available(macOS 13.0, *)
struct DOCXPreviewView: NSViewRepresentable {
    let blocks: [TextBlock]
    let title: String?
    var wordIndex: Int = -1
    var isSelectingStart: Bool = false
    /// Visual style applied to the word at `wordIndex`. Defaults to live reading
    /// (used by `ObservedDOCXPreviewView` when wrapped by an engine). Direct
    /// callers that show a pre-selected start word pass `.startMarker`.
    var highlightRole: HighlightRole = .readingActive
    var onWordSelected: ((Int) -> Void)? = nil
    /// `SearchablePreviewContainer` writes the WKWebView into this binding so ⌘F can talk to it.
    var webViewRef: Binding<WKWebView?>? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "wordClicked")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.enableInspectorInDebug()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.onWordSelected = onWordSelected
        if let webViewRef {
            DispatchQueue.main.async { webViewRef.wrappedValue = webView }
        }

        context.coordinator.pendingIndex = wordIndex
        context.coordinator.pendingSelectionMode = isSelectingStart
        let html = buildHTML(blocks: blocks, title: title)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onWordSelected = onWordSelected
        context.coordinator.highlightRole = highlightRole

        // Toggle selection mode in JS
        if isSelectingStart != context.coordinator.lastSelectionMode {
            context.coordinator.lastSelectionMode = isSelectingStart
            webView.evaluateJavaScript("window._setSelectionMode(\(isSelectingStart))", completionHandler: nil)
        }

        // Highlight word (used for both reading and selection modes)
        if wordIndex != context.coordinator.lastIndex {
            context.coordinator.lastIndex = wordIndex
            context.coordinator.highlightWordAt(index: wordIndex)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastIndex = -1
        var pendingIndex = -1
        var lastSelectionMode = false
        var pendingSelectionMode = false
        var highlightRole: HighlightRole = .readingActive
        var onWordSelected: ((Int) -> Void)?
        private var isLoaded = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if pendingSelectionMode {
                lastSelectionMode = true
                webView.evaluateJavaScript("window._setSelectionMode(true)", completionHandler: nil)
            }
            if pendingIndex >= 0 { highlightWordAt(index: pendingIndex) }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "wordClicked", let index = message.body as? Int {
                DispatchQueue.main.async { [weak self] in
                    self?.onWordSelected?(index)
                    self?.lastIndex = index
                    self?.highlightWordAt(index: index)
                }
            }
        }

        func highlightWordAt(index: Int) {
            guard isLoaded, let webView else { return }
            let role = highlightRole
            let hlClass = HighlightStyle.cssClass(for: role)
            let hlStyle = HighlightStyle.cssDeclaration(for: role)
            let placeholderOutline = HighlightStyle.cssBackground(for: role)
            let js = """
            (function(targetIndex) {
                var prev = document.querySelector('\(HighlightStyle.highlightSpanSelector)');
                if (prev) {
                    var p = prev.parentNode;
                    p.replaceChild(document.createTextNode(prev.textContent), prev);
                    p.normalize();
                }
                var prevPHs = document.querySelectorAll('.rsvp-image[data-rsvp-active], .rsvp-code[data-rsvp-active], .rsvp-table[data-rsvp-active], .rsvp-formula[data-rsvp-active]');
                for (var pi = 0; pi < prevPHs.length; pi++) {
                    var pp = prevPHs[pi];
                    pp.removeAttribute('data-rsvp-active');
                    pp.style.outline = '';
                    pp.style.outlineOffset = '';
                }
                if (targetIndex < 0) return;

                var WORD_RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;

                var container = document.getElementById('content');
                var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT,
                    { acceptNode: window._rsvpAcceptNode });
                var wordCount = 0;
                var node;

                while (node = walker.nextNode()) {
                    var cn = node.parentElement && node.parentElement.className;
                    if (cn === 'rsvp-hl' || cn === 'rsvp-start-word') continue;
                    var text = node.textContent;
                    WORD_RE.lastIndex = 0;
                    var match;

                    while ((match = WORD_RE.exec(text)) !== null) {
                        if (wordCount === targetIndex) {
                            // Placeholder beat (rsvp-image/code/table): outline the
                            // wrapper and scroll to the visible inner element rather
                            // than wrapping the off-screen token text node. Bounding
                            // box of the wrapper itself would include the off-screen
                            // token at top:-9999px and jump-scroll the page.
                            var placeholderEl = node.parentElement && node.parentElement.closest('.rsvp-image, .rsvp-code, .rsvp-table, .rsvp-formula');
                            if (placeholderEl) {
                                placeholderEl.style.outline = '2px solid \(placeholderOutline)';
                                placeholderEl.style.outlineOffset = '4px';
                                placeholderEl.setAttribute('data-rsvp-active', '1');
                                // KaTeX render is the only visible inner element for formulas;
                                // scroll to it (not the wrapper) since the wrapper's bbox includes
                                // the off-screen token at top:-9999px.
                                var visibleEl = placeholderEl.querySelector('img, pre, table, .rsvp-formula-render');
                                (visibleEl || placeholderEl).scrollIntoView({block:'center',behavior:'instant'});
                                return;
                            }
                            var offset = match.index;
                            var len = match[0].length;
                            var before = text.substring(0, offset);
                            var after = text.substring(offset + len);
                            var span = document.createElement('span');
                            span.className = '\(hlClass)';
                            span.style.cssText = '\(hlStyle)';
                            span.textContent = match[0];
                            var parent = node.parentNode;
                            if (before) parent.insertBefore(document.createTextNode(before), node);
                            parent.insertBefore(span, node);
                            if (after) parent.insertBefore(document.createTextNode(after), node);
                            parent.removeChild(node);
                            span.scrollIntoView({block:'center',behavior:'instant'});
                            return;
                        }
                        wordCount++;
                    }
                }
            })(\(index));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - HTML generation

    private func buildHTML(blocks: [TextBlock], title: String?) -> String {
        var body = ""
        let isFirstBlockTitle = title != nil && blocks.first?.text == title

        for (i, block) in blocks.enumerated() {
            let text = escapeHTML(block.text)
            switch block.type {
            case .heading(let level):
                let tag = "h\(min(max(level, 1), 6))"
                if i == 0 && isFirstBlockTitle {
                    body += "<\(tag) class=\"doc-title\">\(text)</\(tag)>\n"
                } else {
                    body += "<\(tag)>\(text)</\(tag)>\n"
                }
            case .quote:
                body += "<blockquote><p>\(text)</p></blockquote>\n"
            case .code(let language, let source):
                let langClass = language.flatMap { $0.isEmpty ? nil : " class=\"language-\($0)\"" } ?? ""
                // DOCXReader doesn't emit .code today (Word styled code reads as
                // paragraph), but wrap defensively for parity with the rsvp-image
                // pattern: off-screen token + visible <pre>, walker rejects <pre>
                // so the block contributes exactly one "code" word matching
                // plainText. See `_rsvpAcceptNode`.
                body += "<div class=\"rsvp-code\"><span class=\"rsvp-code-token\">\(RSVPEngine.placeholderCode)</span><pre><code\(langClass)>\(escapeHTML(source))</code></pre></div>\n"
            case .list:
                body += "<p class=\"list-item\">\(text)</p>\n"
            case .table(let html, _, let caption):
                // DOCXReader emits one .table block per <w:tbl> with the rendered
                // HTML as the associated value, so the preview can drop it in
                // verbatim instead of reconstructing rows from a pipe-separated text.
                // Wrapped in an `.rsvp-table` div with an off-screen `.rsvp-table-token`
                // so the DOM walker counts the table as exactly one "table" word —
                // matching `placeholderTable` in plainText. Walker rejects nodes
                // inside `<table>` so cell content doesn't leak in.
                body += "<div class=\"rsvp-table\"><span class=\"rsvp-table-token\">\(RSVPEngine.placeholderTable)</span><div class=\"doc-table-wrap\">\(html)"
                if let caption, !caption.isEmpty {
                    body += "<div class=\"doc-table-caption\">\(escapeHTML(caption))</div>"
                }
                body += "</div></div>\n"
            case .footnote:
                body += "<p class=\"footnote\">\(text)</p>\n"
            case .image(let src, let altText):
                let alt = escapeHTML(altText ?? "")
                body += """
                <div class="rsvp-image"><span class="rsvp-image-token">image</span><img src="\(src)" alt="\(alt)"></div>

                """
            case .formula(let latex, let caption):
                // Off-screen "formula" token + KaTeX-rendered LaTeX. `data-latex`
                // is read by `_rsvpRenderFormulas` once KaTeX finishes loading
                // from CDN. DOCX OMML equations are standalone block equations
                // in Word, so we default to `display=true`. Walker rejects
                // `.rsvp-formula-render` and `.katex` so the rendered math
                // doesn't leak into the word stream — only the off-screen token
                // contributes one "formula" word matching `placeholderFormula`.
                body += "<div class=\"rsvp-formula\"><span class=\"rsvp-formula-token\">\(RSVPEngine.placeholderFormula)</span><span class=\"rsvp-formula-render\" data-latex=\"\(escapeHTML(latex))\" data-display=\"1\"></span></div>\n"
                if let caption, !caption.isEmpty {
                    body += "<div class=\"rsvp-formula-caption\">\(escapeHTML(caption))</div>\n"
                }
            default:
                body += "<p>\(text)</p>\n"
            }
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.css">
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 15px;
            line-height: 1.7;
            color: #24292f;
            background: #e8e8e8;
            margin: 0;
            padding: 24px 0;
        }

        @media (prefers-color-scheme: dark) {
            body { color: #e0ddd5; background: #1e1e1e; }
            .page { background: #2a2a2a; box-shadow: 0 1px 4px rgba(0,0,0,0.4); }
            blockquote { border-color: #444; color: #999; }
            pre, code { background: #1a1a1a !important; }
            hr { border-color: #3a3a3a; }
        }

        #content {
            max-width: 816px;
            margin: 0 auto;
        }

        .page {
            background: white;
            box-shadow: 0 1px 4px rgba(0,0,0,0.12);
            border-radius: 2px;
            padding: 72px 72px 72px 72px;
            margin-bottom: 16px;
            min-height: 1056px;
        }

        .doc-title {
            font-size: 1.8em;
            font-weight: 700;
            text-align: center;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid #d0d7de;
        }

        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            margin-top: 20px;
            margin-bottom: 8px;
            line-height: 1.3;
        }
        h1 { font-size: 1.6em; }
        h2 { font-size: 1.35em; }
        h3 { font-size: 1.15em; }
        h4 { font-size: 1.05em; }

        p {
            margin-bottom: 10px;
            text-align: justify;
            orphans: 2;
            widows: 2;
        }

        .list-item {
            text-indent: 0;
            padding-left: 1.5em;
            margin-bottom: 4px;
        }

        blockquote {
            margin: 12px 0;
            padding: 0 1.2em;
            border-left: 3px solid #d0d7de;
            color: #57606a;
            font-style: italic;
        }
        blockquote p {
            text-indent: 0;
        }

        pre {
            font-family: "SF Mono", Menlo, monospace;
            font-size: 13px;
            background: #f6f8fa;
            padding: 12px;
            border-radius: 6px;
            margin-bottom: 12px;
            white-space: pre-wrap;
            overflow-x: auto;
        }

        /* Structured DOCX tables — DOCXReader emits one `.table` block per
           `<w:tbl>` carrying the rendered HTML, so the preview can drop a
           native `<table>` inline. */
        .doc-table-wrap {
            margin: 12px 0;
            overflow-x: auto;
        }
        .doc-table-wrap table {
            border-collapse: collapse;
            width: 100%;
            font-size: 14px;
        }
        .doc-table-wrap th,
        .doc-table-wrap td {
            border: 1px solid #d0d7de;
            padding: 6px 12px;
            text-align: left;
            vertical-align: top;
        }
        .doc-table-wrap th {
            background: #f6f8fa;
            font-weight: 600;
        }
        .doc-table-caption {
            font-size: 12px;
            color: #57606a;
            margin-top: 4px;
            text-align: center;
        }

        .footnote {
            font-size: 13px;
            color: #57606a;
            border-top: 1px solid #d0d7de;
            padding-top: 8px;
            margin-top: 16px;
        }

        /* Embedded images: visible <img> + off-screen placeholder span that the
           DOM TreeWalker counts as one word ("image") in the RSVP stream. */
        .rsvp-image {
            display: block;
            position: relative;
            margin: 12px 0;
            text-align: center;
        }
        .rsvp-image-token,
        .rsvp-code-token,
        .rsvp-table-token {
            position: absolute; left: -9999px; top: -9999px;
            width: 1px; height: 1px; overflow: hidden;
            pointer-events: none;
        }
        /* Same wrap pattern as .rsvp-image — visible <pre>/<table> stays in
           place while an off-screen token contributes one placeholder word to
           the walker's count. Walker rejects nodes inside <pre>/<table>. */
        .rsvp-code, .rsvp-table {
            display: block;
            position: relative;
        }
        /* Formula wrapper — KaTeX renders into .rsvp-formula-render asynchronously
           once the CDN script finishes loading. Walker rejects .rsvp-formula-render
           and .katex so the rendered math contributes zero walker-words; the
           off-screen .rsvp-formula-token contributes the single "formula" word
           that matches `placeholderFormula` in plainText. */
        .rsvp-formula {
            display: block;
            position: relative;
            margin: 12px 0;
            text-align: center;
        }
        .rsvp-formula-render {
            display: inline-block;
        }
        .rsvp-formula .katex-display {
            display: inline-block;
            margin: 0;
        }
        .rsvp-formula-caption {
            font-size: 12px;
            color: #57606a;
            margin-top: 4px;
            text-align: center;
        }
        @media (prefers-color-scheme: dark) {
            .rsvp-formula-caption { color: #8b949e; }
        }
        .rsvp-image img {
            max-width: 100%;
            max-height: 480px;
            border-radius: 6px;
            display: inline-block;
        }

        @media (prefers-color-scheme: dark) {
            .doc-table-wrap th,
            .doc-table-wrap td { border-color: #444; }
            .doc-table-wrap th { background: #333; }
            .doc-table-caption { color: #999; }
            .footnote { color: #999; border-color: #444; }
        }

        body.selecting { cursor: pointer; -webkit-user-select: none; user-select: none; }
        \(SearchJS.css)
        </style>
        </head>
        <body>
        <div id="content">
            <div class="page">
            \(body)
            </div>
        </div>
        <script>
        (function() {
            var _selectionMode = false;

            // Shared TreeWalker filter — rejects `<pre>` / `<table>` / `.katex` /
            // `.rsvp-formula-render` so visible block content contributes zero
            // words to the count, leaving the off-screen `.rsvp-*-token` (one
            // word) as the block's sole contribution. Must be used by every
            // walker in this file so click and highlight count the same words.
            window._rsvpAcceptNode = function(n) {
                if (!n.parentElement) return NodeFilter.FILTER_ACCEPT;
                if (n.parentElement.closest('pre')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('table')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('.katex')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('.rsvp-formula-render')) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
            };

            function _clearPlaceholdersDOCX() {
                var prevPHs = document.querySelectorAll('.rsvp-image[data-rsvp-active], .rsvp-code[data-rsvp-active], .rsvp-table[data-rsvp-active], .rsvp-formula[data-rsvp-active]');
                for (var pi = 0; pi < prevPHs.length; pi++) {
                    var pp = prevPHs[pi];
                    pp.removeAttribute('data-rsvp-active');
                    pp.style.outline = '';
                    pp.style.outlineOffset = '';
                }
            }

            window._setSelectionMode = function(enabled) {
                _selectionMode = enabled;
                if (enabled) {
                    document.body.classList.add('selecting');
                } else {
                    document.body.classList.remove('selecting');
                    var prev = document.querySelector('\(HighlightStyle.highlightSpanSelector)');
                    if (prev) {
                        var p = prev.parentNode;
                        p.replaceChild(document.createTextNode(prev.textContent), prev);
                        p.normalize();
                    }
                    _clearPlaceholdersDOCX();
                }
            };

            var WORD_RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;

            // Counts words walked in DOM order until reaching the placeholder's
            // off-screen token (rsvp-image / rsvp-code / rsvp-table) inside
            // `placeholderEl`. Used by clicks on the visible inner element
            // (<img> / <pre> / <table>), where caretRangeFromPoint can't reach
            // the off-screen token span.
            function _placeholderWordIndex(placeholderEl) {
                var tokenSpan = placeholderEl.querySelector('.rsvp-image-token, .rsvp-code-token, .rsvp-table-token, .rsvp-formula-token');
                if (!tokenSpan) return -1;
                var container = document.getElementById('content');
                var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT,
                    { acceptNode: window._rsvpAcceptNode });
                var wordCount = 0;
                var node;
                while (node = walker.nextNode()) {
                    if (node.parentElement === tokenSpan) return wordCount;
                    var text = node.textContent;
                    WORD_RE.lastIndex = 0;
                    while (WORD_RE.exec(text) !== null) wordCount++;
                }
                return -1;
            }

            document.addEventListener('click', function(e) {
                if (!_selectionMode) return;
                e.preventDefault();

                var prev = document.querySelector('.rsvp-hl');
                if (prev) {
                    var p = prev.parentNode;
                    p.replaceChild(document.createTextNode(prev.textContent), prev);
                    p.normalize();
                }
                _clearPlaceholdersDOCX();

                // Click landed inside a placeholder wrapper (`<img>` / `<pre>` /
                // `<table>`). For <pre>/<table> the walker rejects the click node
                // anyway; for <img> there's no text node at all. In every case,
                // resolve to the off-screen token via the wrapper directly.
                var placeholderClickEl = e.target && e.target.closest && e.target.closest('.rsvp-image, .rsvp-code, .rsvp-table, .rsvp-formula');
                if (placeholderClickEl) {
                    var phIdx = _placeholderWordIndex(placeholderClickEl);
                    if (phIdx >= 0) {
                        window.webkit.messageHandlers.wordClicked.postMessage(phIdx);
                    }
                    return;
                }

                var range = document.caretRangeFromPoint(e.clientX, e.clientY);
                if (!range) return;
                var clickNode = range.startContainer;
                var clickOffset = range.startOffset;
                if (clickNode.nodeType !== 3) return;

                var container = document.getElementById('content');
                var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT,
                    { acceptNode: window._rsvpAcceptNode });
                var wordCount = 0;
                var node;

                while (node = walker.nextNode()) {
                    var text = node.textContent;
                    WORD_RE.lastIndex = 0;
                    var match;

                    while ((match = WORD_RE.exec(text)) !== null) {
                        if (node === clickNode &&
                            clickOffset >= match.index &&
                            clickOffset <= match.index + match[0].length) {
                            window.webkit.messageHandlers.wordClicked.postMessage(wordCount);
                            return;
                        }
                        wordCount++;
                    }
                }
            });
        })();
        </script>
        <script>
        \(SearchJS.source(.init(rootSelector: "#content")))
        </script>
        <script>
        // KaTeX render — walks every .rsvp-formula-render and replaces its
        // contents with the rendered LaTeX. Called on KaTeX script load. The
        // walker has already counted the off-screen .rsvp-formula-token (one
        // word per formula) before KaTeX runs, so the rendered output's text
        // nodes (which the acceptNode filter rejects via the .katex /
        // .rsvp-formula-render ancestor check) don't affect word indices.
        window._rsvpRenderFormulas = function() {
            if (typeof katex === 'undefined') return;
            var els = document.querySelectorAll('.rsvp-formula-render');
            for (var k = 0; k < els.length; k++) {
                var el = els[k];
                var latex = el.dataset.latex || '';
                var display = el.dataset.display === '1';
                try {
                    katex.render(latex, el, {displayMode: display, throwOnError: false});
                } catch (e) {
                    el.textContent = display ? '$$' + latex + '$$' : '$' + latex + '$';
                }
            }
        };
        </script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.js"
                onload="window._rsvpRenderFormulas && window._rsvpRenderFormulas();"></script>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
