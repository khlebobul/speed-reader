import Foundation
import AppKit
import WebKit

// MARK: - URL Validator

struct URLValidator {

    /// Validation result with detailed error info
    enum ValidationResult {
        case valid(URL)
        case invalid(ValidationError)
    }

    enum ValidationError: LocalizedError {
        case empty
        case invalidFormat
        case unsupportedScheme(String)
        case missingHost
        case localFileNotAllowed
        case ipAddressNotAllowed
        case suspiciousURL(reason: String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Please enter a URL"
            case .invalidFormat:
                return "Invalid URL format"
            case .unsupportedScheme(let scheme):
                return "Unsupported protocol: \(scheme). Use http or https"
            case .missingHost:
                return "URL must contain a domain name"
            case .localFileNotAllowed:
                return "Local file URLs are not supported"
            case .ipAddressNotAllowed:
                return "Direct IP addresses are not supported"
            case .suspiciousURL(let reason):
                return "Suspicious URL: \(reason)"
            }
        }
    }

    /// Validates a URL string and returns a normalized URL or error
    static func validate(_ urlString: String) -> ValidationResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check empty
        guard !trimmed.isEmpty else {
            return .invalid(.empty)
        }

        // Add https:// if no scheme provided
        var normalizedString = trimmed
        if !normalizedString.contains("://") {
            normalizedString = "https://" + normalizedString
        }

        // Try to parse URL
        guard let url = URL(string: normalizedString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .invalid(.invalidFormat)
        }

        // Check scheme
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            if scheme == "file" {
                return .invalid(.localFileNotAllowed)
            }
            return .invalid(.unsupportedScheme(scheme.isEmpty ? "none" : scheme))
        }

        // Check host exists
        guard let host = components.host, !host.isEmpty else {
            return .invalid(.missingHost)
        }

        // Check for IP address (basic check)
        let ipPattern = "^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"
        if let regex = try? NSRegularExpression(pattern: ipPattern),
           regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil {
            return .invalid(.ipAddressNotAllowed)
        }

        // Check for localhost
        if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" {
            return .invalid(.localFileNotAllowed)
        }

        // Check for valid TLD (basic - at least has a dot)
        if !host.contains(".") {
            return .invalid(.invalidFormat)
        }

        // Check for suspicious patterns
        if host.contains("..") {
            return .invalid(.suspiciousURL(reason: "invalid domain"))
        }

        return .valid(url)
    }

    /// Quick check if URL looks valid (for UI enable/disable)
    static func looksValid(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Must have at least one dot or be a valid URL with scheme
        if trimmed.contains("://") {
            if let url = URL(string: trimmed), url.host != nil {
                return true
            }
        } else if trimmed.contains(".") && trimmed.count >= 4 {
            // Looks like domain.tld
            return true
        }

        return false
    }
}

// MARK: - URL Text Fetcher

/// Service for fetching and extracting readable text from URLs
class URLTextFetcher: ObservableObject {
    @Published var isLoading = false
    @Published var error: String?

    /// Fetches URL and extracts structured content from HTML
    func fetchContent(from urlString: String) async throws -> DocumentContent {
        // Validate URL first
        switch URLValidator.validate(urlString) {
        case .valid(let url):
            return try await fetchContent(from: url)
        case .invalid(let error):
            throw error
        }
    }

    /// Legacy API: returns plain text for backward compatibility
    func fetchText(from urlString: String) async throws -> String {
        let content = try await fetchContent(from: urlString)
        return content.plainText
    }

    /// Fetches from a validated URL
    private func fetchContent(from url: URL) async throws -> DocumentContent {
        // Ensure https
        var finalURL = url
        if url.scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let httpsURL = components?.url {
                finalURL = httpsURL
            }
        }

        if Self.isPDFURL(finalURL) {
            throw URLFetchError.pdfDownloadRequired
        }

        var request = URLRequest(url: finalURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        try await Self.performPreflight(request: request, requestedURL: finalURL)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLFetchError.invalidResponse
        }

        // Detect bot walls / empty responses (e.g. ESPN returns 202 with empty body).
        // Fallback to a real browser engine (WKWebView) so JS challenges can resolve.
        let isSuspicious = !Self.isValidResponse(httpResponse, data: data)

        if isSuspicious {
            let result = try await DefuddleExtractor.extract(from: finalURL)
            let metadata = DocumentMetadata(author: result.author)
            let toc = TableOfContents.fromBlocks(result.blocks)
            return DocumentContent(
                title: result.title.isEmpty ? nil : result.title,
                blocks: result.blocks,
                plainText: result.plainText,
                metadata: metadata,
                toc: toc.isEmpty ? nil : toc
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLFetchError.httpError(statusCode: httpResponse.statusCode)
        }

        // Detect redirect to a login page so we don't hand a 700+ KB auth wall to Defuddle/SwiftUI
        if let landedURL = httpResponse.url, Self.looksLikeLoginRedirect(requested: finalURL, landed: landedURL) {
            throw URLFetchError.authenticationRequired
        }

        if Self.isPDFResponse(data: data, response: httpResponse, url: finalURL) {
            throw URLFetchError.pdfDownloadRequired
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           !Self.isTextContentType(contentType) {
            throw URLFetchError.unsupportedContentType(contentType)
        }

        // Try to detect encoding from response
        let encoding: String.Encoding = {
            if let encodingName = httpResponse.textEncodingName {
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
                if cfEncoding != kCFStringEncodingInvalidId {
                    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                }
            }
            return .utf8
        }()

        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) else {
            throw URLFetchError.encodingError
        }

        // Try Defuddle first (accurate article extraction with structure)
        do {
            let result = try await DefuddleExtractor.extract(from: html, baseURL: finalURL)

            let metadata = DocumentMetadata(
                author: result.author
            )

            // Defuddle emits `.heading(level:)` blocks straight from the article's
            // <h1>…<h6> tags, so `fromBlocks` produces wordIndex values that line
            // up with the engine's tokenization of `plainText`.
            let toc = TableOfContents.fromBlocks(result.blocks)

            return DocumentContent(
                title: result.title.isEmpty ? nil : result.title,
                blocks: result.blocks,
                plainText: result.plainText,
                metadata: metadata,
                toc: toc.isEmpty ? nil : toc
            )
        } catch {
            // Fall back to legacy regex-based extraction
            let text = await legacyExtractText(from: html)
            return DocumentContent(plainText: text)
        }
    }

