import SwiftUI
import WebKit

/// A single heading entry produced by the DOM walker — title + h-tag level +
/// its word index in the same canonical word list that `onTextExtracted` posts.
/// Used to build a `TableOfContents` whose indices are guaranteed to line up
/// with `RSVPEngine.currentIndex` after the engine is re-synced to the DOM text.
struct MarkdownDOMTOCEntry: Equatable {
    let title: String
    let level: Int
    let wordIndex: Int
}

/// SwiftUI wrapper that observes RSVPEngine for word changes.
struct ObservedMarkdownPreviewView: View {
    var url: URL? = nil
    var markdownString: String? = nil
    @ObservedObject var engine: RSVPEngine
    var onTextExtracted: ((String) -> Void)? = nil
    /// Fires once after the DOM is rendered with heading positions extracted
    /// from the same walker that produced the canonical word list — used by
    /// `MarkdownTabsPreviewView` to keep the TOC sidebar's word indices in
    /// sync with whatever the JS walker counts (formulas, code, images all
    /// collapse to single placeholder words on the JS side).
    var onTOCExtracted: (([MarkdownDOMTOCEntry]) -> Void)? = nil
    /// Fires once after the DOM is rendered with `wordIndex → PauseableBlock`
    /// extracted from the same walker that produced the canonical word list.
    /// The Swift-side `MarkdownReader.parseBlocks` cannot produce indices that
    /// agree with the JS walker (inline `$…$`, images, typography pass through
    /// the two parsers differently), so the JS pipeline is the single source
    /// of truth for which engine indices map to which pauseable block.
    var onPauseableBlocksExtracted: (([Int: PauseableBlock]) -> Void)? = nil
    var formulaPlaceholder: String = RSVPEngine.placeholderFormula
    var imagePlaceholder: String = RSVPEngine.placeholderImage
    var codePlaceholder: String = RSVPEngine.placeholderCode
    var tablePlaceholder: String = RSVPEngine.placeholderTable
    /// Optional out-binding for the underlying WKWebView. Set by `SearchablePreviewContainer`
    /// so ⌘F search can talk to the same web view that's rendering content.
    var webViewRef: Binding<WKWebView?>? = nil

    var body: some View {
        MarkdownPreviewView(
            url: url,
            markdownString: markdownString,
            wordIndex: engine.currentIndex,
            onTextExtracted: onTextExtracted,
            onTOCExtracted: onTOCExtracted,
            onPauseableBlocksExtracted: onPauseableBlocksExtracted,
            formulaPlaceholder: formulaPlaceholder,
            imagePlaceholder: imagePlaceholder,
            codePlaceholder: codePlaceholder,
            tablePlaceholder: tablePlaceholder,
            webViewRef: webViewRef
        )
    }
}

