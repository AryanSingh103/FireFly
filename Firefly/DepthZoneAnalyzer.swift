import ARKit

struct DepthReading {
    /// Nearest obstacle distance in metres as (left, center, right); maxRange when a zone is clear.
    let distances: SIMD3<Float>
    /// Per zone, where the reported distance was measured, as fractions of the upright image
    /// (x from the left, y from the top). nil when the zone had too few readings.
    let points: [SIMD2<Float>?]
}

enum DepthZoneAnalyzer {
    static let maxRange: Float = 5
    static let minRange: Float = 0.15
    static let minSamples = 30
    static let percentile = 0.05
    // Fraction of the portrait image height that is scanned (0 = top, 1 = bottom).
    // Raising bandBottom catches lower obstacles but starts picking up the floor.
    static let bandTop: Float = 0.35
    static let bandBottom: Float = 0.70

    /// Assumes the phone is worn in portrait.
    nonisolated static func nearestPerZone(in depthData: ARDepthData) -> DepthReading {
        let clear = DepthReading(distances: SIMD3(repeating: maxRange), points: [nil, nil, nil])
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return clear }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // The buffer is in landscape sensor orientation. With the phone in portrait,
        // buffer x runs top to bottom and buffer y runs right to left.
        let xStart = Int(Float(width) * bandTop)
        let xEnd = Int(Float(width) * bandBottom)

        var samples: [[(depth: Float, x: Int, y: Int)]] = [[], [], []]
        for y in stride(from: 0, to: height, by: 2) {
            // 0 = left, 1 = center, 2 = right. If left and right come out swapped on the device, use `y * 3 / height`.
            let zone = (height - 1 - y) * 3 / height
            let depthRow = (depthBase + y * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase.map { ($0 + y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self) }
            for x in stride(from: xStart, to: xEnd, by: 2) {
                if let confidenceRow, confidenceRow[x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let depth = depthRow[x]
                if depth.isFinite, depth > minRange, depth < maxRange {
                    samples[zone].append((depth, x, y))
                }
            }
        }

        var distances = clear.distances
        var points = clear.points
        for zone in 0..<3 where samples[zone].count >= minSamples {
            samples[zone].sort { $0.depth < $1.depth }
            let chosen = samples[zone][Int(Double(samples[zone].count) * percentile)]
            distances[zone] = chosen.depth
            points[zone] = SIMD2(
                1 - (Float(chosen.y) + 0.5) / Float(height),
                (Float(chosen.x) + 0.5) / Float(width)
            )
        }
        return DepthReading(distances: distances, points: points)
    }
}
