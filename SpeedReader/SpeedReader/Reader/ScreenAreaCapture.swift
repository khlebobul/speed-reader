import AppKit
import Vision

// MARK: - Screen Area Capture

/// Captures a screen area using the native macOS screencapture tool and performs OCR.
final class ScreenAreaCapture {

    /// Launches native macOS area selection and returns the captured image.
    static func captureArea() async -> CGImage? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", tempURL.path]  // -i = interactive, -x = no sound

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempURL.path),
              let nsImage = NSImage(contentsOf: tempURL),
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        try? FileManager.default.removeItem(at: tempURL)
        return cgImage
    }

    /// Performs OCR on the captured image and returns recognized text.
    static func recognizeText(from image: CGImage) async throws -> String {
        let engine = OCREngine()
        let options = ReaderSettings.shared.ocrOptions
        let result = try await engine.recognize(cgImage: image, options: options)

        // Sort observations top-to-bottom, left-to-right
        let sorted = result.observations.sorted { a, b in
            let aY = 1 - a.boundingBox.midY
            let bY = 1 - b.boundingBox.midY
            if abs(aY - bY) < 0.02 {
                return a.boundingBox.midX < b.boundingBox.midX
            }
            return aY < bY
        }

        let lines = sorted.compactMap { obs in
            obs.topCandidates(1).first?.string
        }

        return lines.joined(separator: "\n")
    }
}
