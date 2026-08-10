import Foundation
import WebKit

/// Converts PDF to Markdown using jzillmann/pdf-to-markdown via WKWebView.
/// The PDF is passed as base64 data to avoid sandbox file access issues.
enum PDF2MDExtractor {

    // MARK: - Markdown → Plain Text

    /// Per-line scan result for `scanMarkdownLine(_:inTable:)`.
    /// `.skipped` lines (code fences, horizontal rules, table separators) do
    /// not contribute words to the plain-text stream. `.heading(level:)` carries
    /// the ATX hash count so the TOC builder can label entries.
    enum MarkdownLineKind {
        case paragraph
        case heading(level: Int)
        case skipped
    }

    /// Walks one markdown line, returning the stripped plain-text form and its
    /// kind. The same stripping rules `plainText(fromMarkdown:)` uses — extracted
    /// into a helper so `TableOfContents.fromMarkdown(_:)` can iterate the
    /// markdown in lockstep with the plain-text stream and produce word indices
    /// that match `RSVPEngine.currentIndex` exactly.
    static func scanMarkdownLine(_ line: String, inTable: inout Bool) -> (text: String, kind: MarkdownLineKind) {
        // Code fence markers — skipped (the body of the block is still walked
        // as normal lines because PDF code lines are readable text).
        if line.hasPrefix("```") { return ("", .skipped) }

        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Horizontal rules and table separators — skipped.
        if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
            return ("", .skipped)
        }
        if trimmed.hasPrefix("|") {
            if trimmed.range(of: #"^\|[\s\-:|]+\|$"#, options: .regularExpression) != nil {
                return ("", .skipped)
            }
            let cells = trimmed.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            inTable = true
            return (cells.joined(separator: " "), .paragraph)
        }
        if inTable { inTable = false }

        // Detect heading level BEFORE stripping (so we know if this line emits a TOC entry).
        var kind: MarkdownLineKind = .paragraph
        let hashCount = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashCount) {
            let afterHash = trimmed.dropFirst(hashCount)
            if let firstChar = afterHash.first, firstChar == " " || firstChar == "\t" {
                kind = .heading(level: hashCount)
            }
        }

        var s = line
        // Heading markers
        s = s.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        // Blockquote markers
        s = s.replacingOccurrences(of: #"^>\s*"#, with: "", options: .regularExpression)
        // List markers: `- `, `* `, `+ `, `1. `, `12. ` (HTML renders these via CSS)
        s = s.replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(\s*)\d+\.\s+"#, with: "$1", options: .regularExpression)
        // Images: ![alt](url) → remove
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "", options: .regularExpression)
        // Links: [text](url) → text
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Bold/italic: ***text***, **text**, *text*
        s = s.replacingOccurrences(of: #"\*{3}(.+?)\*{3}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*{2}(.+?)\*{2}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
        // Inline code
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // Backslash escapes
        s = s.replacingOccurrences(of: #"\\([\\`*_{}[\]()#+\-.!~>|$])"#, with: "$1", options: .regularExpression)

        return (s, kind)
    }

    /// Strips markdown formatting to produce clean plain text that matches
    /// the visible text content of marked.js-rendered HTML (for RSVP sync).
    ///
    /// GFM tables collapse to a single `RSVPEngine.placeholderTable` token so the
    /// Edit-tab's recomputed `plainText` stays in sync with the DOM walker in
    /// `MarkdownPreviewView`, which wraps every `<table>` as one placeholder.
    static func plainText(fromMarkdown markdown: String) -> String {
        var result: [String] = []
        var inTable = false
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // GFM table: header row + separator row (`|---|---|`) on the next
            // line. Emit one placeholder beat and consume every subsequent
            // pipe row until a blank line or non-pipe line breaks the table.
            if i + 1 < lines.count,
               lineLooksLikeTableRow(line),
               lineIsGFMSeparator(lines[i + 1]) {
                result.append(RSVPEngine.placeholderTable)
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    if row.isEmpty || !lineLooksLikeTableRow(row) { break }
                    i += 1
                }
                continue
            }

            let scan = scanMarkdownLine(line, inTable: &inTable)
            if case .skipped = scan.kind { i += 1; continue }
            result.append(scan.text)
            i += 1
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lineLooksLikeTableRow(_ line: String) -> Bool {
        var prevBackslash = false
        for ch in line {
            if ch == "|" && !prevBackslash { return true }
            prevBackslash = (ch == "\\" && !prevBackslash)
        }
        return false
    }

    /// GFM separator: `| --- | :---: | ---: |`. Each cell must be one or more
    /// `-` with optional leading/trailing `:` for alignment. Mirrors
    /// `MarkdownReader.isTableSeparator`.
    private static func lineIsGFMSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        var stripped = trimmed
        if stripped.hasPrefix("|") { stripped.removeFirst() }
        if stripped.hasSuffix("|") { stripped.removeLast() }
        let cells = stripped.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        let pattern = #"^:?-{1,}:?$"#
        for cell in cells {
            let cellTrim = cell.trimmingCharacters(in: .whitespaces)
            if cellTrim.range(of: pattern, options: .regularExpression) == nil {
                return false
            }
        }
        return true
    }

    enum PDF2MDError: Error, LocalizedError {
        case bundleNotFound
        case pdfReadFailed
        case conversionFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .bundleNotFound: return "PDF2MD.js bundle not found"
            case .pdfReadFailed: return "Failed to read PDF file"
            case .conversionFailed(let msg): return "PDF2MD conversion failed: \(msg)"
            case .timeout: return "PDF2MD conversion timed out"
            }
        }
    }

    /// Converts a PDF file at the given URL to Markdown.
    static func convert(pdfURL: URL) async throws -> String {
        guard let jsURL = Bundle.main.url(forResource: "PDF2MD", withExtension: "js") else {
            throw PDF2MDError.bundleNotFound
        }
        let jsCode = try String(contentsOf: jsURL, encoding: .utf8)

        guard let pdfData = try? Data(contentsOf: pdfURL) else {
            throw PDF2MDError.pdfReadFailed
        }

        let base64 = pdfData.base64EncodedString()

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let helper = ConversionHelper(
                    jsCode: jsCode,
                    base64: base64,
                    continuation: continuation
                )
                helper.start()
            }
        }
    }
}

