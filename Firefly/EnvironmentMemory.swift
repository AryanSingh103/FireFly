import ARKit
import Foundation
import simd

/// Learns familiar places from LiDAR as the wearer walks — groundwork for future navigation.
///
/// **Off by default** (`isEnabled = false`) so it never touches the live safety loop or AR session.
/// Flip the flag in a future build to start recording mesh snapshots and path samples.
@MainActor
final class EnvironmentMemory: ObservableObject {
    /// Master switch. Keep false for GirlHacks demo stability.
    static let isEnabled = false

    struct Vec3: Codable, Equatable {
        var x: Float
        var y: Float
        var z: Float

        init(_ v: SIMD3<Float>) {
            x = v.x; y = v.y; z = v.z
        }

        var simd: SIMD3<Float> { SIMD3(x, y, z) }
    }

    struct VisitSample: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        /// Device pose translation when sampled.
        let position: Vec3
        /// Coarse left / center / right clearances at that pose.
        let clearances: [Float]
    }

    struct PlaceMap: Codable {
        var name: String
        var samples: [VisitSample]
        /// Placeholder for future A* / corridor graph nodes.
        var pathNodes: [Vec3]
    }

    @Published private(set) var isRecording = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastScanPreview: [SIMD3<Float>] = []
    private(set) var currentMap = PlaceMap(name: "untitled", samples: [], pathNodes: [])

    private let minStep: Float = 0.4
    private var lastPosition: SIMD3<Float>?

    /// Call from the frame loop only when `isEnabled` is true.
    func ingest(frame: ARFrame, distances: SIMD3<Float>) {
        guard Self.isEnabled, isRecording else { return }
        let position = SIMD3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        if let last = lastPosition, simd_distance(last, position) < minStep { return }
        lastPosition = position
        let sample = VisitSample(
            id: UUID(),
            timestamp: Date(),
            position: Vec3(position),
            clearances: [distances.x, distances.y, distances.z]
        )
        currentMap.samples.append(sample)
        sampleCount = currentMap.samples.count
        // Keep a short ring of points for a future "show LiDAR scan" overlay.
        lastScanPreview.append(position)
        if lastScanPreview.count > 200 { lastScanPreview.removeFirst() }
    }

    func startRecording(placeName: String = "neighborhood") {
        guard Self.isEnabled else { return }
        currentMap = PlaceMap(name: placeName, samples: [], pathNodes: [])
        sampleCount = 0
        lastScanPreview = []
        lastPosition = nil
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
        rebuildPathNodes()
    }

    /// Very rough corridor: subsample visit positions as future path-graph nodes.
    private func rebuildPathNodes() {
        currentMap.pathNodes = currentMap.samples.enumerated().compactMap { index, sample in
            index % 5 == 0 ? sample.position : nil
        }
    }

    /// Future: plan a walk between two remembered points. Stub returns nil while disabled / unfinished.
    func suggestedPath(from: SIMD3<Float>, to: SIMD3<Float>) -> [SIMD3<Float>]? {
        guard Self.isEnabled, currentMap.pathNodes.count >= 2 else { return nil }
        // Placeholder — real planner would run on pathNodes + clearance samples.
        return [from] + currentMap.pathNodes.map(\.simd) + [to]
    }

    /// Persistence hook for later (Documents directory). No-ops while disabled.
    func save() throws {
        guard Self.isEnabled else { return }
        let url = try fileURL()
        let data = try JSONEncoder().encode(currentMap)
        try data.write(to: url, options: .atomic)
    }

    func load() throws {
        guard Self.isEnabled else { return }
        let url = try fileURL()
        let data = try Data(contentsOf: url)
        currentMap = try JSONDecoder().decode(PlaceMap.self, from: data)
        sampleCount = currentMap.samples.count
    }

    private func fileURL() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return docs.appendingPathComponent("firefly-environment-map.json")
    }
}
