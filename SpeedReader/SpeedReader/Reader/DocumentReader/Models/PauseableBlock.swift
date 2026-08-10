import Foundation

/// Kind of block that the RSVP engine can auto-pause on. Used in settings to gate
/// per-kind auto-pause behavior, in preview views to choose the right renderer, and
/// in analytics if we add it later.
enum BlockKind: String, CaseIterable, Equatable {
    case image, formula, table, code

    /// SF Symbol shown in compact previews and settings rows.
    var iconName: String {
        switch self {
        case .image:   return "photo"
        case .formula: return "function"
        case .table:   return "tablecells"
        case .code:    return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Localized display label for settings and compact previews.
    var displayName: String {
        switch self {
        case .image:   return "Image"
        case .formula: return "Formula"
        case .table:   return "Table"
        case .code:    return "Code"
        }
    }
}

/// A pause-worthy block in the RSVP stream. Each case carries the data needed to
/// render a preview when the engine auto-pauses on the corresponding placeholder
/// beat (`RSVPEngine.placeholderImage` / `.placeholderFormula` / `.placeholderCode`,
/// plus a future "table" placeholder).
///
/// Only `.image` has a producer today (DOCX + URL articles); the other cases exist
/// so the engine, settings, and preview UI can be designed once and extended in
/// later phases without churn.
enum PauseableBlock: Equatable {
    case image(ImageRef)
    case formula(latex: String, caption: String? = nil)
    case table(html: String, columnCount: Int, caption: String? = nil)
    case code(language: String?, source: String)

    var kind: BlockKind {
        switch self {
        case .image:   return .image
        case .formula: return .formula
        case .table:   return .table
        case .code:    return .code
        }
    }

    var caption: String? {
        switch self {
        case .image(let ref):                  return ref.caption
        case .formula(_, let caption):         return caption
        case .table(_, _, let caption):        return caption
        case .code:                            return nil
        }
    }
}
