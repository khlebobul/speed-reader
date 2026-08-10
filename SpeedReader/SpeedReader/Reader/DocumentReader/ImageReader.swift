import Foundation
import AppKit

/// Reader for image files (JPEG, PNG, TIFF, HEIC, BMP).
/// Images always require OCR to extract text.
final class ImageReader: DocumentReader {
    static let supportedExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp"]

    func read(from url: URL) async throws -> DocumentContent {
        // Images cannot be read without OCR — signal the UI to prompt the user
        throw DocumentError.needsOCR(pageCount: 1, url: url)
    }

    /// Reads text from an image using on-device OCR.
    func readWithOCR(
        from url: URL,
        options: OCREngine.Options = .init(),
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> DocumentContent {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw DocumentError.cannotOpen
        }

        await onProgress(0, 1)

        let engine = OCREngine()
        let result = try await engine.recognize(cgImage: cgImage, options: options)

        await onProgress(1, 1)
        let pageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let blocks = OCRTextRebuilder.buildBlocks(
            from: [result], pageSize: pageSize, pageNumber: 1
        )

        guard !blocks.isEmpty else {
            throw DocumentError.emptyDocument
        }

        let plainText = blocks.map(\.text).joined(separator: "\n\n")
        return DocumentContent(
            title: url.deletingPathExtension().lastPathComponent,
            blocks: blocks,
            plainText: plainText,
            usedOCR: true
        )
    }
}
