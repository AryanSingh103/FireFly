import Foundation

enum GeminiClient {
    struct Failure: Error {}

    /// The nearest hazard as "<Object>, <left|ahead|right>", or "none".
    static func nearestHazard(in jpeg: Data) async throws -> String {
        let prompt = """
        This photo is from a phone worn on the chest of a blind person who is walking. \
        Name only the single nearest hazard in their path, formatted exactly as "<Object>, <left|ahead|right>", \
        for example "Chair, left". Prefer these object names when they fit: Chair, Table, Desk, Couch, Person, \
        Wall, Door, Doorway, Backpack, Bag, Stairs, Trash can. If the path is clear, reply "none".
        """
        return try await generate(prompt: prompt, jpeg: jpeg, json: false)
    }

    static func answer(_ question: String, in jpeg: Data) async throws -> String {
        let prompt = """
        You are Firefly, a calm guide for a blind person. This photo is from a phone worn on their chest. \
        Answer their question in under 12 words, using left, ahead or right for directions. \
        Question: \(question)
        """
        return try await generate(prompt: prompt, jpeg: jpeg, json: false)
    }

    /// Centre of the target in the photo as fractions (x from the left, y from the top), or nil if it is not visible.
    static func locate(_ target: String, in jpeg: Data) async throws -> SIMD2<Float>? {
        let prompt = """
        Find the \(target) in this photo. If there are several, pick the nearest. Reply with JSON only: \
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
            else { throw Failure() }
            request = URLRequest(url: url)
            request.setValue(Secrets.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            guard let url = URL(string: Secrets.backendURL + "/gemini") else { throw Failure() }
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { throw Failure() }
        return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