/// Renders Markdown via marked.js in WKWebView with GitHub styling.
/// Pass wordIndex to highlight the Nth word during reading (-1 = no highlight).
/// When isSelectingStart is true, clicking a word calls onWordSelected with its index.
///
/// Provide either `url` (reads .md file from disk) or `markdownString` (renders inline markdown).
struct MarkdownPreviewView: NSViewRepresentable {
    var url: URL? = nil
    var markdownString: String? = nil
    var wordIndex: Int = -1
    var isSelectingStart: Bool = false
    /// Visual style applied to the word at `wordIndex`. Defaults to live reading
    /// (used by `ObservedMarkdownPreviewView` when wrapped by an engine). Direct
    /// callers that show a pre-selected start word pass `.startMarker` to get the
    /// outlined variant instead of the filled live-reading look.
    var highlightRole: HighlightRole = .readingActive
    var onWordSelected: ((Int) -> Void)? = nil
    /// Called once after rendering with the plain text extracted from the DOM
    /// (word-regex–matched tokens joined by spaces). Use this to feed the RSVP engine
    /// so that word indices are perfectly in sync with highlighting.
    var onTextExtracted: ((String) -> Void)? = nil
    /// Called once after rendering with the heading positions counted by the same
    /// walker that produced `onTextExtracted`. See `MarkdownDOMTOCEntry`.
    var onTOCExtracted: (([MarkdownDOMTOCEntry]) -> Void)? = nil
    /// Called once after rendering with `wordIndex → PauseableBlock` for every
    /// `.rsvp-formula` / `.rsvp-image` / `.rsvp-code` / `.rsvp-table` placeholder,
    /// indexed against the same word stream `onTextExtracted` posts. Used by
    /// `FileInputView` to override the Swift-built `pauseableBlocks` map.
    var onPauseableBlocksExtracted: (([Int: PauseableBlock]) -> Void)? = nil
    /// Word that replaces every formula in the RSVP stream and is rendered (off-screen
    /// for the user, visible to the DOM TreeWalker) inside `.rsvp-formula-token`.
    /// Defaults to `RSVPEngine.placeholderFormula` so PDF highlight views and the JS pipeline
    /// agree on the same string — see `RSVPEngine.placeholderWords`.
    var formulaPlaceholder: String = RSVPEngine.placeholderFormula
    /// Same idea as `formulaPlaceholder`, but for `<img>` elements — each image becomes one
    /// "image" word in the RSVP stream while the actual image is shown in the preview.
    var imagePlaceholder: String = RSVPEngine.placeholderImage
    /// Each fenced/indented code block (`<pre>`) collapses to a single "code" word in the RSVP
    /// stream while the actual block stays visible in the preview. Inline `<code>` is unaffected.
    var codePlaceholder: String = RSVPEngine.placeholderCode
    /// Each `<table>` collapses to a single "table" word in the RSVP stream while the actual
    /// table stays visible in the preview. Mirrors `codePlaceholder` for GFM tables.
    var tablePlaceholder: String = RSVPEngine.placeholderTable
    /// Optional out-binding for the underlying WKWebView. `SearchablePreviewContainer` uses
    /// this ref to drive ⌘F search via `WKWebViewSearchTarget`.
    var webViewRef: Binding<WKWebView?>? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "wordClicked")
        config.userContentController.add(context.coordinator, name: "textExtracted")
        config.userContentController.add(context.coordinator, name: "tocExtracted")
        config.userContentController.add(context.coordinator, name: "pauseableBlocksExtracted")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.enableInspectorInDebug()
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.onWordSelected = onWordSelected
        context.coordinator.onTextExtracted = onTextExtracted
        context.coordinator.onTOCExtracted = onTOCExtracted
        context.coordinator.onPauseableBlocksExtracted = onPauseableBlocksExtracted
        if let webViewRef {
            DispatchQueue.main.async { webViewRef.wrappedValue = webView }
        }

        let raw: String
        if let markdownString {
            raw = markdownString
        } else if let url, let fileContent = try? String(contentsOf: url, encoding: .utf8) {
            raw = fileContent
        } else {
            return webView
        }

        guard let jsURL = Bundle.main.url(forResource: "Marked", withExtension: "js"),
              let markedJS = try? String(contentsOf: jsURL, encoding: .utf8) else {
            return webView
        }
        let footnoteJS = (Bundle.main.url(forResource: "MarkedFootnote", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let emojiJS = (Bundle.main.url(forResource: "MarkedEmoji", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""

        context.coordinator.pendingIndex = wordIndex
        context.coordinator.pendingSelectionMode = isSelectingStart
        let html = buildShell(markedJS: markedJS, footnoteJS: footnoteJS, emojiJS: emojiJS, markdown: raw, formulaPlaceholder: formulaPlaceholder, imagePlaceholder: imagePlaceholder, codePlaceholder: codePlaceholder, tablePlaceholder: tablePlaceholder)
        webView.loadHTMLString(html, baseURL: url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onWordSelected = onWordSelected
        context.coordinator.onTextExtracted = onTextExtracted
        context.coordinator.onTOCExtracted = onTOCExtracted
        context.coordinator.onPauseableBlocksExtracted = onPauseableBlocksExtracted
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
        var onTextExtracted: ((String) -> Void)?
        var onTOCExtracted: (([MarkdownDOMTOCEntry]) -> Void)?
        var onPauseableBlocksExtracted: (([Int: PauseableBlock]) -> Void)?
        private var isLoaded = false
        private var textAlreadyExtracted = false

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
            } else if message.name == "textExtracted", let text = message.body as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onTextExtracted?(text)
                }
            } else if message.name == "tocExtracted", let raw = message.body as? [[String: Any]] {
                // JS posts `[{level: Int, title: String, wordIndex: Int}, ...]`.
                let entries: [MarkdownDOMTOCEntry] = raw.compactMap { dict in
                    guard let title = dict["title"] as? String,
                          let level = dict["level"] as? Int,
                          let idx = dict["wordIndex"] as? Int else { return nil }
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    return MarkdownDOMTOCEntry(title: trimmed, level: max(1, level), wordIndex: idx)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onTOCExtracted?(entries)
                }
            } else if message.name == "pauseableBlocksExtracted", let raw = message.body as? [[String: Any]] {
                let blocks = decodePauseableBlocks(raw)
                DispatchQueue.main.async { [weak self] in
                    self?.onPauseableBlocksExtracted?(blocks)
                }
            }
        }

        /// JS posts `[{kind: String, wordIndex: Int, payload: {…}}, …]` where
        /// `payload` shape varies by kind:
        ///   - formula: { latex, display }
        ///   - image:   { src, alt }
        ///   - code:    { source, language? }
        ///   - table:   { html, columnCount }
        /// Skips entries with empty payloads so we don't shadow a real pause beat
        /// with a degenerate one (e.g. empty-html PDF table heuristic ports).
        private func decodePauseableBlocks(_ raw: [[String: Any]]) -> [Int: PauseableBlock] {
            var result: [Int: PauseableBlock] = [:]
            for dict in raw {
                guard let kind = dict["kind"] as? String,
                      let wordIndex = dict["wordIndex"] as? Int,
                      let payload = dict["payload"] as? [String: Any] else { continue }
                switch kind {
                case "formula":
                    guard let latex = payload["latex"] as? String else { continue }
                    let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        result[wordIndex] = .formula(latex: trimmed, caption: nil)
                    }
                case "image":
                    guard let src = payload["src"] as? String else { continue }
                    let altRaw = payload["alt"] as? String
                    let caption = (altRaw?.isEmpty == false) ? altRaw : nil
                    if let ref = ImageRef.from(src: src, caption: caption) {
                        result[wordIndex] = .image(ref)
                    }
                case "code":
                    guard let source = payload["source"] as? String else { continue }
                    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let language = payload["language"] as? String
                        result[wordIndex] = .code(language: language, source: source)
                    }
                case "table":
                    guard let html = payload["html"] as? String else { continue }
                    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let columnCount = payload["columnCount"] as? Int ?? 0
                        result[wordIndex] = .table(html: trimmed, columnCount: columnCount, caption: nil)
                    }
                default:
                    break
                }
            }
            return result
        }

        /// Highlights the word at the given index (0-based) in DOM order.
        /// Uses the same word regex as RSVPEngine.splitText() to keep counts in sync.
        func highlightWordAt(index: Int) {
            guard isLoaded, let webView else { return }
            let role = highlightRole
            let hlClass = HighlightStyle.cssClass(for: role)
            let hlStyle = HighlightStyle.cssDeclaration(for: role)
            let placeholderBg = HighlightStyle.cssBackground(for: role)
            let placeholderBorder = HighlightStyle.cssBorder(for: role).map { "border:\($0);" } ?? ""
            let js = """
            (function(targetIndex) {
                // Reset previous highlight (every role we paint).
                var prev = document.querySelector('\(HighlightStyle.highlightSpanSelector)');
                if (prev) {
                    var p = prev.parentNode;
                    p.replaceChild(document.createTextNode(prev.textContent), prev);
                    p.normalize();
                }
                var prevPlaceholders = document.querySelectorAll('.rsvp-formula[data-rsvp-active], .rsvp-image[data-rsvp-active], .rsvp-code[data-rsvp-active], .rsvp-table[data-rsvp-active]');
                for (var pi = 0; pi < prevPlaceholders.length; pi++) {
                    var pp = prevPlaceholders[pi];
                    pp.removeAttribute('data-rsvp-active');
                    pp.style.background = '';
                    pp.style.borderRadius = '';
                    pp.style.padding = '';
                    pp.style.border = '';
                }
                if (targetIndex < 0) return;

                var WORD_RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;

                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                    acceptNode: function(n) {
                        if (!n.parentElement) return NodeFilter.FILTER_ACCEPT;
                        if (n.parentElement.closest('.katex')) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('.rsvp-formula-render')) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('pre')) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('table')) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('.sr-only')) return NodeFilter.FILTER_REJECT;
                        if (n.parentElement.closest('.footnote-backref')) return NodeFilter.FILTER_REJECT;
                        return NodeFilter.FILTER_ACCEPT;
                    }
                });
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
                            // Placeholder token (formula / image / code): highlight the wrapper
                            // rather than wrapping the off-screen text.
                            var placeholderEl = node.parentElement && node.parentElement.closest('.rsvp-formula, .rsvp-image, .rsvp-code, .rsvp-table');
                            if (placeholderEl) {
                                placeholderEl.style.background = '\(placeholderBg)';
                                placeholderEl.style.borderRadius = '4px';
                                placeholderEl.style.padding = '0 2px';
                                placeholderEl.style.cssText += ';\(placeholderBorder)';
                                placeholderEl.setAttribute('data-rsvp-active', '1');
                                // Scroll the visible content (KaTeX render / <img> / <pre>) — the
                                // wrapper's bounding box includes the off-screen token at
                                // top:-9999px, which would jump scroll to the top of the document.
                                var visibleEl = placeholderEl.querySelector('.rsvp-formula-render, img, pre, table');
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

    // MARK: - HTML shell (marked.js parses markdown at page load time)

    /// Builds a self-contained HTML page that embeds marked.js and the raw Markdown source.
    /// At page load the script runs `document.body.innerHTML = marked.parse(src)` so the
    /// rendered output matches what MarkdownUI's .gitHub theme produces visually.
    ///
    /// `formulaPlaceholder` replaces every LaTeX formula in the RSVP word stream and is
    /// rendered (off-screen for the user, visible to the DOM TreeWalker) inside
    /// `.rsvp-formula-token`. The original LaTeX is rendered visibly via KaTeX inside a
    /// sibling `.rsvp-formula-render`.
    private func buildShell(markedJS: String, footnoteJS: String, emojiJS: String, markdown: String, formulaPlaceholder: String, imagePlaceholder: String, codePlaceholder: String, tablePlaceholder: String) -> String {
        // JSON-encode the markdown so it lands in JS as a plain string literal
        // (`"..."`) instead of a template literal (`` `...` ``). PDF2MD output
        // can contain `${`, unescaped backticks, or Unicode line separators that
        // a template literal mishandles — that breaks the whole `<script>` parse
        // before the try/catch even runs, leaving `<body>` empty.
        let markdownJSLiteral: String = {
            if let data = try? JSONEncoder().encode(markdown),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\"\""
        }()
        let escapedPlaceholder = jsStringEscape(formulaPlaceholder)
        let escapedImagePlaceholder = jsStringEscape(imagePlaceholder)
        let escapedCodePlaceholder = jsStringEscape(codePlaceholder)
        let escapedTablePlaceholder = jsStringEscape(tablePlaceholder)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.css">
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            font-size: 15px;
            line-height: 1.7;
            padding: 16px 20px;
            margin: 0;
            word-wrap: break-word;
            color: #24292f;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #e6edf3; background: transparent; }
            code, pre { background: #161b22 !important; }
            blockquote { border-color: #30363d; color: #8b949e; }
            a { color: #58a6ff; }
            table th, table td { border-color: #30363d; }
            hr { border-color: #21262d; }
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            margin-top: 24px;
            margin-bottom: 16px;
            line-height: 1.25;
        }
        h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid #d0d7de; }
        h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid #d0d7de; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: 0.875em; }
        h6 { font-size: 0.85em; color: #57606a; }
        p { margin-top: 0; margin-bottom: 16px; }
        blockquote {
            margin: 0 0 16px 0;
            padding: 0 1em;
            color: #57606a;
            border-left: 0.25em solid #d0d7de;
        }
        code {
            font-family: "SF Mono", Menlo, Consolas, monospace;
            font-size: 85%;
            background: #afb8c133;
            padding: 0.2em 0.4em;
            border-radius: 6px;
        }
        pre {
            background: #f6f8fa;
            border-radius: 6px;
            padding: 16px;
            overflow-x: auto;
            margin-bottom: 16px;
            font-size: 85%;
        }
        pre code { background: none; padding: 0; font-size: 100%; }
        ul, ol { margin-top: 0; margin-bottom: 16px; padding-left: 2em; }
        li { margin-bottom: 4px; }
        li > ul, li > ol { margin-top: 4px; margin-bottom: 0; }
        table { border-collapse: collapse; margin-bottom: 16px; width: 100%; }
        table th, table td {
            border: 1px solid #d0d7de;
            padding: 6px 13px;
        }
        table th { font-weight: 600; background: #f6f8fa; }
        table tr:nth-child(2n) { background: #f6f8fa; }
        hr { height: 0.25em; background: #d0d7de; border: 0; margin: 24px 0; }
        a { color: #0969da; text-decoration: none; }
        a:hover { text-decoration: underline; }
        img { max-width: 100%; }
        body.selecting { cursor: pointer; -webkit-user-select: none; user-select: none; }
        /* Placeholders: visible to TreeWalker, invisible to user */
        .rsvp-formula { display: inline; position: relative; }
        .rsvp-formula-token, .rsvp-image-token, .rsvp-code-token, .rsvp-table-token {
            position: absolute; left: -9999px; top: -9999px;
            width: 1px; height: 1px; overflow: hidden;
            pointer-events: none;
        }
        .rsvp-formula-render { display: inline; }
        .rsvp-formula .katex-display { display: inline-block; margin: 0; }
        .rsvp-image { display: inline-block; position: relative; }
        .rsvp-code { display: block; position: relative; }
        /* Footnotes (marked-footnote extension) */
        .sr-only {
            position: absolute; left: -9999px; top: -9999px;
            width: 1px; height: 1px; overflow: hidden;
        }
        .footnotes {
            margin-top: 32px; padding-top: 16px;
            border-top: 1px solid #d0d7de;
            font-size: 0.9em; color: #57606a;
        }
        @media (prefers-color-scheme: dark) {
            .footnotes { border-top-color: #30363d; color: #8b949e; }
        }
        .footnotes ol { padding-left: 1.5em; }
        .footnotes li { margin-bottom: 8px; }
        .footnotes p { margin: 0; display: inline; }
        .footnote-ref a { text-decoration: none; }
        .footnote-backref {
            text-decoration: none;
            margin-left: 4px;
            opacity: 0.6;
        }
        .footnote-backref:hover { opacity: 1; }
        /* Custom containers (markdown-it-container): ::: warning ... ::: -> div.container-warning */
        div[class^="container-"] {
            margin: 16px 0;
            padding: 12px 16px;
            border-left: 4px solid #d0d7de;
            background: #f6f8fa;
            border-radius: 4px;
        }
        div[class^="container-"] > p:first-child { margin-top: 0; }
        div[class^="container-"] > p:last-child { margin-bottom: 0; }
        .container-warning { border-left-color: #d29922; background: #fff8c5; }
        .container-danger, .container-error { border-left-color: #cf222e; background: #ffebe9; }
        .container-tip, .container-success { border-left-color: #1a7f37; background: #dafbe1; }
        .container-info, .container-note { border-left-color: #0969da; background: #ddf4ff; }
        @media (prefers-color-scheme: dark) {
            div[class^="container-"] { border-left-color: #30363d; background: #161b22; }
            .container-warning { border-left-color: #bb8009; background: #2d2008; }
            .container-danger, .container-error { border-left-color: #f85149; background: #2d0a0a; }
            .container-tip, .container-success { border-left-color: #3fb950; background: #0a2218; }
            .container-info, .container-note { border-left-color: #58a6ff; background: #0c1f33; }
        }
        /* Definition lists (markdown-it-deflist) */
        dl { margin: 12px 0; }
        dt { font-weight: 600; margin-top: 8px; }
        dd { margin-left: 1.5em; margin-bottom: 4px; }
        /* Inserted / marked text */
        ins { text-decoration: underline; text-decoration-color: #2da44e; }
        mark { background: #fff8c5; padding: 0 2px; border-radius: 2px; }
        @media (prefers-color-scheme: dark) {
            ins { text-decoration-color: #3fb950; }
            mark { background: #3a2d00; color: #f0f6fc; }
        }
        \(SearchJS.css)
        </style>
        </head>
        <body>
        <script>
        \(markedJS)
        </script>
        <script>
        \(footnoteJS)
        </script>
        <script>
        \(emojiJS)
        </script>
        <script>
        // Register the footnote extension if it loaded successfully.
        // description:'' suppresses the auto-inserted "Footnotes" heading; we render the
        // footnotes section with a top divider via CSS instead.
        if (typeof markedFootnote === 'function' && typeof marked !== 'undefined') {
            try { marked.use(markedFootnote({description: ''})); } catch (e) { /* ignore */ }
        }
        // Register the emoji extension. The default renderer emits <img> assuming the value
        // is a URL; we override to emit the unicode char directly so :wink: -> 😉 (which
        // the RSVP walker counts as one word via \\p{Extended_Pictographic}).
        if (typeof markedEmoji === 'object' && typeof markedEmoji.markedEmoji === 'function' &&
            typeof window.__rsvpEmojiMap === 'object' && typeof marked !== 'undefined') {
            try {
                marked.use(markedEmoji.markedEmoji({
                    emojis: window.__rsvpEmojiMap,
                    renderer: function(token) { return token.emoji; }
                }));
            } catch (e) { /* ignore */ }
        }
        // Register custom marked extensions: subscript/superscript, ins, mark, custom containers.
        //   H~2~O           -> H<sub>2</sub>O                            (markdown-it-sub)
        //   19^th^          -> 19<sup>th</sup>                           (markdown-it-sup)
        //   ++text++        -> <ins>text</ins>                           (markdown-it-ins)
        //   ==text==        -> <mark>text</mark>                         (markdown-it-mark)
        //   ::: name ... :::-> <div class="container-name"> ... </div>   (markdown-it-container)
        // Sub specifically rejects ~~strike~~ (second char must not be ~, closing ~ must not be
        // followed by ~) so GFM strikethrough still wins.
        if (typeof marked !== 'undefined') {
            try {
                var _esc = function(s) {
                    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                };
                marked.use({extensions: [
                    {
                        name: 'sub',
                        level: 'inline',
                        start: function(src) { var i = src.indexOf('~'); return i === -1 ? undefined : i; },
                        tokenizer: function(src) {
                            if (src[0] !== '~' || src[1] === '~') return;
                            var match = /^~([^~\\s]+)~/.exec(src);
                            if (!match) return;
                            if (src[match[0].length] === '~') return;
                            return { type: 'sub', raw: match[0], text: match[1] };
                        },
                        renderer: function(token) { return '<sub>' + _esc(token.text) + '</sub>'; }
                    },
                    {
                        name: 'sup',
                        level: 'inline',
                        start: function(src) { var i = src.indexOf('^'); return i === -1 ? undefined : i; },
                        tokenizer: function(src) {
                            var match = /^\\^([^\\^\\s]+)\\^/.exec(src);
                            if (!match) return;
                            return { type: 'sup', raw: match[0], text: match[1] };
                        },
                        renderer: function(token) { return '<sup>' + _esc(token.text) + '</sup>'; }
                    },
                    {
                        name: 'ins',
                        level: 'inline',
                        start: function(src) { var i = src.indexOf('++'); return i === -1 ? undefined : i; },
                        tokenizer: function(src) {
                            // ++text++ — content may contain spaces but cannot start/end with whitespace
                            // and cannot contain another ++. Anchored, non-greedy.
                            var match = /^\\+\\+(?!\\s)([^\\n]*?[^\\s])\\+\\+/.exec(src);
                            if (!match) return;
                            if (match[1].indexOf('++') !== -1) return;
                            var inlineTokens = [];
                            this.lexer.inline(match[1], inlineTokens);
                            return { type: 'ins', raw: match[0], text: match[1], tokens: inlineTokens };
                        },
                        renderer: function(token) {
                            return '<ins>' + this.parser.parseInline(token.tokens) + '</ins>';
                        }
                    },
                    {
                        name: 'mark',
                        level: 'inline',
                        start: function(src) { var i = src.indexOf('=='); return i === -1 ? undefined : i; },
                        tokenizer: function(src) {
                            var match = /^==(?!\\s)([^\\n]*?[^\\s])==/.exec(src);
                            if (!match) return;
                            if (match[1].indexOf('==') !== -1) return;
                            var inlineTokens = [];
                            this.lexer.inline(match[1], inlineTokens);
                            return { type: 'mark', raw: match[0], text: match[1], tokens: inlineTokens };
                        },
                        renderer: function(token) {
                            return '<mark>' + this.parser.parseInline(token.tokens) + '</mark>';
                        }
                    },
                    {
                        name: 'container',
                        level: 'block',
                        start: function(src) { var m = src.match(/^:::[ \\t]*\\w/m); return m ? m.index : undefined; },
                        tokenizer: function(src) {
                            var match = /^:::[ \\t]*([\\w-]+)[ \\t]*\\n([\\s\\S]*?)\\n:::[ \\t]*(?:\\n|$)/.exec(src);
                            if (!match) return;
                            var blockTokens = [];
                            this.lexer.blockTokens(match[2], blockTokens);
                            return {
                                type: 'container',
                                raw: match[0],
                                className: match[1],
                                tokens: blockTokens
                            };
                        },
                        renderer: function(token) {
                            return '<div class="container-' + _esc(token.className) +
                                '">' + this.parser.parse(token.tokens) + '</div>\\n';
                        }
                    }
                ]});
            } catch (e) { /* ignore */ }
        }
        </script>
        <script>
        // === Formula pre-processing: protect $...$, $$...$$, \\(...\\), \\[...\\] from marked.js ===
        window.__rsvpFormulas = [];
        var FORMULA_PLACEHOLDER = "\(escapedPlaceholder)";
        var IMAGE_PLACEHOLDER = "\(escapedImagePlaceholder)";
        var CODE_PLACEHOLDER = "\(escapedCodePlaceholder)";
        var TABLE_PLACEHOLDER = "\(escapedTablePlaceholder)";

        // Generic helper: walks text, applies fn to "prose" segments only (skips fenced code blocks
        // and inline `code` spans verbatim). Used by typography + abbreviation pre-processors.
        function processOutsideCode(text, fn) {
            var out = '';
            var i = 0;
            var N = text.length;
            var __iters = 0;
            while (i < N) {
                __iters++;
                if (__iters > N * 4 + 1000) {
                    return out + text.slice(i);
                }
                // Fenced code block at line start — pass through verbatim
                if (i === 0 || text[i-1] === '\\n') {
                    var fenceMatch = text.slice(i).match(/^([ \\t]*)(`{3,}|~{3,})/);
                    if (fenceMatch) {
                        var indent = fenceMatch[1];
                        var fenceMarker = fenceMatch[2];
                        var lineEnd = text.indexOf('\\n', i);
                        var pos = lineEnd === -1 ? N : lineEnd + 1;
                        var blockEnd = N;
                        while (pos < N) {
                            var nl = text.indexOf('\\n', pos);
                            var lineText = text.slice(pos, nl === -1 ? N : nl);
                            if (lineText.indexOf(indent) === 0 && lineText.slice(indent.length).indexOf(fenceMarker) === 0) {
                                blockEnd = nl === -1 ? N : nl + 1;
                                break;
                            }
                            if (nl === -1) { blockEnd = N; break; }
                            pos = nl + 1;
                        }
                        out += text.slice(i, blockEnd);
                        i = blockEnd;
                        continue;
                    }
                }
                // Inline code (1+ backticks, matched length)
                if (text[i] === '`') {
                    var n = 0;
                    while (text[i+n] === '`') n++;
                    var fence = '`'.repeat(n);
                    var endC = text.indexOf(fence, i+n);
                    if (endC !== -1) {
                        out += text.slice(i, endC + n);
                        i = endC + n;
                        continue;
                    }
                    // Unterminated inline code (PDF2MD output can drop a stray backtick).
                    // Emit the opening backticks as literal prose-bound text and advance,
                    // otherwise the accumulate loop below breaks immediately on the same
                    // backtick and we spin forever — see WATCHDOG bailouts pre-fix.
                    out += fn(text.slice(i, i + n));
                    i += n;
                    continue;
                }
                // Accumulate plain segment until next code marker or line that opens a fence
                var startSeg = i;
                while (i < N) {
                    if (text[i] === '`') break;
                    if (text[i] === '\\n' && i + 1 < N) {
                        var rest = text.slice(i+1);
                        if (/^[ \\t]*(`{3,}|~{3,})/.test(rest)) { i++; break; }
                    }
                    i++;
                }
                out += fn(text.slice(startSeg, i));
            }
            return out;
        }

        // Typographic replacements (markdown-it default subset, conservative to avoid surprises):
        // (c)/(C) -> ©, (r)/(R) -> ®, (tm)/(TM) -> ™, +- -> ±, --- -> em-dash, -- -> en-dash, ... -> …
        // Smart quotes intentionally NOT replaced (locale-dependent and easy to break in code/regex).
        // Dash replacements are skipped on structural lines — GFM table separators (`| --- | --- |`),
        // Setext H2 underlines (`---`), and HR (`---` / `- - -`) — otherwise marked.parse stops
        // recognizing them and the table renders as a single header row of plain text.
        function preprocessTypography(text) {
            return processOutsideCode(text, function(s) {
                s = s
                    .replace(/\\(c\\)/gi, '\\u00a9')
                    .replace(/\\(r\\)/gi, '\\u00ae')
                    .replace(/\\(tm\\)/gi, '\\u2122')
                    .replace(/\\+-/g, '\\u00b1')
                    .replace(/\\.\\.\\./g, '\\u2026');
                var lines = s.split('\\n');
                for (var i = 0; i < lines.length; i++) {
                    var trimmed = lines[i].trim();
                    var isDashStructural = trimmed.length > 0 &&
                        /^[\\s\\-:|]+$/.test(trimmed) &&
                        /-/.test(trimmed);
                    if (isDashStructural) continue;
                    lines[i] = lines[i].replace(/---/g, '\\u2014').replace(/--/g, '\\u2013');
                }
                return lines.join('\\n');
            });
        }

        // Abbreviations (markdown-it-abbr): `*[X]: Definition` lines define abbreviations; occurrences
        // of X in body prose get wrapped in <abbr title="Definition">X</abbr>. Word-boundary matching
        // (so `xxxHTMLyyy` is left alone). The wrapped HTML is inline HTML — marked passes it through.
        function preprocessAbbreviations(text) {
            var lines = text.split('\\n');
            var stripped = [];
            var abbrs = {};
            var inFence = false;
            for (var li = 0; li < lines.length; li++) {
                if (/^[ \\t]*(`{3,}|~{3,})/.test(lines[li])) inFence = !inFence;
                if (!inFence) {
                    var m = lines[li].match(/^\\*\\[([^\\]]+)\\]:[ \\t]+(.+)$/);
                    if (m) { abbrs[m[1]] = m[2]; continue; }
                }
                stripped.push(lines[li]);
            }
            var keys = Object.keys(abbrs);
            if (keys.length === 0) return stripped.join('\\n');
            keys.sort(function(a, b) { return b.length - a.length; });
            var escapedKeys = keys.map(function(k) { return k.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'); });
            var bigRe = new RegExp('\\\\b(' + escapedKeys.join('|') + ')\\\\b', 'g');
            return processOutsideCode(stripped.join('\\n'), function(seg) {
                return seg.replace(bigRe, function(_match, key) {
                    var title = abbrs[key]
                        .replace(/&/g, '&amp;')
                        .replace(/</g, '&lt;')
                        .replace(/>/g, '&gt;')
                        .replace(/"/g, '&quot;');
                    return '<abbr title="' + title + '">' + key + '</abbr>';
                });
            });
        }

        // Definition lists (markdown-it-deflist) — basic single-paragraph form:
        //   Term
        //   [optional blank line]
        //   :   Definition
        // Multiple `:   def` lines after one term produce multiple <dd>. Multi-paragraph definitions
        // (with indented continuation paragraphs / nested code) are NOT handled — those render as in
        // upstream markdown source.
        function preprocessDefLists(text) {
            var lines = text.split('\\n');
            var out = [];
            var i = 0;
            var inFence = false;
            var DEF_RE = /^[ ]{0,3}:[ \\t]+(.+)$/;
            var isStructural = function(s) {
                return s.trim() === '' || /^\\s/.test(s) || /^[#>*+\\-]\\s/.test(s) ||
                       /^\\d+\\.\\s/.test(s) || /^[ ]{0,3}:[ \\t]/.test(s) || /^---+$/.test(s);
            };
            while (i < lines.length) {
                if (/^[ \\t]*(`{3,}|~{3,})/.test(lines[i])) inFence = !inFence;
                if (inFence) { out.push(lines[i]); i++; continue; }
                if (isStructural(lines[i])) { out.push(lines[i]); i++; continue; }

                // Look ahead through optional blank line(s) for a `:   def` line
                var lookI = i + 1;
                while (lookI < lines.length && lines[lookI].trim() === '') lookI++;
                if (!(lookI < lines.length && DEF_RE.test(lines[lookI]))) {
                    out.push(lines[i]); i++; continue;
                }

                var dl = ['<dl>'];
                while (i < lines.length) {
                    if (isStructural(lines[i])) break;
                    var term = lines[i].trim();
                    var afterTerm = i + 1;
                    while (afterTerm < lines.length && lines[afterTerm].trim() === '') afterTerm++;
                    if (afterTerm >= lines.length || !DEF_RE.test(lines[afterTerm])) break;
                    dl.push('<dt>' + term + '</dt>');
                    i = afterTerm;
                    while (i < lines.length && DEF_RE.test(lines[i])) {
                        var defLine = lines[i].match(DEF_RE)[1];
                        i++;
                        // Lazy continuation: subsequent non-empty unindented lines that aren't a new
                        // term/def belong to the same definition.
                        while (i < lines.length && lines[i].trim() !== '' &&
                               !DEF_RE.test(lines[i]) && !/^\\s/.test(lines[i])) {
                            defLine += ' ' + lines[i].trim();
                            i++;
                        }
                        dl.push('<dd>' + defLine + '</dd>');
                    }
                    while (i < lines.length && lines[i].trim() === '') i++;
                }
                dl.push('</dl>');
                out.push('');
                out.push(dl.join('\\n'));
                out.push('');
            }
            return out.join('\\n');
        }

        function preprocessFormulas(text, store) {
            var out = '';
            var i = 0;
            var N = text.length;
            function pushFormula(latex, display) {
                var idx = store.length;
                store.push({latex: latex, display: display});
                return '@@RSVP_FORMULA_' + idx + '@@';
            }
            while (i < N) {
                var ch = text[i];
                // Fenced code block at line start — pass through verbatim
                if (i === 0 || text[i-1] === '\\n') {
                    var fenceMatch = text.slice(i).match(/^([ \\t]*)(`{3,}|~{3,})/);
                    if (fenceMatch) {
                        var indent = fenceMatch[1];
                        var fenceMarker = fenceMatch[2];
                        var lineEnd = text.indexOf('\\n', i);
                        var pos = lineEnd === -1 ? N : lineEnd + 1;
                        var blockEnd = N;
                        while (pos < N) {
                            var nl = text.indexOf('\\n', pos);
                            var lineText = text.slice(pos, nl === -1 ? N : nl);
                            if (lineText.indexOf(indent) === 0 && lineText.slice(indent.length).indexOf(fenceMarker) === 0) {
                                blockEnd = nl === -1 ? N : nl + 1;
                                break;
                            }
                            if (nl === -1) { blockEnd = N; break; }
                            pos = nl + 1;
                        }
                        out += text.slice(i, blockEnd);
                        i = blockEnd;
                        continue;
                    }
                }
                // Backslash escape and \\(...\\) / \\[...\\] math delimiters
                if (ch === '\\\\') {
                    if (text[i+1] === '(') {
                        var endP = text.indexOf('\\\\)', i+2);
                        if (endP !== -1) {
                            out += pushFormula(text.slice(i+2, endP), false);
                            i = endP + 2;
                            continue;
                        }
                    }
                    if (text[i+1] === '[') {
                        var endB = text.indexOf('\\\\]', i+2);
                        if (endB !== -1) {
                            out += pushFormula(text.slice(i+2, endB), true);
                            i = endB + 2;
                            continue;
                        }
                    }
                    out += text[i] + (text[i+1] || '');
                    i += 2;
                    continue;
                }
                // Inline code (1+ backticks, matched length)
                if (ch === '`') {
                    var n = 0;
                    while (text[i+n] === '`') n++;
                    var fence = '`'.repeat(n);
                    var endC = text.indexOf(fence, i+n);
                    if (endC !== -1) {
                        out += text.slice(i, endC + n);
                        i = endC + n;
                        continue;
                    }
                    out += text.slice(i, i+n);
                    i += n;
                    continue;
                }
                // $$...$$ display math (multi-line OK)
                if (ch === '$' && text[i+1] === '$') {
                    var endD = text.indexOf('$$', i+2);
                    if (endD !== -1 && endD > i+2) {
                        out += pushFormula(text.slice(i+2, endD), true);
                        i = endD + 2;
                        continue;
                    }
                }
                // $...$ inline math — Pandoc-style: opening $ followed by non-space,
                // closing $ preceded by non-space and not followed by a digit (to avoid
                // currency like "$5 to $10").
                if (ch === '$') {
                    var nextCh = text[i+1];
                    var openOK = nextCh && nextCh !== ' ' && nextCh !== '\\t' && nextCh !== '\\n' && nextCh !== '$';
                    if (openOK) {
                        var endI = -1;
                        for (var j = i+1; j < N; j++) {
                            if (text[j] === '\\\\') { j++; continue; }
                            if (text[j] === '\\n') break;
                            if (text[j] === '$') {
                                var prevCh = text[j-1];
                                if (prevCh !== ' ' && prevCh !== '\\t' && prevCh !== '\\n') {
                                    var afterCh = text[j+1];
                                    if (!afterCh || !/[0-9]/.test(afterCh)) {
                                        endI = j;
                                    }
                                }
                                break;
                            }
                        }
                        if (endI !== -1 && endI > i+1) {
                            var latex = text.slice(i+1, endI);
                            out += pushFormula(latex, false);
                            i = endI + 1;
                            continue;
                        }
                    }
                }
                out += ch;
                i++;
            }
            return out;
        }

        function injectFormulaTokens() {
            var tokenRe = /@@RSVP_FORMULA_(\\d+)@@/;
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var nodes = [];
            var n;
            while (n = walker.nextNode()) {
                if (tokenRe.test(n.textContent)) nodes.push(n);
            }
            var RE_G = /@@RSVP_FORMULA_(\\d+)@@/g;
            for (var k = 0; k < nodes.length; k++) {
                var node = nodes[k];
                var text = node.textContent;
                var parent = node.parentNode;
                var lastIdx = 0;
                RE_G.lastIndex = 0;
                var m;
                while ((m = RE_G.exec(text)) !== null) {
                    if (m.index > lastIdx) {
                        parent.insertBefore(document.createTextNode(text.slice(lastIdx, m.index)), node);
                    }
                    var fIdx = parseInt(m[1], 10);
                    var data = window.__rsvpFormulas[fIdx];
                    if (data) {
                        var wrap = document.createElement('span');
                        wrap.className = 'rsvp-formula';
                        wrap.dataset.formulaIdx = String(fIdx);
                        var tok = document.createElement('span');
                        tok.className = 'rsvp-formula-token';
                        tok.textContent = FORMULA_PLACEHOLDER;
                        var ren = document.createElement('span');
                        ren.className = 'rsvp-formula-render';
                        ren.dataset.latex = data.latex;
                        ren.dataset.display = data.display ? '1' : '0';
                        wrap.appendChild(tok);
                        wrap.appendChild(ren);
                        parent.insertBefore(wrap, node);
                    }
                    lastIdx = m.index + m[0].length;
                }
                if (lastIdx < text.length) {
                    parent.insertBefore(document.createTextNode(text.slice(lastIdx)), node);
                }
                parent.removeChild(node);
            }
        }

        function wrapImages() {
            // Wrap every <img> with an off-screen "image" token + the original element so the
            // RSVP TreeWalker counts each image as a single placeholder word.
            var imgs = document.querySelectorAll('img');
            for (var k = 0; k < imgs.length; k++) {
                var img = imgs[k];
                if (img.parentElement && img.parentElement.classList.contains('rsvp-image')) continue;
                var wrap = document.createElement('span');
                wrap.className = 'rsvp-image';
                var tok = document.createElement('span');
                tok.className = 'rsvp-image-token';
                tok.textContent = IMAGE_PLACEHOLDER;
                var parent = img.parentNode;
                parent.insertBefore(wrap, img);
                wrap.appendChild(tok);
                wrap.appendChild(img);
            }
        }

        // Block-level wrapper for <pre>/<table>: <div class="rsvp-X"><span off-screen token/><original/></div>.
        // The walker rejects nodes inside <pre>/<table> so the entire block reads as a single placeholder.
        function wrapBlock(el, wrapClass, tokenClass, placeholderText) {
            if (el.parentElement && el.parentElement.classList.contains(wrapClass)) return;
            var wrap = document.createElement('div');
            wrap.className = wrapClass;
            var tok = document.createElement('span');
            tok.className = tokenClass;
            tok.textContent = placeholderText;
            var parent = el.parentNode;
            parent.insertBefore(wrap, el);
            wrap.appendChild(tok);
            wrap.appendChild(el);
        }

        function wrapCodeBlocks() {
            var pres = document.querySelectorAll('pre');
            for (var k = 0; k < pres.length; k++) wrapBlock(pres[k], 'rsvp-code', 'rsvp-code-token', CODE_PLACEHOLDER);
        }

        function wrapTables() {
            var tables = document.querySelectorAll('table');
            for (var k = 0; k < tables.length; k++) wrapBlock(tables[k], 'rsvp-table', 'rsvp-table-token', TABLE_PLACEHOLDER);
        }

        function renderFormulas() {
            if (typeof katex === 'undefined') return;
            var els = document.querySelectorAll('.rsvp-formula-render');
            for (var k = 0; k < els.length; k++) {
                var el = els[k];
                var latex = el.dataset.latex || '';
                var display = el.dataset.display === '1';
                try {
                    katex.render(latex, el, {displayMode: display, throwOnError: false});
                } catch(e) {
                    el.textContent = display ? '$$' + latex + '$$' : '$' + latex + '$';
                }
            }
        }
        window._rsvpRenderFormulas = renderFormulas;

        try {
            var src = \(markdownJSLiteral);
            // Pre-processing pipeline: abbreviations and definition lists run first so their
            // emitted HTML survives subsequent passes; typography runs next; formula tokens last
            // (right before marked.parse) so that protected formulas keep characters like `--`.
            src = preprocessAbbreviations(src);
            src = preprocessDefLists(src);
            src = preprocessTypography(src);
            src = preprocessFormulas(src, window.__rsvpFormulas);
            document.body.innerHTML = marked.parse(src, {gfm: true, breaks: false});
            injectFormulaTokens();
            wrapImages();
            wrapCodeBlocks();
            wrapTables();
        } catch(e) {
            document.body.innerHTML = '<pre style="color:red">Marked.js error: ' + e.message + '</pre>';
        }
        // Extract words from rendered DOM (formula tokens already in place; KaTeX has not loaded yet)
        try {
            var _RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;
            var _w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode: function(n) {
                    if (!n.parentElement) return NodeFilter.FILTER_ACCEPT;
                    if (n.parentElement.closest('script')) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('style')) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('.rsvp-formula-render')) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('.katex')) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('pre')) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('table')) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('.sr-only')) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('.footnote-backref')) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            var _words = [], _n;
            // TOC entries are collected in the SAME walk that produces the canonical
            // word list — so their `wordIndex` values are guaranteed to match the
            // engine's indices after `onTextExtracted` re-syncs the engine to this
            // word stream. Otherwise placeholder tokens (formula/image/code) and
            // any nodes the walker rejects (pre, .katex, .sr-only, …) would shift
            // the TOC offsets relative to the engine.
            var _toc = [];
            // Pauseable blocks are collected in the SAME walk for the same reason
            // as TOC entries: only the JS walker knows the real word indices that
            // the engine will see after `onTextExtracted`. Each placeholder token
            // (`.rsvp-formula-token` / `-image-token` / `-code-token` / `-table-token`)
            // contributes exactly one word, so `wordIndex = _words.length` at the
            // time we visit the token's text node is its index in the engine's stream.
            var _pauseable = [];
            var _seenHeadings = (typeof Set === 'function') ? new Set() : null;
            var _seenHeadingsArr = _seenHeadings ? null : [];
            function _markHeadingSeen(h) {
                if (_seenHeadings) { if (_seenHeadings.has(h)) return false; _seenHeadings.add(h); return true; }
                if (_seenHeadingsArr.indexOf(h) !== -1) return false;
                _seenHeadingsArr.push(h); return true;
            }
            function _collectPauseablePayload(tokenEl, kind) {
                var wrap = tokenEl.parentElement;
                if (!wrap) return null;
                if (kind === 'formula') {
                    var ren = wrap.querySelector('.rsvp-formula-render');
                    if (!ren) return null;
                    return {
                        latex: (ren.dataset && ren.dataset.latex) || '',
                        display: (ren.dataset && ren.dataset.display) === '1'
                    };
                }
                if (kind === 'image') {
                    var img = wrap.querySelector('img');
                    if (!img) return null;
                    return {
                        src: img.getAttribute('src') || '',
                        alt: img.getAttribute('alt') || ''
                    };
                }
                if (kind === 'code') {
                    var pre = wrap.querySelector('pre');
                    if (!pre) return null;
                    var codeEl = pre.querySelector('code') || pre;
                    var lang = null;
                    var cls = (codeEl.className || '') + ' ' + (pre.className || '');
                    var langMatch = cls.match(/(?:language|lang|hljs)-([\\w+#-]+)/i);
                    if (langMatch) lang = langMatch[1].toLowerCase();
                    if (!lang && codeEl.dataset && codeEl.dataset.lang) lang = codeEl.dataset.lang;
                    if (!lang && pre.dataset && pre.dataset.lang) lang = pre.dataset.lang;
                    return {source: codeEl.textContent || '', language: lang};
                }
                if (kind === 'table') {
                    var tbl = wrap.querySelector('table');
                    if (!tbl) return null;
                    var rows = tbl.querySelectorAll('tr');
                    var maxCols = 0;
                    for (var ri = 0; ri < rows.length; ri++) {
                        var cells = rows[ri].querySelectorAll('td,th');
                        if (cells.length > maxCols) maxCols = cells.length;
                    }
                    return {html: tbl.outerHTML, columnCount: maxCols};
                }
                return null;
            }
            while (_n = _w.nextNode()) {
                // Record the heading containing this text node's first accepted word.
                // `closest('h1,h2,...')` returns the nearest heading ancestor (the
                // heading element itself, not a descendant) so a single record per
                // heading is produced even if the heading text spans multiple text
                // nodes (e.g. `## Title <code>foo</code> end`).
                var _hAnc = _n.parentElement && _n.parentElement.closest('h1,h2,h3,h4,h5,h6');
                if (_hAnc && _markHeadingSeen(_hAnc)) {
                    _toc.push({
                        level: parseInt(_hAnc.tagName.substring(1), 10),
                        title: (_hAnc.textContent || '').trim(),
                        wordIndex: _words.length
                    });
                }
                // Placeholder-token text nodes — `wrap*()` produced them as the first
                // child of each `.rsvp-X` wrapper, so we hit them before any sibling
                // content (which the walker rejects anyway for pre/table/.katex).
                var _pe = _n.parentElement;
                if (_pe && _pe.classList) {
                    var _kind = null;
                    if (_pe.classList.contains('rsvp-formula-token'))      _kind = 'formula';
                    else if (_pe.classList.contains('rsvp-image-token'))  _kind = 'image';
                    else if (_pe.classList.contains('rsvp-code-token'))   _kind = 'code';
                    else if (_pe.classList.contains('rsvp-table-token'))  _kind = 'table';
                    if (_kind) {
                        var _payload = _collectPauseablePayload(_pe, _kind);
                        if (_payload) {
                            _pauseable.push({kind: _kind, wordIndex: _words.length, payload: _payload});
                        }
                    }
                }
                var _t = _n.textContent; _RE.lastIndex = 0; var _m;
                while ((_m = _RE.exec(_t)) !== null) _words.push(_m[0]);
            }
            if (_words.length > 0 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.textExtracted) {
                window.webkit.messageHandlers.textExtracted.postMessage(_words.join(' '));
            }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tocExtracted) {
                window.webkit.messageHandlers.tocExtracted.postMessage(_toc);
            }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pauseableBlocksExtracted) {
                window.webkit.messageHandlers.pauseableBlocksExtracted.postMessage(_pauseable);
            }
        } catch(e2) {}
        </script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.js"
                onload="window._rsvpRenderFormulas && window._rsvpRenderFormulas();"></script>
        <script>
        (function() {
            var _selectionMode = false;

            var WORD_RE = /https?:\\/\\/\\S+|["'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*[$€£¥₹₽¢]?[\\p{L}\\p{N}\\p{Extended_Pictographic}]+(?:[.,]\\d+)*(?:[-'][\\p{L}]+)*[%.,!?;:\\u2026"'\\u00AB\\u00BB\\u201E\\u201C\\u201D\\u2018\\u2019\\u201A\\u2039\\u203A]*/gu;

            function _acceptNode(n) {
                if (!n.parentElement) return NodeFilter.FILTER_ACCEPT;
                if (n.parentElement.closest('.katex')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('.rsvp-formula-render')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('script')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('style')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('pre')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('table')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('.sr-only')) return NodeFilter.FILTER_REJECT;
                if (n.parentElement.closest('.footnote-backref')) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
            }

            function _walkWords() {
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {acceptNode: _acceptNode});
                var words = [];
                var node;
                while (node = walker.nextNode()) {
                    var text = node.textContent;
                    WORD_RE.lastIndex = 0;
                    var match;
                    while ((match = WORD_RE.exec(text)) !== null) {
                        words.push(match[0]);
                    }
                }
                return words;
            }

            // Computes the word index of a placeholder's off-screen token by counting words in
            // DOM order until the token span is reached. Used by the click handler when the user
            // clicks anywhere inside a .rsvp-formula (KaTeX render) or .rsvp-image (an <img>).
            function _placeholderWordIndex(placeholderEl) {
                var tokenSpan = placeholderEl.querySelector('.rsvp-formula-token, .rsvp-image-token, .rsvp-code-token, .rsvp-table-token');
                if (!tokenSpan) return -1;
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {acceptNode: _acceptNode});
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

            // Called from Swift after page loads to extract the canonical word list
            window._extractText = function() {
                var words = _walkWords();
                window.webkit.messageHandlers.textExtracted.postMessage(words.join(' '));
            };

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
                    var prevPHs = document.querySelectorAll('.rsvp-formula[data-rsvp-active], .rsvp-image[data-rsvp-active], .rsvp-code[data-rsvp-active], .rsvp-table[data-rsvp-active]');
                    for (var pi = 0; pi < prevPHs.length; pi++) {
                        var pp = prevPHs[pi];
                        pp.removeAttribute('data-rsvp-active');
                        pp.style.background = '';
                        pp.style.borderRadius = '';
                        pp.style.padding = '';
                        pp.style.border = '';
                    }
                }
            };

            document.addEventListener('click', function(e) {
                if (!_selectionMode) return;
                e.preventDefault();

                // Reset previous highlight (both forms)
                var prev = document.querySelector('\(HighlightStyle.highlightSpanSelector)');
                if (prev) {
                    var p = prev.parentNode;
                    p.replaceChild(document.createTextNode(prev.textContent), prev);
                    p.normalize();
                }
                var prevPHsClick = document.querySelectorAll('.rsvp-formula[data-rsvp-active], .rsvp-image[data-rsvp-active], .rsvp-code[data-rsvp-active], .rsvp-table[data-rsvp-active]');
                for (var pic = 0; pic < prevPHsClick.length; pic++) {
                    var ppc = prevPHsClick[pic];
                    ppc.removeAttribute('data-rsvp-active');
                    ppc.style.background = '';
                    ppc.style.borderRadius = '';
                    ppc.style.padding = '';
                    ppc.style.border = '';
                }

                // Click landed inside a placeholder (KaTeX / <img> / <pre>) — caretRangeFromPoint
                // can't reach the off-screen token span, so resolve directly.
                var placeholderClickEl = e.target && e.target.closest && e.target.closest('.rsvp-formula, .rsvp-image, .rsvp-code, .rsvp-table');
                if (placeholderClickEl) {
                    var fIdx = _placeholderWordIndex(placeholderClickEl);
                    if (fIdx >= 0) {
                        window.webkit.messageHandlers.wordClicked.postMessage(fIdx);
                    }
                    return;
                }

                // Normal text click via caretRangeFromPoint
                var range = document.caretRangeFromPoint(e.clientX, e.clientY);
                if (!range) return;
                var clickNode = range.startContainer;
                var clickOffset = range.startOffset;
                if (clickNode.nodeType !== 3) return;

                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {acceptNode: _acceptNode});
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
        \(SearchJS.source())
        </script>
        </body>
        </html>
        """
    }

    /// Escape a Swift string for safe interpolation as a JS double-quoted string literal.
    private func jsStringEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
