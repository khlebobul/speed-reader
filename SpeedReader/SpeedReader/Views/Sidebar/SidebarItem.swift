import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case text = "Text"
    case url = "URL"
    case file = "File"
    case area = "Area"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .text: return "textbox"
        case .url: return "link"
        case .file: return "doc.richtext"
        case .area: return "viewfinder"
        }
    }

    var description: String {
        switch self {
        case .text: return "Paste or type any text for speed reading."
        case .url: return "Load articles from any web page URL."
        case .file: return "Import PDF, EPUB, DOCX, FB2, and more."
        case .area: return "Capture a screen region and OCR the text."
        }
    }

    var tagLabel: String {
        switch self {
        case .text: return "Paste & Type"
        case .url: return "Web Article"
        case .file: return "Documents"
        case .area: return "Screen OCR"
        }
    }

    var cardNumber: String {
        switch self {
        case .text: return "SR.001"
        case .url: return "SR.002"
        case .file: return "SR.003"
        case .area: return "SR.004"
        }
    }

    var shortcutKey: KeyEquivalent {
        switch self {
        case .text: return "1"
        case .url: return "2"
        case .file: return "3"
        case .area: return "4"
        }
    }

    var shortcutHint: String {
        switch self {
        case .text: return "⌘1"
        case .url: return "⌘2"
        case .file: return "⌘3"
        case .area: return "⌘4"
        }
    }
}
