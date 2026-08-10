import Foundation
import CoreGraphics

/// Location of a word on a PDF page, extracted via OCR.
/// Used to highlight the current RSVP word on scanned PDF pages.
struct OCRWordLocation: Equatable {
    /// 0-based page index (for PDFDocument.page(at:))
    let pageIndex: Int
    /// Bounding rect in PDF page coordinates (points, origin at bottom-left)
    let rect: CGRect
}
