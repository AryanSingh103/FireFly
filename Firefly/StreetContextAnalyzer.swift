import ARKit
import CoreImage
import Vision

/// Emergency street context: cars, buildings, and pedestrian / traffic signal color.
/// Aimed at the NYC "pharmacy a block away" use case — information you can act on, not turn-by-turn routing.
enum StreetContextAnalyzer {
    struct Report {
        var cars: [(zone: Zone, confidence: Float)] = []
        var buildingsOrFacades: Bool = false
        /// Approximate signal color if a light-like region was found.
        var crossingLight: CrossingLight = .unknown
        var signs: Bool = false

        enum CrossingLight: String {
            case unknown, white, red, green, yellow

            var spoken: String {
                switch self {
                case .unknown: return "I can't clearly read the crossing light."
                case .white: return "The pedestrian light looks white — walk signal."
                case .red: return "The light looks red — don't cross yet."
                case .green: return "The light looks green."
                case .yellow: return "The light looks yellow — be careful."
                }
            }
        }

        func spokenAnswer(for question: String) -> String? {
            let q = question.lowercased()
            if q.contains("light") || q.contains("signal") || q.contains("crossing")
                || q.contains("white") || q.contains("red") || q.contains("walk") {
                return crossingLight.spoken
            }
            if q.contains("car") || q.contains("vehicle") || q.contains("road") || q.contains("traffic") {
                if cars.isEmpty { return "I don't clearly see cars right now." }
                let sides = cars.map { directionWord($0.zone) }.uniqued().joined(separator: " and ")
                return "Car \(sides). Stay back until you're sure it's clear."
            }
            if q.contains("building") || q.contains("store") || q.contains("pharmacy") || q.contains("street") {
                if buildingsOrFacades {
                    return "Buildings or storefronts look close ahead. Ask me about signs if you need the name."
                }
                return "I don't clearly see a building facade right now."
            }
            if q.contains("sign") {
                return signs
                    ? "There's a sign ahead. Ask me what it says if you need the text."
                    : "I don't clearly see a sign right now."
            }
            return nil
        }
    }

    static func looksLikeStreetQuestion(_ lowered: String) -> Bool {
        let keys = ["car", "vehicle", "traffic", "crossing", "light", "signal", "walk", "red", "white",
                    "building", "pharmacy", "street", "road", "avenue", "ave", "crosswalk"]
        return keys.contains { lowered.contains($0) }
    }

    nonisolated static func scan(_ frame: ARFrame) -> Report {
        var report = Report()
        let classify = VNClassifyImageRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 8
        rectangles.minimumConfidence = 0.4
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right)

        do {
            try handler.perform([classify, rectangles])
        } catch {
            return report
        }

        for observation in classify.results ?? [] where observation.confidence >= 0.18 {
            let id = observation.identifier
            if id.contains("car") || id.contains("truck") || id.contains("bus") || id.contains("taxi") {
                report.cars.append((.center, observation.confidence))
            }
            if id.contains("building") || id.contains("shop") || id.contains("storefront")
                || id.contains("skyscraper") || id.contains("apartment") {
                report.buildingsOrFacades = true
            }
            if id.contains("sign") || id.contains("traffic_light") || id.contains("street_sign") {
                report.signs = true
            }
            if id.contains("traffic_light") || id.contains("traffic light") {
                report.crossingLight = sampleLightColor(in: frame)
            }
        }

        // Tall thin rectangles near the top third often are signals / signs — sample their color.
        if report.crossingLight == .unknown, let rects = rectangles.results {
            for box in rects where box.boundingBox.maxY > 0.55 && box.boundingBox.height > 0.05 {
                let color = sampleColor(in: frame, normalizedBox: box.boundingBox)
                if color != .unknown {
                    report.crossingLight = color
                    break
                }
            }
        }

        return report
    }

    private nonisolated static func sampleLightColor(in frame: ARFrame) -> Report.CrossingLight {
        // Center-upper crop where a chest-worn phone often sees the signal.
        let box = CGRect(x: 0.35, y: 0.55, width: 0.3, height: 0.35)
        return sampleColor(in: frame, normalizedBox: box)
    }

    /// Vision / Core Image: average hue in a crop → coarse white / red / green / yellow.
    private nonisolated static func sampleColor(
        in frame: ARFrame,
        normalizedBox: CGRect
    ) -> Report.CrossingLight {
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let w = image.extent.width
        let h = image.extent.height
        // Vision bottom-left → CI bottom-left after orientation.
        let rect = CGRect(
            x: normalizedBox.minX * w,
            y: normalizedBox.minY * h,
            width: normalizedBox.width * w,
            height: normalizedBox.height * h
        ).integral.intersection(image.extent)
        guard !rect.isNull, rect.width > 4, rect.height > 4 else { return .unknown }

        let cropped = image.cropped(to: rect)
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            cropped,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Float(bitmap[0]) / 255
        let g = Float(bitmap[1]) / 255
        let b = Float(bitmap[2]) / 255
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let sat = maxC > 0 ? (maxC - minC) / maxC : 0

        if sat < 0.2, maxC > 0.65 { return .white }
        if r > g + 0.15, r > b + 0.15 { return .red }
        if g > r + 0.1, g > b + 0.05 { return .green }
        if r > 0.5, g > 0.4, b < 0.35 { return .yellow }
        return .unknown
    }

    private static func directionWord(_ zone: Zone) -> String {
        switch zone {
        case .left: return "on your left"
        case .center: return "ahead"
        case .right: return "on your right"
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
