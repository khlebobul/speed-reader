import Foundation

/// Errors that can occur when reading documents
enum DocumentError: LocalizedError {
    case cannotOpen
    case unsupportedFormat
    case readingFailed(String)
    case emptyDocument
    case scannedDocument
    case needsOCR(pageCount: Int, url: URL)

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return "Cannot open the document"
        case .unsupportedFormat:
            return "Unsupported document format"
        case .readingFailed(let reason):
            return "Failed to read document: \(reason)"
        case .emptyDocument:
            return "No extractable text found in this document"
        case .scannedDocument:
            return "This PDF appears to be a scan and contains no selectable text."
        case .needsOCR(let pageCount, _):
            return "This document contains \(pageCount) scanned page\(pageCount == 1 ? "" : "s") that require OCR to read."
        }
    }
}

/// Protocol for reading different document formats
protocol DocumentReader {
    /// Supported file extensions for this reader
    static var supportedExtensions: [String] { get }

    /// Check if this reader can handle the given URL
    func canRead(url: URL) -> Bool

    /// Read and parse the document at the given URL
    func read(from url: URL) async throws -> DocumentContent
}

extension DocumentReader {
    func canRead(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }
}

/// Factory for creating appropriate document readers
final class DocumentReaderFactory {
    /// Get a reader that can handle the given URL
    static func reader(for url: URL) -> DocumentReader? {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "txt":
            return PlainTextReader()
        case "pdf":
            return PDFDocumentReader()
        case "md", "markdown":
            return MarkdownReader()
        case "fb2":
            return FB2Reader()
        case "epub":
            return EPUBReader()
        case "docx":
            return DOCXReader()
        case "jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp":
            return ImageReader()
        default:
            return nil
        }
    }

    /// All supported file extensions
    static var supportedExtensions: [String] {
        ["pdf", "txt", "md", "markdown", "fb2", "epub", "docx",
         "jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp"]
    }

    /// Primary extensions for display in UI (one per format)
    static var displayExtensions: [String] {
        ["pdf", "txt", "md", "fb2", "epub", "docx", "jpg", "png", "tiff", "heic", "bmp"]
    }

    /// Check if a file extension is supported
    static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
