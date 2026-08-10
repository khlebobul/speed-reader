import SwiftUI

/// The shared unified top control row used by every preview container:
/// `[leading] ──── [trailing controls] [search field]`.
///
/// Centralizes the bar's padding and background so File / Text / URL / Area and
/// the PDF/Markdown tabbed previews all line their controls up identically.
@available(macOS 13.0, *)
struct PreviewToolbarRow<Search: View>: View {
    /// Approximate rendered height of the toolbar row. Used by floating overlays
    /// (e.g. `BookPreviewWithTOC`'s `topPadding`) that need to slide in below
    /// the toolbar without covering its chips. Derived from the chip's
    /// intrinsic height (~24pt) + the row's vertical padding (8pt × 2).
    static var approximateHeight: CGFloat { 40 }

    var leading: AnyView = AnyView(EmptyView())
    var trailing: AnyView = AnyView(EmptyView())
    /// The search field — empty when search is unavailable (e.g. during reading).
    @ViewBuilder var search: () -> Search

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 8)
            trailing
            search()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.82))
    }
}

/// Compact pill label for a control button living inside `PreviewToolbarRow`
/// (e.g. "Set start position", "Paste", "Recapture"). Keeps every toolbar
/// button visually consistent across File / Text / URL / Area.
@available(macOS 13.0, *)
struct ToolbarChipLabel: View {
    let icon: String
    let text: String
    var active: Bool = false
    var shortcut: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12, weight: .medium))
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .foregroundColor(active ? .accentColor : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
        )
        .contentShape(Rectangle())
    }
}

/// The rounded card chrome shared by the Text / URL / Area preview areas.
@available(macOS 13.0, *)
struct PreviewCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }
}

@available(macOS 13.0, *)
extension View {
    /// Applies the shared rounded-card chrome used by preview areas.
    func previewCard() -> some View { modifier(PreviewCardModifier()) }
}

// MARK: - Search controls (shared by every preview container)

/// Compact toggle that lives in `PreviewToolbarRow.search`. Opens/closes the
/// expandable search row below the toolbar instead of mounting the full
/// `SearchBarView` inline — keeps the toolbar's other chips from jittering
/// when the user types and counter/chevrons/"Read from here" appear.
@available(macOS 13.0, *)
struct SearchToggleButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarChipLabel(icon: "magnifyingglass", text: "Search", active: isOpen)
        }
        .buttonStyle(.plain)
        .help("Search (⌘F)")
    }
}

/// Floating search pill — `SearchBarView` with toolbar-edge padding, designed
/// to be placed in `.overlay(alignment: .topTrailing)` over the preview content
/// so it appears above the text without pushing the text down. Self-contained
/// (no row background): `SearchBarView` already carries its own material
/// fill / border / shadow, which is enough to read as a floating element.
@available(macOS 14.0, *)
struct ExpandedSearchRow: View {
    let target: any SearchTarget
    let focusRequest: Int
    let onClose: () -> Void
    var onStartFromHere: ((Int) -> Void)? = nil

    var body: some View {
        SearchBarView(
            target: target,
            focusRequest: focusRequest,
            onClose: onClose,
            onStartFromHere: onStartFromHere
        )
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}
