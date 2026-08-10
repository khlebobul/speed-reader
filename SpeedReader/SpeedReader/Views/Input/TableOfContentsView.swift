import SwiftUI

/// Slide-in sidebar listing a document's table of contents. Tapping a row jumps
/// the reader to that section; the section containing the current word is
/// highlighted and auto-scrolled into view.
@available(macOS 13.0, *)
struct TableOfContentsView: View {
    let toc: TableOfContents
    /// Current RSVP word index — drives active-section highlighting.
    let currentIndex: Int
    var onSelect: (TOCEntry) -> Void
    var onClose: () -> Void

    @State private var filter = ""

    /// Depth-first list of every entry, in reading order.
    private var flatEntries: [TOCEntry] { toc.flattened }

    /// Rows actually shown — all entries, or those matching the filter text.
    private var visibleEntries: [TOCEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return flatEntries }
        return flatEntries.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// The deepest entry whose jump target is at or before the current word.
    private var activeEntry: TOCEntry? {
        flatEntries.last(where: { $0.wordIndex <= currentIndex })
    }

    private var showsSearch: Bool { flatEntries.count > 20 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsSearch {
                searchField
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleEntries) { entry in
                            TOCRow(
                                entry: entry,
                                isActive: entry.id == activeEntry?.id,
                                onTap: { onSelect(entry) }
                            )
                            .id(entry.id)
                        }
                        if visibleEntries.isEmpty {
                            Text("No matching sections")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: currentIndex) { _, _ in
                    guard filter.isEmpty, let active = activeEntry else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(active.id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 18, x: -4, y: 4)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text("Contents")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("Filter sections", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// One row in the table of contents — indented by `level`, highlighted when it
/// is the section currently being read.
@available(macOS 13.0, *)
private struct TOCRow: View {
    let entry: TOCEntry
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(max(0, entry.level - 1)) * 12)
                Text(entry.title)
                    .font(.system(size: entry.level == 1 ? 13 : 12,
                                  weight: entry.level == 1 ? .semibold : .regular))
                    .foregroundColor(isActive ? .accentColor : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.accentColor.opacity(0.14)
                          : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}
