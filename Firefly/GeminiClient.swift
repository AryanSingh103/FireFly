import Foundation

enum GeminiClient {
    enum Failure: Error {
        /// No internet, or the request timed out.
        case offline
        /// Google refused the request for quota (HTTP 429). Free-tier keys allow only a few requests a day per model.
        case quota(retryAfter: TimeInterval)
        /// Missing key, bad model name, or an unexpected reply.
        case failed
    }

    /// The nearest hazard as "<Object>, <left|ahead|right>", or "none".
    static func nearestHazard(in jpeg: Data) async throws -> String {
        let prompt = """
        This photo is from a chest-worn phone helping a blind walker. \
        Name only the single nearest hazard in their path as "<Object>, <left|ahead|right>", \
        for example "Chair, left". Prefer: person, bicycle, car, bus, truck, chair, couch, backpack, \
        suitcase, bench, stop sign, traffic light, dog, table, stairs, door, doorway, wet floor sign, curb. \
        If the path is clear, reply "none".
        """
        return try await generate(prompt: prompt, jpeg: jpeg, json: false)
    }

    static func answer(_ question: String, in jpeg: Data) async throws -> String {
        let prompt = """
        You are Firefly, a calm enchanted guide for a blind or low-vision person. \
        This photo is from a phone on their chest. Answer in under 18 words. \
        Use left, ahead, or right. Be honest if unsure — say you think or aren't sure. \
        Never claim you can detect glass. Never invent crosswalks or signal colors. \
        Question: \(question)
        """
        return try await generate(prompt: prompt, jpeg: jpeg, json: false)
    }

    /// Centre of the target in the photo as fractions (x from the left, y from the top), or nil if missing.
    static func locate(_ target: String, in jpeg: Data) async throws -> SIMD2<Float>? {
        let prompt = """
        Find the \(target) in this photo (door, doorway, EXIT sign, or exit). \
        If several, pick the nearest usable one. Reply with JSON only: \
        {"found": true, "box_2d": [ymin, xmin, ymax, xmax]} with coordinates normalized to 0-1000, \
        or {"found": false} if it is not visible.
        """
        let text = try await generate(prompt: prompt, jpeg: jpeg, json: true)
        let cleaned = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        guard let box = (object?["box_2d"] as? [NSNumber])?.map(\.floatValue), box.count == 4 else { return nil }
        return SIMD2((box[1] + box[3]) / 2000, (box[0] + box[2]) / 2000)
    }

    private static func generate(prompt: String, jpeg: Data, json: Bool) async throws -> String {
        var request: URLRequest
        if Secrets.backendURL.isEmpty {
            guard !Secrets.geminiKey.isEmpty,
                  let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Secrets.geminiModel):generateContent")
            else { throw Failure.failed }
            request = URLRequest(url: url)
            request.setValue(Secrets.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            guard let url = URL(string: Secrets.backendURL + "/gemini") else { throw Failure.failed }
            request = URLRequest(url: url)
            request.setValue(Secrets.backendKey, forHTTPHeaderField: "x-functions-key")
        }

        var generationConfig: [String: Any] = ["temperature": 0.2]
        if json { generationConfig["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": generationConfig
        ]
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw Failure.quota(retryAfter: retryDelay(in: data) ?? 60) }
        guard status == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { throw Failure.failed }
        return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads "retryDelay": "1654s" from a 429 reply.
    private static func retryDelay(in data: Data) -> TimeInterval? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = (root["error"] as? [String: Any])?["details"] as? [[String: Any]]
        else { return nil }
        for detail in details {
            if let delay = detail["retryDelay"] as? String, let seconds = TimeInterval(delay.dropLast()) {
                return seconds
            }
        }
        return nil
    }
}