// MARK: - Conversion Helper

/// Handles the WKWebView lifecycle for a single conversion.
/// Prevents premature deallocation by retaining itself until complete.
private class ConversionHelper: NSObject, WKNavigationDelegate {
    let jsCode: String
    let base64: String
    let continuation: CheckedContinuation<String, Error>
    var webView: WKWebView?
    var resumed = false

    private static var activeHelpers = [ObjectIdentifier: ConversionHelper]()

    init(jsCode: String, base64: String, continuation: CheckedContinuation<String, Error>) {
        self.jsCode = jsCode
        self.base64 = base64
        self.continuation = continuation
    }

    @MainActor func start() {
        ConversionHelper.activeHelpers[ObjectIdentifier(self)] = self

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        wv.enableInspectorInDebug()
        wv.navigationDelegate = self
        self.webView = wv

        // Load a minimal blank page first, then inject JS programmatically
        wv.loadHTMLString("<html><body></body></html>", baseURL: nil)

        // Timeout after 120 seconds (large PDFs may take a while)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.finish(with: .failure(PDF2MDExtractor.PDF2MDError.timeout))
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard !resumed else { return }
        resumed = true
        webView?.navigationDelegate = nil
        webView = nil

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }

        ConversionHelper.activeHelpers.removeValue(forKey: ObjectIdentifier(self))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Inject the JS bundle via evaluateJavaScript (handles large scripts better than inline HTML)
        webView.evaluateJavaScript(jsCode) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error {
                self.finish(with: .failure(PDF2MDExtractor.PDF2MDError.conversionFailed(
                    "JS injection failed: \(error.localizedDescription)"
                )))
                return
            }
            self.runConversion()
        }
    }

    private func runConversion() {
        guard let webView = webView else { return }

        let script = """
        try {
            const result = await window.convertPdfToMarkdown(b64);
            return result || "";
        } catch (e) {
            return "ERROR:" + (e.message || String(e));
        }
        """

        webView.callAsyncJavaScript(
            script,
            arguments: ["b64": base64],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let value):
                if let markdown = value as? String {
                    if markdown.hasPrefix("ERROR:") {
                        let msg = String(markdown.dropFirst(6))
                        self.finish(with: .failure(PDF2MDExtractor.PDF2MDError.conversionFailed(msg)))
                    } else {
                        self.finish(with: .success(markdown))
                    }
                } else {
                    self.finish(with: .failure(PDF2MDExtractor.PDF2MDError.conversionFailed(
                        "Invalid result type: \(type(of: value)), value: \(String(describing: value))"
                    )))
                }
            case .failure(let error):
                self.finish(with: .failure(PDF2MDExtractor.PDF2MDError.conversionFailed(
                    error.localizedDescription
                )))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(PDF2MDExtractor.PDF2MDError.conversionFailed(error.localizedDescription)))
    }
}
