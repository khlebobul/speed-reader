import Vision
import CoreGraphics

/// Converts VNRecognizedTextObservation arrays into TextBlock arrays
/// with proper reading order.
enum OCRTextRebuilder {

    /// Minimum confidence threshold to include an observation.
    private static let minConfidence: Float = 0.4

    /// Builds TextBlocks from OCR results, preserving Vision's reading order
    /// while clustering observations into paragraphs.
    static func buildBlocks(
        from results: [OCREngine.PageResult],
        pageSize: CGSize,
        pageNumber: Int
    ) -> [TextBlock] {
        let observations = results
            .flatMap { $0.observations }
            .filter { $0.confidence > minConfidence }

        guard !observations.isEmpty else { return [] }

        // Convert normalized bounding boxes to page coordinates
        let positioned = observations.compactMap { obs -> PositionedLine? in
            guard let text = obs.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let box = obs.boundingBox
            return PositionedLine(
                text: text,
                x: box.minX * pageSize.width,
                y: (1.0 - box.maxY) * pageSize.height, // flip Y: Vision bottom-left -> top-left
                width: box.width * pageSize.width,
                height: box.height * pageSize.height,
                centerY: (1.0 - box.midY) * pageSize.height
            )
        }

        // Cluster lines into paragraphs by vertical gap
        let paragraphs = clusterIntoParagraphs(positioned)

        // Build TextBlocks
        return paragraphs.enumerated().compactMap { _, lines in
            let text = lines.map(\.text).joined(separator: " ")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let xMin = lines.map(\.x).min() ?? 0
            let xMax = lines.map { $0.x + $0.width }.max() ?? 0

            return TextBlock(
                text: trimmed,
                type: .paragraph,
                column: nil,
                pageNumber: pageNumber,
                range: trimmed.startIndex..<trimmed.endIndex,
                y: lines.first?.y ?? 0,
                xMin: xMin,
                xMax: xMax
            )
        }
    }

    // MARK: - Word Locations

    /// Extracts word-level bounding boxes from OCR observations.
    /// Returns words paired with their PDF-coordinate locations for highlighting.
    static func buildWordLocations(
        from results: [OCREngine.PageResult],
        pageSize: CGSize,
        pageIndex: Int
    ) -> [(word: String, location: OCRWordLocation)] {
        let observations = results
            .flatMap { $0.observations }
            .filter { $0.confidence > minConfidence }

        guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern, options: []) else {
            return []
        }

        var wordLocations: [(word: String, location: OCRWordLocation)] = []

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            // Match buildBlocks filtering: skip empty observations
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)

            for match in matches {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let word = String(text[swiftRange])
                guard !word.isEmpty else { continue }

                // Get bounding box from VNRecognizedText
                guard let box = try? candidate.boundingBox(for: swiftRange) else { continue }

                // Convert normalized Vision coordinates to PDF page points.
                // Vision: origin bottom-left, [0,1] normalized — same origin as PDFKit.
                let corners = [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft]
                let xs = corners.map { $0.x * pageSize.width }
                let ys = corners.map { $0.y * pageSize.height }

                let rect = CGRect(
                    x: xs.min()!,
                    y: ys.min()!,
                    width: xs.max()! - xs.min()!,
                    height: ys.max()! - ys.min()!
                )

                wordLocations.append((
                    word: word,
                    location: OCRWordLocation(pageIndex: pageIndex, rect: rect)
                ))
            }
        }

        return wordLocations
    }

    // MARK: - Private

    private struct PositionedLine {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let centerY: CGFloat
    }

    /// Groups lines into paragraphs based on vertical and horizontal proximity.
    /// Lines within ~1.5x median line height vertically AND with overlapping X ranges
    /// are considered part of the same paragraph.
    private static func clusterIntoParagraphs(_ lines: [PositionedLine]) -> [[PositionedLine]] {
        guard lines.count > 1 else { return lines.isEmpty ? [] : [lines] }

        // Compute median line height
        let heights = lines.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let paragraphGapThreshold = medianHeight * 1.5

        var paragraphs: [[PositionedLine]] = []
        var current: [PositionedLine] = [lines[0]]

        for line in lines.dropFirst() {
            let prev = current.last!
            let prevBottom = prev.y + prev.height
            let gap = line.y - prevBottom

            // Check horizontal overlap: lines in different page regions
            // (e.g. left label vs right value) should not be merged
            let prevRight = prev.x + prev.width
            let lineRight = line.x + line.width
            let overlapStart = max(prev.x, line.x)
            let overlapEnd = min(prevRight, lineRight)
            let overlap = max(0, overlapEnd - overlapStart)
            let smallerWidth = min(prev.width, line.width)
            let hasXOverlap = smallerWidth <= 0 || overlap / smallerWidth > 0.15

            if gap > paragraphGapThreshold || !hasXOverlap {
                paragraphs.append(current)
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs
    }
}
