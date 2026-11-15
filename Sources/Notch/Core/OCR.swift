import AppKit
import Vision

enum OCR {
    /// Recognised text, lines joined with newlines. Runs off the main thread.
    static func text(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([req])
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    static func text(in url: URL) async -> String {
        guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return await text(in: img)
    }
}
