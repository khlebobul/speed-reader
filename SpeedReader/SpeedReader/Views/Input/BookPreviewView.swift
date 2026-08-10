import SwiftUI
import WebKit

/// SwiftUI wrapper that observes RSVPEngine for word highlighting in book view.
@available(macOS 13.0, *)
struct ObservedBookPreviewView: View {
    let blocks: [TextBlock]
    let title: String?
    @ObservedObject var engine: RSVPEngine
    var webViewRef: Binding<WKWebView?>? = nil

    var body: some View {
        BookPreviewView(blocks: blocks, title: title, wordIndex: engine.currentIndex, webViewRef: webViewRef)
    }
}

/// Layout wrapper: a book preview (`content`) with an optional floating
/// table-of-contents panel. The panel is placed in `.overlay(alignment: .trailing)`
/// over `content` (it does not affect layout — the text underneath stays put).
/// Toggled from the preview's unified toolbar button or ⌘⇧O, both of which post
/// the `.toggleTOC` notification.
///
/// `topPadding` lets callers push the panel down to clear any toolbar living
/// *inside* `content` (URL preview, PDF tabs). Callers whose content starts
/// directly with the actual preview area (EPUB / FB2 / DOCX / Markdown — where
/// the toolbar is rendered by a parent `SearchablePreviewContainer`) can leave
/// the default 12pt floating gap.
@available(macOS 13.0, *)
struct BookPreviewWithTOC<Content: View>: View {
    let toc: TableOfContents?
    /// Current RSVP word index — drives the TOC's active-section highlight.
    let currentIndex: Int
    var onSelect: (TOCEntry) -> Void
    /// Space above the panel. Set to `PreviewToolbarRow.height + 12` when
    /// `content` includes a toolbar at its top, so the panel slides in below
    /// the toolbar instead of covering its chips.
    var topPadding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    @State private var showTOC = false

    private var hasTOC: Bool { !(toc?.isEmpty ?? true) }

    var body: some View {
        content()
            .overlay(alignment: .topTrailing) {
                if showTOC, let toc, !toc.isEmpty {
                    TableOfContentsView(
                        toc: toc,
                        currentIndex: currentIndex,
                        onSelect: { entry in onSelect(entry) },
                        onClose: { withAnimation(.easeOut(duration: 0.2)) { showTOC = false } }
                    )
                    .frame(maxHeight: .infinity)
                    .padding(.top, topPadding)
                    .padding(.bottom, 12)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTOC)) { _ in
                guard hasTOC else { return }
                withAnimation(.easeOut(duration: 0.2)) { showTOC.toggle() }
            }
    }
}

/// `BookPreviewWithTOC` driven by an `RSVPEngine` — observes `currentIndex` for
/// the active-section highlight and seeks the engine on tap.
@available(macOS 13.0, *)
struct ObservedBookPreviewWithTOC: View {
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
            ObservedBookPreviewView(blocks: blocks, title: title, engine: engine, webViewRef: webViewRef)
        }
    }
}

