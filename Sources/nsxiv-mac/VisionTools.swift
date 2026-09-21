import AppKit
import Vision

// Vision/CoreImage helpers for edit mode. Public completions run on the main queue.
enum VisionTools {
    // MARK: - OCR

    struct OCRWord {
        let text: String
        let box: CGRect // image pixel coords, bottom-left origin
    }

    static func recognizeText(in image: CGImage,
                              completion: @escaping (String, [OCRWord]) -> Void) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        run(request, on: image) { (found: [VNRecognizedTextObservation]) in
            var lines: [String] = []
            var words: [OCRWord] = []
            let w = CGFloat(image.width), h = CGFloat(image.height)
            for obs in found {
                guard let cand = obs.topCandidates(1).first else { continue }
                lines.append(cand.string)
                for range in cand.string.ranges(of: #/\S+/#) {
                    guard let box = try? cand.boundingBox(for: range) else { continue }
                    let bb = box.boundingBox
                    words.append(OCRWord(
                        text: String(cand.string[range]),
                        box: CGRect(x: bb.minX * w, y: bb.minY * h,
                                    width: bb.width * w, height: bb.height * h)))
                }
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { [words] in completion(text, words) }
        }
    }

    // MARK: - QR / barcodes

    static func detectBarcodes(in image: CGImage,
                               completion: @escaping ([String]) -> Void) {
        run(VNDetectBarcodesRequest(), on: image) { (found: [VNBarcodeObservation]) in
            let payloads = found.compactMap(\.payloadStringValue)
            DispatchQueue.main.async { completion(payloads) }
        }
    }

    // MARK: - faces

    static func detectFaces(in image: CGImage,
                            completion: @escaping ([CGRect]) -> Void) {
        run(VNDetectFaceRectanglesRequest(), on: image) { (found: [VNFaceObservation]) in
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let rects = found.map { obs in
                let bb = obs.boundingBox
                return CGRect(x: bb.minX * w, y: bb.minY * h,
                              width: bb.width * w, height: bb.height * h)
                    .insetBy(dx: -bb.width * w * 0.1, dy: -bb.height * h * 0.1)
            }
            DispatchQueue.main.async { completion(rects) }
        }
    }

    // MARK: - PII detection (regex over OCR words)

    // email, phone, card, SSN, API key, token
    static let piiPatterns = [
        #/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#,
        #/\+?\d[\d ()\-]{7,}\d/#,
        #/(?:\d[ -]?){13,19}/#,
        #/\d{3}-\d{2}-\d{4}/#,
        #/(?:sk|pk|ghp|gho|xox[bap]|AKIA|AIza)[A-Za-z0-9_\-]{10,}/#,
        #/[A-Za-z0-9+/_\-]{32,}={0,2}/#,
    ]

    // the match may fall short of the OCR token by two characters of stray punctuation;
    // anything looser would censor ordinary words
    static func findPII(in words: [OCRWord]) -> [CGRect] {
        words.filter { word in
            piiPatterns.contains { pattern in
                word.text.firstMatch(of: pattern).map { $0.output.count >= word.text.count - 2 } == true
            }
        }.map { $0.box.insetBy(dx: -3, dy: -3) }
    }

    // MARK: - background removal (macOS 14+)

    static func removeBackground(from image: CGImage,
                                 completion: @escaping (CGImage?) -> Void) {
        guard #available(macOS 14.0, *) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            var result: CGImage?
            do {
                try handler.perform([request])
                if let obs = request.results?.first {
                    let maskBuf = try obs.generateScaledMaskForImage(
                        forInstances: obs.allInstances, from: handler)
                    let mask = CIImage(cvPixelBuffer: maskBuf)
                    let src = CIImage(cgImage: image)
                    let f = CIFilter(name: "CIBlendWithMask")!
                    f.setValue(src, forKey: kCIInputImageKey)
                    f.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
                    f.setValue(mask, forKey: kCIInputMaskImageKey)
                    if let out = f.outputImage {
                        result = CIContext().createCGImage(out, from: src.extent)
                    }
                }
            } catch {
                result = nil
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - invert

    static func invert(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIColorInvert") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let out = f.outputImage else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }

    // perform() fills request.results before it returns; a throw leaves them empty
    private static func run<T: VNObservation>(_ request: VNRequest, on image: CGImage,
                                              completion: @escaping ([T]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let found = (request.results as? [T]) ?? []
            completion(found)
        }
    }
}
