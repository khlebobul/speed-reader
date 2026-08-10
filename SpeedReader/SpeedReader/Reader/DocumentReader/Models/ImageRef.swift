import Foundation

/// A reference to an image embedded in a document, paired with its position in the
/// RSVP word stream via `DocumentContent.imageRefs`. Lets the engine pause on the
/// matching `placeholderImage` beat and the reader UI render a thumbnail in place
/// of the placeholder word.
///
/// Sources:
/// - `.dataURL` — DOCX (base64-inlined image bytes) and Markdown when the renderer
///   already produced a data URL.
/// - `.url` — remote `<img src="https://...">` from URL articles or Markdown links
///   pointing at remote/local-file images.
enum ImageRef: Equatable {
    case url(URL, caption: String? = nil)
    case dataURL(String, caption: String? = nil)

    var caption: String? {
        switch self {
        case .url(_, let c), .dataURL(_, let c): return c
        }
    }

    /// Build a ref from the raw `src` string stored in a `BlockType.image`. Returns
    /// `nil` when the src is empty or unrecognized.
    static func from(src: String, caption: String?) -> ImageRef? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:") {
            return .dataURL(trimmed, caption: caption)
        }
        if let url = URL(string: trimmed) {
            return .url(url, caption: caption)
        }
        return nil
    }
}
