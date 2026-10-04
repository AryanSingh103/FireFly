import ARKit
import Foundation
import Vision

/// On-device scene answers when Gemini is unreachable.
///
/// Hackathon prototype: uses Apple Vision classifications plus short template replies so Firefly
/// still answers offline. Swap the `answer` body for a bundled Gemma / MediaPipe LLM later —
/// the call site (`SceneAI`) already treats this as the offline model.
enum GemmaClient {
    /// Same spoken vocabulary as obstacle naming, so offline answers stay consistent with callouts.
    private static let spokenNames = ObstacleNamer.spokenNames

    static func answer(_ question: String, in frame: ARFrame) -> String {
        let labels = classify(frame)
        let lowered = question.lowercased()

        if StreetContextAnalyzer.looksLikeStreetQuestion(lowered) {
            let street = StreetContextAnalyzer.scan(frame)
            if let reply = street.spokenAnswer(for: lowered) { return reply }
        }

        if lowered.contains("in front") || lowered.contains("ahead") || lowered.contains("see")
            || lowered.contains("what") || lowered.contains("around") {
            if labels.isEmpty { return "I'm not sure what's there." }
            let top = labels.prefix(3).joined(separator: ", ")
            return "I think I see \(top) ahead."
        }

        if lowered.contains("car") || lowered.contains("vehicle") || lowered.contains("traffic") {
            if labels.contains(where: { $0 == "Car" || $0 == "Bicycle" }) {
                return "I think there's a vehicle ahead. Stay back until you're sure."
            }
            return "I don't clearly see a car right now."
        }

        if lowered.contains("person") || lowered.contains("people") {
            if labels.contains("Person") { return "There's a person ahead." }
            return "I don't clearly see a person right now."
        }

        if labels.isEmpty { return "I'm not sure what's there." }
        return "Nearby I notice \(labels.prefix(2).joined(separator: " and "))."
    }

    static func nearestHazard(in frame: ARFrame) -> String {
        let labels = classify(frame)
        guard let first = labels.first else { return "none" }
        return "\(first), ahead"
    }

    /// Labels seen across left / center / right of the upright image.
    private static func classify(_ frame: ARFrame) -> [String] {
        let classify = VNClassifyImageRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right)
        do {
            try handler.perform([classify, humans])
        } catch {
            return []
        }

        var names: [String] = []
        if let people = humans.results, people.contains(where: { $0.confidence > 0.45 }) {
            names.append("Person")
        }
        for observation in classify.results ?? [] where observation.confidence >= 0.2 {
            if let name = spokenNames[observation.identifier], !names.contains(name) {
                names.append(name)
            }
            if names.count >= 4 { break }
        }
        return names
    }
}
