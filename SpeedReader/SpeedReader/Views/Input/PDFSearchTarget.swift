import Foundation
import PDFKit
import AppKit

/// `SearchTarget` implementation backed by a `PDFView`.
///
/// Finds matches via `PDFDocument.findString` and paints two annotations per match:
/// a yellow `.highlight` for every hit, plus a separate orange `.highlight` and
/// rectangular `.square` outline on the active one. The active match is no longer
/// drawn via PDFKit's native blue selection — that selection is only used to
/// drive `scrollSelectionToVisible(nil)` and is cleared again immediately so the
/// blue ring doesn't compete with our orange annotation.
///
/// For "Read from here", the active `PDFSelection` is mapped back to an RSVP
/// word index by looking up the nearest entry in `wordLocations`.
@MainActor
final class PDFSearchTarget: SearchTarget {
    weak var pdfView: PDFView?
    var wordLocations: [OCRWordLocation?]?

    private var selections: [PDFSelection] = []
    /// One inactive-match highlight per selection.
    private var matchAnnotations: [PDFAnnotation] = []
    /// Overlay annotations for the currently active match (orange highlight +
    /// square border). Removed and re-added on every `activate(_:)` so they
    /// only ever decorate one match at a time.
    private var activeAnnotations: [PDFAnnotation] = []
    private var activeIdx: Int = -1

    init(pdfView: PDFView, wordLocations: [OCRWordLocation?]?) {
        self.pdfView = pdfView
        self.wordLocations = wordLocations
    }

    func find(query: String) async -> Int {
        clear()
        guard let pdfView, let document = pdfView.document, !query.isEmpty else { return 0 }
        let found = document.findString(query, withOptions: [.caseInsensitive])
        guard !found.isEmpty else { return 0 }
        selections = found
        addMatchAnnotations()
        activate(0)
        return found.count
    }

    func next() async -> Int {
        guard !selections.isEmpty else { return -1 }
        let n = (activeIdx + 1) % selections.count
        activate(n)
        return n
    }

    func prev() async -> Int {
        guard !selections.isEmpty else { return -1 }
        let p = (activeIdx - 1 + selections.count) % selections.count
        activate(p)
        return p
    }

    func clear() {
        for ann in matchAnnotations { ann.page?.removeAnnotation(ann) }
        matchAnnotations.removeAll()
        clearActiveAnnotations()
        pdfView?.setCurrentSelection(nil, animate: false)
        selections.removeAll()
        activeIdx = -1
    }

    func activeWordIndex() async -> Int {
        guard let pdfView, let document = pdfView.document,
              activeIdx >= 0, activeIdx < selections.count,
              let wordLocations, !wordLocations.isEmpty else { return -1 }

        let selection = selections[activeIdx]
        guard let page = selection.pages.first else { return -1 }
        let pageIdx = document.index(for: page)
        let selRect = selection.bounds(for: page)
        let center = CGPoint(x: selRect.midX, y: selRect.midY)

        var bestIdx = -1
        var bestDist = CGFloat.greatestFiniteMagnitude

        // Same-page word whose rect intersects the selection wins; tie-break by center distance.
        for (i, loc) in wordLocations.enumerated() {
            guard let l = loc, l.pageIndex == pageIdx, l.rect.intersects(selRect) else { continue }
            let d = hypot(l.rect.midX - center.x, l.rect.midY - center.y)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        if bestIdx >= 0 { return bestIdx }

        // Fallback: nearest center on the same page (selection might land between word rects).
        for (i, loc) in wordLocations.enumerated() {
            guard let l = loc, l.pageIndex == pageIdx else { continue }
            let d = hypot(l.rect.midX - center.x, l.rect.midY - center.y)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - Internals

    private func activate(_ idx: Int) {
        guard let pdfView, idx >= 0, idx < selections.count else { return }
        activeIdx = idx
        let sel = selections[idx]
        // Drive autoscroll via the native selection — `scrollSelectionToVisible`
        // is the only PDFKit hook that knows how to flip pages — then drop it
        // immediately so the blue selection ring stops competing with the
        // orange `searchActive` annotation we paint below.
        pdfView.setCurrentSelection(sel, animate: false)
        pdfView.scrollSelectionToVisible(nil)
        pdfView.setCurrentSelection(nil, animate: false)
        repaintActiveAnnotations(for: sel)
    }

    private func addMatchAnnotations() {
        let color = HighlightStyle.nsColor(for: .searchMatch)
        for sel in selections {
            guard let page = sel.pages.first else { continue }
            let bounds = sel.bounds(for: page)
            let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            ann.color = color
            page.addAnnotation(ann)
            matchAnnotations.append(ann)
        }
    }

    private func clearActiveAnnotations() {
        for ann in activeAnnotations { ann.page?.removeAnnotation(ann) }
        activeAnnotations.removeAll()
    }

    /// Repaints the active-match decoration on top of the existing yellow match
    /// annotation: an orange `.highlight` for the fill plus a thin `.square`
    /// outline for the border, since PDFKit highlights don't accept a border on
    /// their own.
    private func repaintActiveAnnotations(for selection: PDFSelection) {
        clearActiveAnnotations()
        guard let page = selection.pages.first else { return }
        let bounds = selection.bounds(for: page)

        let fill = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        fill.color = HighlightStyle.nsColor(for: .searchActive)
        page.addAnnotation(fill)
        activeAnnotations.append(fill)

        let border = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        border.color = HighlightStyle.nsBorderColor(for: .searchActive)
        let lineBorder = PDFBorder()
        lineBorder.lineWidth = 1.5
        border.border = lineBorder
        page.addAnnotation(border)
        activeAnnotations.append(border)
    }
}
