import AppKit
import Vision

// Vision/CoreImage helpers for edit mode. All completion handlers hop to main.
enum VisionTools {
    // MARK: - OCR

    struct OCRWord {
        let text: String
        let box: CGRect // image pixel coords, bottom-left origin
    }

    static func recognizeText(in image: CGImage,
                              completion: @escaping (String, [OCRWord]) -> Void) {
        var done = false
        let request = VNRecognizeTextRequest { req, _ in
            done = true
            var lines: [String] = []
            var words: [OCRWord] = []
            let w = CGFloat(image.width), h = CGFloat(image.height)
            for obs in (req.results as? [VNRecognizedTextObservation]) ?? [] {
                guard let cand = obs.topCandidates(1).first else { continue }
                lines.append(cand.string)
                let str = cand.string
                var idx = str.startIndex
                for token in str.split(separator: " ") {
                    guard let range = str.range(of: token, range: idx..<str.endIndex)
                    else { continue }
                    idx = range.upperBound
                    guard let boxObs = try? cand.boundingBox(for: range) else { continue }
                    let bb = boxObs.boundingBox
                    words.append(OCRWord(
                        text: String(token),
                        box: CGRect(x: bb.minX * w, y: bb.minY * h,
                                    width: bb.width * w, height: bb.height * h)))
                }
            }
            DispatchQueue.main.async { completion(lines.joined(separator: "\n"), words) }
        }
        request.recognitionLevel = .accurate
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        perform(request, on: image) {
            if !done { DispatchQueue.main.async { completion("", []) } }
        }
    }

    // MARK: - QR / barcodes

    static func detectBarcodes(in image: CGImage,
                               completion: @escaping ([String]) -> Void) {
        var done = false
        let request = VNDetectBarcodesRequest { req, _ in
            done = true
            let payloads = ((req.results as? [VNBarcodeObservation]) ?? [])
                .compactMap(\.payloadStringValue)
            DispatchQueue.main.async { completion(payloads) }
        }
        perform(request, on: image) {
            if !done { DispatchQueue.main.async { completion([]) } }
        }
    }

    // MARK: - faces

    static func detectFaces(in image: CGImage,
                            completion: @escaping ([CGRect]) -> Void) {
        var done = false
        let request = VNDetectFaceRectanglesRequest { req, _ in
            done = true
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let rects = ((req.results as? [VNFaceObservation]) ?? []).map { obs -> CGRect in
                let bb = obs.boundingBox
                return CGRect(x: bb.minX * w, y: bb.minY * h,
                              width: bb.width * w, height: bb.height * h)
                    .insetBy(dx: -bb.width * w * 0.1, dy: -bb.height * h * 0.1)
            }
            DispatchQueue.main.async { completion(rects) }
        }
        perform(request, on: image) {
            if !done { DispatchQueue.main.async { completion([]) } }
        }
    }

    // MARK: - PII detection (regex over OCR words)

    static let piiPatterns: [(String, NSRegularExpression)] = {
        let sources = [
            ("email", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
            ("phone", #"\+?\d[\d ()\-]{7,}\d"#),
            ("card", #"(?:\d[ -]?){13,19}"#),
            ("ssn", #"\d{3}-\d{2}-\d{4}"#),
            ("apikey", #"(?:sk|pk|ghp|gho|xox[bap]|AKIA|AIza)[A-Za-z0-9_\-]{10,}"#),
            ("token", #"[A-Za-z0-9+/_\-]{32,}={0,2}"#),
        ]
        return sources.compactMap { name, pat in
            (try? NSRegularExpression(pattern: pat)).map { (name, $0) }
        }
    }()

    static func findPII(in words: [OCRWord]) -> [CGRect] {
        var out: [CGRect] = []
        for word in words {
            let range = NSRange(word.text.startIndex..., in: word.text)
            for (_, regex) in piiPatterns
            where regex.firstMatch(in: word.text, range: range).map({
                // whole-word match only, to avoid censoring ordinary text
                $0.range.length >= range.length - 2
            }) == true {
                out.append(word.box.insetBy(dx: -3, dy: -3))
                break
            }
        }
        return out
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

    // onFailure runs when perform throws before the request callback fired,
    // so callers always get their completion.
    private static func perform(_ request: VNRequest, on image: CGImage,
                                onFailure: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                onFailure()
            }
        }
    }
}
