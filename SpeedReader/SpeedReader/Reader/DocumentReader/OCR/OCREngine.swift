import Vision
import CoreGraphics

/// Actor wrapping VNRecognizeTextRequest for on-device OCR via Vision framework.
actor OCREngine {

    struct Options {
        var languages: [String] = ["en-US", "ru-RU"]
        var quality: Quality = .accurate
        var autoDetectLanguage: Bool = true

        enum Quality: String, CaseIterable, Codable {
            case fast
            case accurate

            var vnLevel: VNRequestTextRecognitionLevel {
                switch self {
                case .fast: return .fast
                case .accurate: return .accurate
                }
            }

            var label: String {
                switch self {
                case .fast: return "Fast"
                case .accurate: return "Accurate"
                }
            }
        }
    }

    struct PageResult {
        let pageIndex: Int
        let observations: [VNRecognizedTextObservation]
    }

    func recognize(
        cgImage: CGImage,
        pageIndex: Int = 0,
        options: Options = Options()
    ) throws -> PageResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.quality.vnLevel
        request.recognitionLanguages = options.languages
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = options.autoDetectLanguage

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return PageResult(
            pageIndex: pageIndex,
            observations: request.results ?? []
        )
    }
}
