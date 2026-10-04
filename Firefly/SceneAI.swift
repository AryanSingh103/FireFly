import ARKit
import Foundation
import Network

/// Gemini when the network is up; on-device Gemma-style answers when it isn't.
enum SceneAI {
    private static let monitor = NWPathMonitor()
    private static let queue = DispatchQueue(label: "firefly.reachability")
    private static let lock = NSLock()
    private nonisolated(unsafe) static var pathSatisfied = true
    private nonisolated(unsafe) static var started = false

    static func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            lock.lock()
            pathSatisfied = path.status == .satisfied
            lock.unlock()
        }
        monitor.start(queue: queue)
    }

    static var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pathSatisfied
    }

    /// Prefer Gemini; fall back to on-device Gemma when offline or when Gemini fails.
    static func answer(_ question: String, jpeg: Data, frame: ARFrame?) async -> String {
        if isOnline {
            do {
                return try await GeminiClient.answer(question, in: jpeg)
            } catch GeminiClient.Failure.offline, GeminiClient.Failure.quota {
                // Fall through to Gemma.
            } catch {
                // Fall through — still try local.
            }
        }
        if let frame {
            return GemmaClient.answer(question, in: frame)
        }
        return "I can't reach the internet right now, but I'm still watching for obstacles."
    }

    static func nearestHazard(jpeg: Data, frame: ARFrame?) async throws -> String {
        if isOnline {
            do {
                return try await GeminiClient.nearestHazard(in: jpeg)
            } catch GeminiClient.Failure.quota {
                throw GeminiClient.Failure.quota(retryAfter: 60)
            } catch {
                // Offline / failed → local.
            }
        }
        if let frame {
            return GemmaClient.nearestHazard(in: frame)
        }
        throw GeminiClient.Failure.offline
    }
}
