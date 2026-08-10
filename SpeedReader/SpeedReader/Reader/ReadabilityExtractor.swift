import WebKit

// MARK: - Result

struct DefuddleResult {
    let title: String
    let blocks: [TextBlock]
    let plainText: String
    let author: String?
    let description: String?
    let published: String?
    let domain: String?
    let siteName: String?
    let wordCount: Int
}

// MARK: - Errors

enum DefuddleError: LocalizedError {
    case jsNotFound
    case noContent
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .jsNotFound:
            return "Defuddle.js not found in app bundle"
        case .noContent:
            return "Could not extract article content from this page"
        case .parsingFailed:
            return "Failed to parse page content"
        }
    }
}

// MARK: - Extractor

/// Extracts article text from HTML using Defuddle via an offscreen WKWebView.
/// The WKWebView is used only as a JS engine — it loads the HTML string directly,
/// so no additional network requests are made.
/// Can also load a live URL when `URLSession` hits a bot wall (202/empty body).
@MainActor
final class DefuddleExtractor: NSObject {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<DefuddleResult, Error>?
    private var hasResumed = false
    private var timeoutTask: Task<Void, Never>?
    private var loadedFromURL: URL?

    /// How many times we've re-run Defuddle while waiting for a live URL's
    /// JS to hydrate the DOM (bot walls / SPAs that fill content after load).
    private var extractionRetries = 0
    private static let maxExtractionRetries = 8
    private static let retryDelay: Duration = .milliseconds(700)

    /// Hard cap so a runaway page can never hang the extraction indefinitely.
    private static let extractionTimeout: Duration = .seconds(20)

    /// Content rule list that blocks every subresource load (images, CSS, fonts,
    /// scripts, XHR, …) inside the offscreen extraction WebView. Defuddle only
    /// needs the parsed DOM and reads image URLs as strings via `el.src`, so the
    /// real bytes never need to download. Built once and reused.
    private static var blockAllResourcesRuleList: WKContentRuleList?

    // MARK: - Public API

    static func extract(from html: String, baseURL: URL) async throws -> DefuddleResult {
        let extractor = DefuddleExtractor()
        return try await extractor.run(html: html, baseURL: baseURL)
    }

    /// Loads a live URL in a real browser engine so JS challenges / bot walls
    /// (e.g. ESPN returning 202 with empty body) can be resolved.
    static func extract(from url: URL) async throws -> DefuddleResult {
        let extractor = DefuddleExtractor()
        return try await extractor.run(url: url)
    }

    /// Compiles (or returns the cached) rule list that blocks all subresource loads.
    private static func resourceBlockingRuleList() async -> WKContentRuleList? {
        if let blockAllResourcesRuleList { return blockAllResourcesRuleList }

        // url-filter ".*" matches everything; load-type ["third-party","first-party"]
        // covers all origins. We keep the top "document" alive (loadHTMLString) but
        // block every image / script / stylesheet / font / media subresource.
        let rules = """
        [
          {
            "trigger": { "url-filter": ".*", "resource-type": ["image","style-sheet","script","font","raw","svg-document","media","popup","ping","fetch","websocket","other"] },
            "action": { "type": "block" }
          }
        ]
        """

        let store = WKContentRuleListStore.default()
        let list = try? await store?.compileContentRuleList(
            forIdentifier: "DefuddleBlockAllResources",
            encodedContentRuleList: rules
        )
        blockAllResourcesRuleList = list
        return list
    }

    // MARK: - Private