/// Renders parsed document blocks as a paginated book in WKWebView.
/// Supports page navigation and word highlighting during reading.
/// When isSelectingStart is true, clicking a word calls onWordSelected with its index.
@available(macOS 13.0, *)
struct BookPreviewView: NSViewRepresentable {
    let blocks: [TextBlock]
    let title: String?
    var wordIndex: Int = -1
    var isSelectingStart: Bool = false
    /// Visual style applied to the word at `wordIndex`. Defaults to live reading
    /// (used by `ObservedBookPreviewView` when wrapped by an engine). Direct
    /// callers that show a pre-selected start word pass `.startMarker`.
    var highlightRole: HighlightRole = .readingActive
    var onWordSelected: ((Int) -> Void)? = nil
    /// `SearchablePreviewContainer` writes the WKWebView into this binding so ⌘F can talk to it.
    var webViewRef: Binding<WKWebView?>? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "pageInfo")
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
                // Reset any previously-outlined placeholder wrappers.
                var prevPHs = document.querySelectorAll('.rsvp-image[data-rsvp-active], .rsvp-code[data-rsvp-active], .rsvp-table[data-rsvp-active], .rsvp-formula[data-rsvp-active]');
                for (var pi = 0; pi < prevPHs.length; pi++) {
                    var pp = prevPHs[pi];
                    pp.removeAttribute('data-rsvp-active');
                    pp.style.outline = '';
                    pp.style.outlineOffset = '';
                }
                if (targetIndex < 0) return;

                var WORD_RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;

                var walker = document.createTreeWalker(
                    document.getElementById('content'), NodeFilter.SHOW_TEXT,
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
                            // Placeholder token: outline the wrapper
                            // and scroll the visible block into view, rather than
                            // wrapping the off-screen token text node. Matches the
                            // DOCXPreview .rsvp-image branch.
                            var placeholderEl = node.parentElement && node.parentElement.closest('.rsvp-image, .rsvp-code, .rsvp-table, .rsvp-formula');
                            if (placeholderEl) {
                                placeholderEl.style.outline = '2px solid \(placeholderOutline)';
                                placeholderEl.style.outlineOffset = '4px';
                                placeholderEl.setAttribute('data-rsvp-active', '1');
                                var visibleEl = placeholderEl.querySelector('img, pre, table, .rsvp-formula-render');
                                window._goToWordPage(visibleEl || placeholderEl);
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
                            window._goToWordPage(span);
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
                // Style the book title differently
                if i == 0 && isFirstBlockTitle {
                    body += "<\(tag) class=\"book-title\">\(text)</\(tag)>\n"
                } else {
                    body += "<\(tag)>\(text)</\(tag)>\n"
                }
            case .quote:
                body += "<blockquote><p>\(text)</p></blockquote>\n"
            case .code(let language, let source):
                let langClass = language.flatMap { $0.isEmpty ? nil : " class=\"language-\($0)\"" } ?? ""
                let escaped = escapeHTML(source)
                // Wrap with an off-screen `.rsvp-code-token` placeholder so the DOM
                // walker counts the block as exactly one "code" word — matching the
                // engine's plainText (where `.code` blocks contribute one
                // `placeholderCode` word). The walker rejects nodes inside `<pre>`,
                // so the actual source is not walked.
                body += "<div class=\"rsvp-code\"><span class=\"rsvp-code-token\">\(RSVPEngine.placeholderCode)</span><pre><code\(langClass)>\(escaped)</code></pre></div>\n"
            case .table(let html, _, let caption):
                body += "<div class=\"rsvp-table\"><span class=\"rsvp-table-token\">\(RSVPEngine.placeholderTable)</span><div class=\"book-table-wrap\">\(html)"
                if let caption, !caption.isEmpty {
                    body += "<div class=\"book-table-caption\">\(escapeHTML(caption))</div>"
                }
                body += "</div></div>\n"
            case .image(let src, let altText):
                body += "<div class=\"rsvp-image\"><span class=\"rsvp-image-token\">\(RSVPEngine.placeholderImage)</span><img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(altText ?? ""))\"></div>\n"
            case .formula(let latex, let caption):
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

        html, body {
            height: 100%;
            overflow: hidden;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: Georgia, "Times New Roman", serif;
            font-size: 16px;
            line-height: 1.8;
            color: #2c2c2c;
        }

        @media (prefers-color-scheme: dark) {
            body { color: #e0ddd5; }
            .page-nav { background: rgba(30,30,30,0.95); border-color: #333; }
            .page-nav button { color: #ccc; border-color: #444; background: #2a2a2a; }
            .page-nav button:hover { background: #3a3a3a; }
            .page-nav button:disabled { color: #555; background: #222; }
            blockquote { border-color: #444; color: #999; }
            pre, code { background: #1a1a1a !important; }
            .book-table-wrap th,
            .book-table-wrap td { border-color: #444; }
            .book-table-wrap th { background: #333; }
            .book-table-caption,
            .rsvp-formula-caption { color: #999; }
        }

        #viewport {
            width: 100%;
            height: calc(100vh - 44px);
            overflow: hidden;
        }

        #content {
            height: 100%;
            column-fill: auto;
            column-gap: 0;
            padding: 0;
        }

        /* All content elements get horizontal padding to inset text from edges */
        #content > * {
            margin-left: 40px;
            margin-right: 40px;
        }
        #content > *:first-child {
            padding-top: 28px;
        }

        h1, h2, h3, h4, h5, h6 {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-weight: 600;
            margin-bottom: 12px;
            break-after: avoid;
        }
        .book-title {
            font-size: 1.8em;
            text-align: center;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid #ddd;
        }
        h2 { font-size: 1.4em; margin-top: 20px; }
        h3 { font-size: 1.2em; margin-top: 16px; }
        h4 { font-size: 1.05em; margin-top: 12px; }

        p {
            margin-bottom: 12px;
            text-align: justify;
            text-indent: 1.5em;
            orphans: 2;
            widows: 2;
        }

        blockquote {
            margin: 12px 40px;
            padding: 0 1.2em;
            border-left: 3px solid #ccc;
            color: #666;
            font-style: italic;
        }
        blockquote p {
            text-indent: 0;
            margin-left: 0;
            margin-right: 0;
        }

        pre {
            font-family: "SF Mono", Menlo, monospace;
            font-size: 13px;
            background: #f5f5f5;
            padding: 12px;
            border-radius: 6px;
            margin-bottom: 12px;
            white-space: pre-wrap;
            break-inside: avoid;
        }

        .book-table-wrap {
            margin-bottom: 12px;
            overflow-x: auto;
            break-inside: avoid;
        }
        .book-table-wrap table {
            width: 100%;
            border-collapse: collapse;
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.45;
        }
        .book-table-wrap th,
        .book-table-wrap td {
            border: 1px solid #d0d7de;
            padding: 6px 10px;
            text-align: left;
            vertical-align: top;
        }
        .book-table-wrap th {
            background: #f6f8fa;
            font-weight: 600;
        }
        .book-table-caption,
        .rsvp-formula-caption {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 12px;
            color: #666;
            margin-top: 4px;
            text-align: center;
        }

        .rsvp-image {
            display: block;
            position: relative;
            margin-bottom: 12px;
            text-align: center;
            break-inside: avoid;
        }
        .rsvp-image img {
            max-width: 100%;
            max-height: 520px;
            border-radius: 6px;
            display: inline-block;
        }
        .rsvp-formula {
            display: block;
            position: relative;
            margin-bottom: 12px;
            text-align: center;
            break-inside: avoid;
        }
        .rsvp-formula-render {
            display: inline-block;
        }
        .rsvp-formula .katex-display {
            display: inline-block;
            margin: 0;
        }

        /* Structured pause blocks: visible content + off-screen placeholder span
           that the DOM TreeWalker counts as one word in the RSVP stream. */
        .rsvp-code,
        .rsvp-table {
            display: block;
            position: relative;
            break-inside: avoid;
        }
        .rsvp-image-token,
        .rsvp-code-token,
        .rsvp-table-token,
        .rsvp-formula-token {
            position: absolute; left: -9999px; top: -9999px;
            width: 1px; height: 1px; overflow: hidden;
            pointer-events: none;
        }

        .page-nav {
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            height: 44px;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 16px;
            background: rgba(255,255,255,0.95);
            backdrop-filter: blur(8px);
            -webkit-backdrop-filter: blur(8px);
            border-top: 1px solid #e0e0e0;
            padding: 0 16px;
            z-index: 100;
        }

        .page-nav button {
            font-size: 13px;
            padding: 4px 14px;
            border: 1px solid #ccc;
            border-radius: 6px;
            background: #f8f8f8;
            color: #333;
            cursor: pointer;
            font-family: -apple-system, sans-serif;
        }
        .page-nav button:hover { background: #eee; }
        .page-nav button:disabled { opacity: 0.4; cursor: default; }

        .page-info {
            font-size: 13px;
            color: #888;
            font-family: -apple-system, sans-serif;
            min-width: 80px;
            text-align: center;
        }

        body.selecting { cursor: pointer; -webkit-user-select: none; user-select: none; }
        \(SearchJS.css)
        </style>
        </head>
        <body>
        <div id="viewport">
            <div id="content">
            \(body)
            </div>
        </div>
        <div class="page-nav">
            <button id="prevBtn" onclick="window._prevPage()">&#8592;</button>
            <span class="page-info" id="pageInfo">1 / 1</span>
            <button id="nextBtn" onclick="window._nextPage()">&#8594;</button>
        </div>
        <script>
        (function() {
            var viewport = document.getElementById('viewport');
            var content  = document.getElementById('content');
            var info     = document.getElementById('pageInfo');
            var prevBtn  = document.getElementById('prevBtn');
            var nextBtn  = document.getElementById('nextBtn');

            var currentPage = 0;
            var totalPages  = 1;
            var pageWidth   = 0;

            function recalc() {
                pageWidth = viewport.offsetWidth;
                if (pageWidth <= 0) return;

                content.style.columnWidth = pageWidth + 'px';

                // Force reflow before measuring scrollWidth
                void content.scrollWidth;

                totalPages = Math.max(1, Math.round(content.scrollWidth / pageWidth));

                // After resize, go to the page containing the highlighted word
                // (pagination changed, so the old page number is meaningless)
                var hl = document.querySelector('\(HighlightStyle.highlightSpanSelector)');
                if (hl) {
                    var targetPage = Math.floor(hl.offsetLeft / pageWidth);
                    goTo(targetPage);
                } else {
                    goTo(currentPage);
                }
            }

            function goTo(page) {
                currentPage = Math.max(0, Math.min(page, totalPages - 1));
                content.style.transform = 'translateX(' + (-currentPage * pageWidth) + 'px)';
                info.textContent = (currentPage + 1) + ' / ' + totalPages;
                prevBtn.disabled = currentPage <= 0;
                nextBtn.disabled = currentPage >= totalPages - 1;
            }

            function pageForElement(el) {
                if (!pageWidth) recalc();
                return Math.floor(el.offsetLeft / pageWidth);
            }

            window._prevPage = function() { goTo(currentPage - 1); };
            window._nextPage = function() { goTo(currentPage + 1); };
            window._goToPage = function(p) { goTo(p); };

            window._goToWordPage = function(el) {
                var targetPage = pageForElement(el);
                if (targetPage !== currentPage) goTo(targetPage);
            };

            document.addEventListener('keydown', function(e) {
                if (e.key === 'ArrowLeft')  { window._prevPage(); e.preventDefault(); }
                if (e.key === 'ArrowRight') { window._nextPage(); e.preventDefault(); }
            });

            // Recalculate immediately on resize (no debounce — must stay in sync)
            window.addEventListener('resize', function() { recalc(); });

            // Initial layout
            setTimeout(recalc, 50);
            setTimeout(recalc, 300);
        })();
        </script>
        <script>
        // Shared TreeWalker filter: rejects nodes inside visible block content
        // (`<pre>` / `<table>` / `.katex` / `.rsvp-formula-render`) so a multi-
        // line code block / table / KaTeX render counts as zero words, leaving
        // the off-screen `.rsvp-*-token` (one word) as the sole contribution per
        // pause-worthy block. All walkers in this file must use it to keep word
        // indices consistent — otherwise click and highlight count different
        // words and clicks select the wrong index.
        window._rsvpAcceptNode = function(n) {
            if (!n.parentElement) return NodeFilter.FILTER_ACCEPT;
            if (n.parentElement.closest('pre')) return NodeFilter.FILTER_REJECT;
            if (n.parentElement.closest('table')) return NodeFilter.FILTER_REJECT;
            if (n.parentElement.closest('.katex')) return NodeFilter.FILTER_REJECT;
            if (n.parentElement.closest('.rsvp-formula-render')) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_ACCEPT;
        };

        (function() {
            var _selectionMode = false;

            function _clearPlaceholders() {
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
                    _clearPlaceholders();
                }
            };

            var WORD_RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;

            // Counts words walked in DOM order until reaching the placeholder token
            // inside `placeholderEl`. Used by clicks on the visible `<pre>` —
            // caretRangeFromPoint can't reach the off-screen token text node.
            function _placeholderWordIndex(placeholderEl) {
                var tokenSpan = placeholderEl.querySelector('.rsvp-image-token, .rsvp-code-token, .rsvp-table-token, .rsvp-formula-token');
                if (!tokenSpan) return -1;
                var walker = document.createTreeWalker(
                    document.getElementById('content'), NodeFilter.SHOW_TEXT,
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

            function _wordIndexAtPoint(x, y) {
                var walker = document.createTreeWalker(
                    document.getElementById('content'), NodeFilter.SHOW_TEXT,
                    { acceptNode: window._rsvpAcceptNode });
                var wordCount = 0;
                var node;
                while (node = walker.nextNode()) {
                    var text = node.textContent;
                    WORD_RE.lastIndex = 0;
                    var match;
                    while ((match = WORD_RE.exec(text)) !== null) {
                        var range = document.createRange();
                        range.setStart(node, match.index);
                        range.setEnd(node, match.index + match[0].length);
                        var rects = range.getClientRects();
                        for (var i = 0; i < rects.length; i++) {
                            var rect = rects[i];
                            if (x >= rect.left && x <= rect.right &&
                                y >= rect.top && y <= rect.bottom) return wordCount;
                        }
                        wordCount++;
                    }
                }
                return -1;
            }

            document.addEventListener('click', function(e) {
                if (!_selectionMode) return;
                // Don't intercept page navigation button clicks
                if (e.target.closest('.page-nav')) return;
                e.preventDefault();

                var prev = document.querySelector('\(HighlightStyle.highlightSpanSelector)');
                if (prev) {
                    var p = prev.parentNode;
                    p.replaceChild(document.createTextNode(prev.textContent), prev);
                    p.normalize();
                }
                _clearPlaceholders();

                // Click landed inside a placeholder wrapper (visible image/pre/table/formula).
                // caretRangeFromPoint resolves to a node inside `<pre>` which the
                // walker rejects, so resolve via the wrapper directly.
                var placeholderClickEl = e.target && e.target.closest && e.target.closest('.rsvp-image, .rsvp-code, .rsvp-table, .rsvp-formula');
                if (placeholderClickEl) {
                    var phIdx = _placeholderWordIndex(placeholderClickEl);
                    if (phIdx >= 0) {
                        window.webkit.messageHandlers.wordClicked.postMessage(phIdx);
                    }
                    return;
                }

                var range = document.caretRangeFromPoint
                    ? document.caretRangeFromPoint(e.clientX, e.clientY)
                    : null;
                var clickNode = range && range.startContainer;
                var clickOffset = range && range.startOffset;

                if (clickNode && clickNode.nodeType === 3) {
                    var walker = document.createTreeWalker(
                        document.getElementById('content'), NodeFilter.SHOW_TEXT,
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
                }

                var fallbackIndex = _wordIndexAtPoint(e.clientX, e.clientY);
                if (fallbackIndex >= 0) {
                    window.webkit.messageHandlers.wordClicked.postMessage(fallbackIndex);
                }
            });
        })();
        </script>
        <script>
        \(SearchJS.source(.init(rootSelector: "#content", useGoToWordPage: true)))
        </script>
        <script>
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
