import PDFKit
import CoreGraphics

/// Renders PDF pages to CGImage for Vision OCR processing.
enum OCRPageRenderer {

    /// 216 DPI (3× 72pt) provides sharp character-level bounding boxes
    /// while keeping memory reasonable (~15 MB per letter-size page).
    static let defaultDPI: CGFloat = 216

    static func render(page: PDFPage, dpi: CGFloat = defaultDPI) -> CGImage? {
        let mediaBox = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let pixelWidth = Int(mediaBox.width * scale)
        let pixelHeight = Int(mediaBox.height * scale)

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White background (important for scanned documents)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }
}