    private func run(html: String, baseURL: URL) async throws -> DefuddleResult {
        guard let jsURL = Bundle.main.url(forResource: "Defuddle", withExtension: "js"),
              let js = try? String(contentsOf: jsURL, encoding: .utf8) else {
            throw DefuddleError.jsNotFound
        }

        let config = WKWebViewConfiguration()

        // Inject Defuddle once as a user script at document end instead of
        // concatenating the whole minified library into every evaluateJavaScript
        // call (which re-parsed ~hundreds of KB of JS each run).
        let defuddleUserScript = WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(defuddleUserScript)

        // Block all subresource downloads (images/CSS/fonts/etc.) in the offscreen
        // WebView so a 900 KB article with dozens of figures doesn't pull megabytes
        // of image data just to extract text.
        if let ruleList = await Self.resourceBlockingRuleList() {
            config.userContentController.add(ruleList)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.enableInspectorInDebug()
        webView.navigationDelegate = self
        self.webView = webView

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.startTimeout()
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    /// Loads a live URL directly in the WebView so JS challenges and bot walls
    /// (e.g. ESPN 202 Accepted) are resolved by a real browser engine.
    /// We do NOT block scripts here — only images/styles/fonts — so any
    /// JS-based challenge can still execute.
    private func run(url: URL) async throws -> DefuddleResult {
        guard let jsURL = Bundle.main.url(forResource: "Defuddle", withExtension: "js"),
              let js = try? String(contentsOf: jsURL, encoding: .utf8) else {
            throw DefuddleError.jsNotFound
        }

        let config = WKWebViewConfiguration()

        let defuddleUserScript = WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(defuddleUserScript)

        // Block heavy subresources (images, fonts, media) but keep scripts
        // and fetch alive so JS challenges / hydration work.
        let rules = """
        [
          {
            "trigger": { "url-filter": ".*", "resource-type": ["image","style-sheet","font","media","svg-document","popup","ping"] },
            "action": { "type": "block" }
          }
        ]
        """
        let store = WKContentRuleListStore.default()
        if let ruleList = try? await store?.compileContentRuleList(
            forIdentifier: "DefuddleBlockHeavyResources",
            encodedContentRuleList: rules
        ) {
            config.userContentController.add(ruleList)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.enableInspectorInDebug()
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
        self.webView = webView
        self.loadedFromURL = url

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.startTimeout()
            var request = URLRequest(url: url)
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            webView.load(request)
        }
    }

    /// Fails the extraction if the page never finishes loading or the JS hangs.
    private func startTimeout() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.extractionTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finish(.failure(DefuddleError.parsingFailed))
            }
        }
    }

    /// Single resume + teardown point. Safe to call multiple times; only the first
    /// call resumes the continuation. Always releases the WebView so its process
    /// and memory are reclaimed promptly.
    private func finish(_ result: Result<DefuddleResult, Error>) {
        guard !hasResumed else { return }
        hasResumed = true
        timeoutTask?.cancel()
        timeoutTask = nil

        if let webView {
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.removeAllContentRuleLists()
        }
        webView = nil

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    private func runDefuddle() {
        guard let webView else {
            finish(.failure(DefuddleError.parsingFailed))
            return
        }

        let script = """
        (function() {
            try {
                var result = new Defuddle(document).parse();
                if (!result || !result.content) return JSON.stringify({});

                // Parse content HTML into structured blocks
                var div = document.createElement('div');
                div.innerHTML = result.content;

                var blocks = [];

                function getText(node) {
                    return (node.textContent || '').replace(/\\s+/g, ' ').trim();
                }

                // Pulls LaTeX out of an element that wraps a math expression.
                // Covers:
                //   - KaTeX:  <span class="katex"><span class="katex-mathml"><math><semantics>
                //               <annotation encoding="application/x-tex">LATEX</annotation>...
                //   - MathJax v3: <mjx-container><math><semantics><annotation ...>LATEX</annotation>
                //   - Wikipedia/MathML islands: <math><semantics><annotation ...>LATEX</annotation>
                //   - Bare <math>…</math> with no semantics: fall back to alttext attr,
                //     then to textContent (won't render as TeX but at least carries the
                //     symbols so we can still pause on it).
                // Returns null if nothing usable was found.
                function extractLatex(el) {
                    if (!el) return null;
                    var ann = el.querySelector('annotation[encoding="application/x-tex"]');
                    if (ann && ann.textContent && ann.textContent.trim()) return ann.textContent.trim();
                    if (el.tagName && el.tagName.toLowerCase() === 'math') {
                        var alt = el.getAttribute('alttext');
                        if (alt && alt.trim()) return alt.trim();
                    }
                    var script = el.querySelector('script[type="math/tex"], script[type="math/tex; mode=display"]');
                    if (script && script.textContent && script.textContent.trim()) return script.textContent.trim();
                    return null;
                }

                function emitFormula(el, opts) {
                    var latex = extractLatex(el);
                    if (!latex) return false;
                    var displayMode = !!(opts && opts.displayMode);
                    blocks.push({ type: 'formula', text: 'formula', latex: latex, displayMode: displayMode, level: 0 });
                    return true;
                }

                function emitImage(el) {
                    // `el.src` resolves relative and protocol-relative URLs via the document
                    // baseURL set by WKWebView; `getAttribute('src')` returns the raw attribute.
                    // Fall back to common lazy-loading attributes when src is empty/placeholder.
                    var src = el.src || '';
                    if (!src || src.indexOf('data:image/gif;base64,') === 0) {
                        var lazy = el.getAttribute('data-src')
                                || el.getAttribute('data-original')
                                || el.getAttribute('data-lazy-src')
                                || '';
                        if (lazy) {
                            try {
                                src = new URL(lazy, document.baseURI).href;
                            } catch (e) {
                                src = lazy;
                            }
                        }
                    }
                    if (!src) return;
                    // Skip 1x1 tracking pixels
                    var w = parseInt(el.getAttribute('width') || '0', 10);
                    var h = parseInt(el.getAttribute('height') || '0', 10);
                    if (w > 0 && w <= 1) return;
                    if (h > 0 && h <= 1) return;
                    var alt = el.getAttribute('alt') || '';
                    blocks.push({ type: 'image', text: 'image', src: src, alt: alt, level: 0 });
                }

                function processNode(node) {
                    if (node.nodeType === 3) {
                        var text = node.textContent.trim();
                        if (text) blocks.push({ type: 'paragraph', text: text, level: 0 });
                        return;
                    }
                    if (node.nodeType !== 1) return;

                    var tag = node.tagName.toLowerCase();

                    // Images are leaf elements with no textContent — handle before the empty-text guard
                    if (tag === 'img') {
                        emitImage(node);
                        return;
                    }

                    // Math wrappers — handled before the text/empty-text branches so we
                    // never recurse into their MathML/span guts (which would emit garbled
                    // paragraph blocks for each token of the rendered equation).
                    var cls = node.className || '';
                    if (typeof cls !== 'string') cls = cls.baseVal || '';
                    var isKatexDisplay = cls.indexOf('katex-display') !== -1;
                    var isKatexInline  = !isKatexDisplay && cls.indexOf('katex') !== -1;
                    if (tag === 'math' || tag === 'mjx-container' || isKatexDisplay || isKatexInline) {
                        var display = isKatexDisplay
                            || (tag === 'mjx-container' && (node.getAttribute('display') === 'true' || (node.getAttribute('class') || '').indexOf('mjx-block') !== -1))
                            || (tag === 'math' && node.getAttribute('display') === 'block');
                        if (emitFormula(node, { displayMode: display })) return;
                        // Fell through (no LaTeX) — let normal processing render the text.
                    }

                    var text = getText(node);
                    if (!text && tag !== 'hr' && tag !== 'figure') return;

                    if (/^h[1-6]$/.test(tag)) {
                        blocks.push({ type: 'heading', text: text, level: parseInt(tag[1]) });
                    } else if (tag === 'blockquote') {
                        blocks.push({ type: 'quote', text: text, level: 0 });
                    } else if (tag === 'pre') {
                        // Preserve original whitespace for code blocks. Look for
                        // a language hint on the inner <code class="language-X">
                        // (highlight.js / Prism convention) or directly on the
                        // <pre>. Empty hint stays null on the Swift side so the
                        // highlighter can auto-detect.
                        var codeText = node.textContent || '';
                        var inner = node.querySelector('code');
                        var langSource = (inner && inner.className) || node.className || '';
                        var lang = null;
                        var m = langSource.match(/(?:^|\\s)(?:language|lang|hljs)-([\\w+-]+)/i);
                        if (m) {
                            lang = m[1].toLowerCase();
                        } else if (inner && inner.getAttribute('data-lang')) {
                            lang = inner.getAttribute('data-lang').toLowerCase();
                        }
                        blocks.push({ type: 'code', text: 'code', source: codeText, language: lang, level: 0 });
                    } else if (tag === 'ul' || tag === 'ol') {
                        var items = node.querySelectorAll(':scope > li');
                        for (var i = 0; i < items.length; i++) {
                            var prefix = tag === 'ol' ? ((i + 1) + '. ') : '• ';
                            blocks.push({ type: 'list', text: prefix + getText(items[i]), level: 0 });
                        }
                    } else if (tag === 'figure') {
                        var img = node.querySelector('img');
                        if (img) emitImage(img);
                        var caption = node.querySelector('figcaption');
                        if (caption) {
                            var capText = getText(caption);
                            if (capText) blocks.push({ type: 'caption', text: capText, level: 0 });
                        }
                    } else if (tag === 'p') {
                        blocks.push({ type: 'paragraph', text: text, level: 0 });
                    } else if (tag === 'table') {
                        // Emit one structured `.table` block per `<table>` carrying the
                        // raw HTML so the Swift side can hand it to TablePreviewView.
                        // Strip scripts/styles defensively; outerHTML keeps thead/tbody.
                        var clone = node.cloneNode(true);
                        var bad = clone.querySelectorAll('script, style, link, meta');
                        for (var k = 0; k < bad.length; k++) bad[k].remove();
                        // Estimate column count from the widest row (header or first body row).
                        var rows = clone.querySelectorAll('tr');
                        var maxCols = 0;
                        for (var r = 0; r < rows.length; r++) {
                            var cells = rows[r].querySelectorAll('td, th');
                            if (cells.length > maxCols) maxCols = cells.length;
                        }
                        blocks.push({ type: 'table', text: 'table', html: clone.outerHTML, columnCount: maxCols, level: 0 });
                    } else {
                        // For div, section, article, etc. — process children
                        var hasBlockChild = false;
                        for (var i = 0; i < node.children.length; i++) {
                            var childTag = node.children[i].tagName.toLowerCase();
                            if (['p','h1','h2','h3','h4','h5','h6','ul','ol','blockquote','pre','div','section','article','figure','table','img'].indexOf(childTag) !== -1) {
                                hasBlockChild = true;
                                break;
                            }
                        }
                        if (hasBlockChild) {
                            for (var i = 0; i < node.childNodes.length; i++) {
                                processNode(node.childNodes[i]);
                            }
                        } else if (text) {
                            blocks.push({ type: 'paragraph', text: text, level: 0 });
                        }
                    }
                }

                for (var i = 0; i < div.childNodes.length; i++) {
                    processNode(div.childNodes[i]);
                }

                return JSON.stringify({
                    title: result.title || '',
                    author: result.author || null,
                    description: result.description || null,
                    published: result.published || null,
                    domain: result.domain || null,
                    site: result.site || null,
                    wordCount: result.wordCount || 0,
                    blocks: blocks
                });
            } catch(e) {
                return JSON.stringify({ error: e.message });
            }
        })();
        """

        Task {
            do {
                let jsResult = try await webView.evaluateJavaScript(script)
                self.processJSResult(jsResult)
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func processJSResult(_ jsResult: Any?) {
        guard let jsonString = jsResult as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[Defuddle] processJSResult: non-string/invalid JSON result: \(String(describing: jsResult))")
            finish(.failure(DefuddleError.parsingFailed))
            return
        }

        if let jsError = json["error"] as? String, !jsError.isEmpty {
            NSLog("[Defuddle] processJSResult: JS error: \(jsError)")
            if loadedFromURL != nil, extractionRetries < Self.maxExtractionRetries {
                extractionRetries += 1
                Task { @MainActor in
                    try? await Task.sleep(for: Self.retryDelay)
                    guard !self.hasResumed else { return }
                    self.runDefuddle()
                }
                return
            }
            finish(.failure(DefuddleError.parsingFailed))
            return
        }

        guard let rawBlocks = json["blocks"] as? [[String: Any]], !rawBlocks.isEmpty else {
            // For live URLs (bot walls / SPAs), the DOM may still be hydrating.
            // Retry a few times with a short delay before giving up.
            if loadedFromURL != nil, extractionRetries < Self.maxExtractionRetries {
                extractionRetries += 1
                Task { @MainActor in
                    try? await Task.sleep(for: Self.retryDelay)
                    guard !self.hasResumed else { return }
                    self.runDefuddle()
                }
                return
            }
            finish(.failure(DefuddleError.noContent))
            return
        }

        // Build TextBlocks and plainText
        var textBlocks: [TextBlock] = []
        var plainParts: [String] = []

        for rawBlock in rawBlocks {
            guard let text = rawBlock["text"] as? String,
                  let typeStr = rawBlock["type"] as? String,
                  !text.isEmpty else { continue }

            let cleaned = Self.cleanBlockText(text)
            guard !cleaned.isEmpty else { continue }

            let blockType: BlockType
            switch typeStr {
            case "heading":
                let level = rawBlock["level"] as? Int ?? 1
                blockType = .heading(level: level)
            case "quote":
                blockType = .quote
            case "code":
                let source = (rawBlock["source"] as? String ?? "")
                let language = (rawBlock["language"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                plainParts.append(RSVPEngine.placeholderCode)
                let plainSoFar = plainParts.joined(separator: "\n\n")
                let startIndex = plainSoFar.index(plainSoFar.endIndex, offsetBy: -RSVPEngine.placeholderCode.count)
                textBlocks.append(TextBlock(
                    text: RSVPEngine.placeholderCode,
                    type: .code(language: language?.isEmpty == false ? language : nil, source: source),
                    range: startIndex..<plainSoFar.endIndex
                ))
                continue
            case "list":
                blockType = .list
            case "caption":
                blockType = .caption
            case "table":
                let html = (rawBlock["html"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let cols = rawBlock["columnCount"] as? Int ?? 0
                guard !html.isEmpty else { continue }
                // Override the cleaned cell-text concatenation with the canonical
                // placeholder so RSVP word counts stay aligned. The structured
                // HTML rides along on the BlockType associated value.
                plainParts.append(RSVPEngine.placeholderTable)
                let plainSoFar = plainParts.joined(separator: "\n\n")
                let startIndex = plainSoFar.index(plainSoFar.endIndex, offsetBy: -RSVPEngine.placeholderTable.count)
                textBlocks.append(TextBlock(
                    text: RSVPEngine.placeholderTable,
                    type: .table(html: html, columnCount: cols, caption: nil),
                    range: startIndex..<plainSoFar.endIndex
                ))
                continue
            case "image":
                let src = rawBlock["src"] as? String ?? ""
                guard !src.isEmpty else { continue }
                guard !src.lowercased().hasPrefix("data:image/gif"),
                      URLComponents(string: src)?.path.lowercased().hasSuffix(".gif") != true else { continue }
                let rawAlt = rawBlock["alt"] as? String
                let alt = rawAlt?.trimmingCharacters(in: .whitespacesAndNewlines)
                blockType = .image(src: src, altText: (alt?.isEmpty == false) ? alt : nil)
            case "formula":
                let latex = (rawBlock["latex"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latex.isEmpty else { continue }
                blockType = .formula(latex: latex, caption: nil)
            default:
                blockType = .paragraph
            }

            plainParts.append(cleaned)
            let plainSoFar = plainParts.joined(separator: "\n\n")
            let startIndex = plainSoFar.index(plainSoFar.endIndex, offsetBy: -cleaned.count)
            let range = startIndex..<plainSoFar.endIndex

            textBlocks.append(TextBlock(
                text: cleaned,
                type: blockType,
                range: range
            ))
        }

        let plainText = plainParts.joined(separator: "\n\n")

        guard !plainText.isEmpty else {
            finish(.failure(DefuddleError.noContent))
            return
        }

        let result = DefuddleResult(
            title: json["title"] as? String ?? "",
            blocks: textBlocks,
            plainText: plainText,
            author: json["author"] as? String,
            description: json["description"] as? String,
            published: json["published"] as? String,
            domain: json["domain"] as? String,
            siteName: json["site"] as? String,
            wordCount: json["wordCount"] as? Int ?? 0
        )

        finish(.success(result))
    }

    /// Normalizes whitespace within a block while preserving single newlines for code.
    private static func cleanBlockText(_ text: String) -> String {
        var result = text
            .components(separatedBy: "\n")
            .map { line in
                line.components(separatedBy: .init(charactersIn: " \t"))
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")

        // Collapse 3+ consecutive newlines to 2
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // For non-code text: single \n → space, \n\n → preserved
        let placeholder = "\u{0000}"
        result = result.replacingOccurrences(of: "\n\n", with: placeholder)
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: placeholder, with: "\n\n")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WKNavigationDelegate

extension DefuddleExtractor: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            NSLog("[Defuddle] WKWebView response: status=\(http.statusCode) url=\(http.url?.absoluteString ?? "?")")
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !self.hasResumed else { return }

            // When loading a live URL (e.g. ESPN bot wall), give the page JS
            // ~800 ms to hydrate the DOM before running Defuddle.
            if self.loadedFromURL != nil {
                try? await Task.sleep(for: .milliseconds(800))
                if let diag = try? await webView.evaluateJavaScript(
                    "JSON.stringify({title: document.title, bodyLen: (document.body ? document.body.innerText.length : -1), url: location.href})"
                ) {
                    NSLog("[Defuddle] didFinish diag: \(diag)")
                }
            }
            self.runDefuddle()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[Defuddle] didFail: \(error.localizedDescription)")
        Task { @MainActor in
            self.finish(.failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[Defuddle] didFailProvisionalNavigation: \(error.localizedDescription)")
        Task { @MainActor in
            self.finish(.failure(error))
        }
    }
}