    /// Legacy fallback: regex-based HTML tag stripping via NSAttributedString
    @MainActor
    private func legacyExtractText(from html: String) -> String {
        var cleanedHTML = html

        let tagsToRemove = ["script", "style", "nav", "header", "footer", "aside", "noscript", "iframe", "form"]
        for tag in tagsToRemove {
            let pattern = "<\(tag)[^>]*>.*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                cleanedHTML = regex.stringByReplacingMatches(
                    in: cleanedHTML,
                    options: [],
                    range: NSRange(cleanedHTML.startIndex..., in: cleanedHTML),
                    withTemplate: ""
                )
            }
        }

        guard let data = cleanedHTML.data(using: .utf8) else {
            return fallbackTagStrip(html)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil),
           !attributed.string.isEmpty {
            return collapseWhitespace(attributed.string)
        }

        return fallbackTagStrip(html)
    }

    private func fallbackTagStrip(_ html: String) -> String {
        var text = html
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return collapseWhitespace(text)
    }

    private func collapseWhitespace(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "\\s+", options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPDFURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    private static func isPDFResponse(data: Data, response: HTTPURLResponse, url: URL) -> Bool {
        if isPDFURL(url) { return true }
        if let mimeType = response.mimeType?.lowercased(), mimeType == "application/pdf" {
            return true
        }

        if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("application/pdf") {
            return true
        }

        return data.starts(with: Data("%PDF".utf8))
    }

    /// Returns `false` for responses that look like a bot wall (202/204) or are
    /// suspiciously empty — these are handled by falling back to WKWebView.
    private static func isValidResponse(_ response: HTTPURLResponse, data: Data) -> Bool {
        guard (200...299).contains(response.statusCode) else { return false }
        if response.statusCode == 202 || response.statusCode == 204 {
            return false
        }
        if data.count < 100 {
            return false
        }
        return true
    }

    private static func isTextContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        if lowercased.hasPrefix("text/") {
            return true
        }

        let textLikeTypes = [
            "application/xhtml+xml",
            "application/xml",
            "application/json",
            "application/ld+json",
            "application/rss+xml",
            "application/atom+xml"
        ]

        return textLikeTypes.contains { lowercased.contains($0) }
    }

    private static func performPreflight(request: URLRequest, requestedURL: URL) async throws {
        var headRequest = request
        headRequest.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: headRequest)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            guard (200...299).contains(httpResponse.statusCode) else { return }

            if let landedURL = httpResponse.url,
               looksLikeLoginRedirect(requested: requestedURL, landed: landedURL) {
                throw URLFetchError.authenticationRequired
            }

            if isPDFResponse(data: Data(), response: httpResponse, url: requestedURL) {
                throw URLFetchError.pdfDownloadRequired
            }
        } catch let error as URLFetchError {
            throw error
        } catch {
            // Some sites do not support HEAD. Fall back to GET and let normal handling decide.
            return
        }
    }

    /// Returns true when the final URL after redirects looks like a login/auth wall.
    /// Triggers only when the path actually changed — same-URL responses are not flagged.
    static func looksLikeLoginRedirect(requested: URL, landed: URL) -> Bool {
        let pathChanged = requested.path != landed.path
        let queryChanged = requested.query != landed.query
        guard pathChanged || queryChanged else { return false }

        let landedPath = landed.path.lowercased()
        let landedQuery = (landed.query ?? "").lowercased()

        let pathHints = ["/login", "/signin", "/sign-in", "/sign_in", "/auth/", "/sso/", "/account/login", "/users/sign_in"]
        if pathHints.contains(where: { landedPath.contains($0) }) { return true }

        // Skilljar / many SaaS use ?next=/original/path on the login page
        if landedQuery.contains("next=") || landedQuery.contains("redirect=") || landedQuery.contains("return_to=") {
            return true
        }

        return false
    }
}

// MARK: - Errors

enum URLFetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case encodingError
    case noContent
    case authenticationRequired
    case unsupportedContentType(String)
    case pdfDownloadRequired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL. Please enter a valid web address."
        case .invalidResponse:
            return "Invalid response from server."
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .encodingError:
            return "Could not decode the page content."
        case .noContent:
            return "No readable content found on this page."
        case .authenticationRequired:
            return "This page requires login."
        case .unsupportedContentType(let contentType):
            return "This link returned \(contentType), not a readable web page."
        case .pdfDownloadRequired:
            return "This link points to a PDF. Download the file and open it in the File tab."
        }
    }
}
