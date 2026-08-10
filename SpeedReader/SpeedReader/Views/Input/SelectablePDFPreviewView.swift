import SwiftUI
import PDFKit

/// PDF preview that allows clicking on words to select a start position.
/// Uses ocrWordLocations to map click coordinates to RSVP word indices.
struct SelectablePDFPreviewView: NSViewRepresentable {
    let url: URL
    let wordLocations: [OCRWordLocation?]
    var selectedWordIndex: Int? = nil
    var onWordSelected: ((Int) -> Void)? = nil
    /// Out-binding for the underlying `PDFView` — see `PDFPreviewView.pdfViewRef`.
    var pdfViewRef: Binding<PDFView?>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onWordSelected: onWordSelected, wordLocations: wordLocations)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor.textBackgroundColor

        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }

        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        pdfView.addGestureRecognizer(clickGesture)
        context.coordinator.pdfView = pdfView

        if let pdfViewRef {
            DispatchQueue.main.async { pdfViewRef.wrappedValue = pdfView }
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onWordSelected = onWordSelected
        context.coordinator.wordLocations = wordLocations

        if pdfView.document?.documentURL != url {
            if let document = PDFDocument(url: url) {
                pdfView.document = document
            }
        }

        // Update highlight for selected word
        context.coordinator.updateHighlight(selectedIndex: selectedWordIndex, in: pdfView)
    }

    class Coordinator: NSObject {
        var onWordSelected: ((Int) -> Void)?
        var wordLocations: [OCRWordLocation?]
        weak var pdfView: PDFView?
        private var startMarkerAnnotations: [PDFAnnotation] = []
        private var lastHighlightedIndex: Int = -1

        init(onWordSelected: ((Int) -> Void)?, wordLocations: [OCRWordLocation?]) {
            self.onWordSelected = onWordSelected
            self.wordLocations = wordLocations
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView else { return }

            let locationInView = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: locationInView, nearest: false) else { return }
            let pagePoint = pdfView.convert(locationInView, to: page)
            let pageIndex = pdfView.document?.index(for: page) ?? 0

            // Find the closest word on this page
            var bestIndex = -1
            var bestDistance: CGFloat = .greatestFiniteMagnitude

            for (wordIndex, location) in wordLocations.enumerated() {
                guard let loc = location, loc.pageIndex == pageIndex else { continue }

                if loc.rect.contains(pagePoint) {
                    bestIndex = wordIndex
                    break
                }

                // Check proximity for near-misses
                let dx: CGFloat = pagePoint.x - loc.rect.midX
                let dy: CGFloat = pagePoint.y - loc.rect.midY
                let distance: CGFloat = hypot(dx, dy)

                if distance < bestDistance && distance < 30.0 {
                    bestDistance = distance
                    bestIndex = wordIndex
                }
            }

            if bestIndex >= 0 {
                onWordSelected?(bestIndex)
            }
        }

        func updateHighlight(selectedIndex: Int?, in pdfView: PDFView) {
            guard let document = pdfView.document else { return }

            clearStartMarker()

            guard let index = selectedIndex, index >= 0,
                  index < wordLocations.count,
                  let location = wordLocations[index],
                  let page = document.page(at: location.pageIndex) else {
                lastHighlightedIndex = -1
                return
            }

            guard index != lastHighlightedIndex else { return }

            // Two annotations: a translucent fill in the preset hue plus a
            // saturated `.square` outline. PDFKit highlights can't carry a
            // border directly, so the outline is the only way to match the
            // bordered look the WK/SwiftUI start-marker uses.
            let highlight = PDFAnnotation(bounds: location.rect, forType: .highlight, withProperties: nil)
            highlight.color = HighlightStyle.nsColor(for: .startMarker)
            page.addAnnotation(highlight)
            startMarkerAnnotations.append(highlight)

            let border = PDFAnnotation(bounds: location.rect, forType: .square, withProperties: nil)
            border.color = HighlightStyle.nsBorderColor(for: .startMarker)
            let lineBorder = PDFBorder()
            lineBorder.lineWidth = 1
            border.border = lineBorder
            page.addAnnotation(border)
            startMarkerAnnotations.append(border)

            lastHighlightedIndex = index

            let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: location.rect.maxY + 20))
            pdfView.go(to: destination)
        }

        private func clearStartMarker() {
            for ann in startMarkerAnnotations { ann.page?.removeAnnotation(ann) }
            startMarkerAnnotations.removeAll()
        }
    }
}
