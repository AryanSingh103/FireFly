import ARKit

enum DepthZoneAnalyzer {
    /// Nearest obstacle distance in metres as (left, center, right), assuming the phone is worn in portrait.
    nonisolated static func nearestPerZone(in depthData: ARDepthData) -> SIMD3<Float> {
        let maxRange: Float = 5
        let minRange: Float = 0.15
        let minSamples = 30
        let percentile = 0.05
        // Fraction of the portrait image height that is scanned (0 = top, 1 = bottom).
        // Raising bandBottom catches lower obstacles but starts picking up the floor.
        let bandTop: Float = 0.35
        let bandBottom: Float = 0.70

        let clear = SIMD3<Float>(repeating: maxRange)
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

        var samples: [[Float]] = [[], [], []]
        for y in stride(from: 0, to: height, by: 2) {
            // 0 = left, 1 = center, 2 = right. If left and right come out swapped on the device, use `y * 3 / height`.
            let zone = (height - 1 - y) * 3 / height
            let depthRow = (depthBase + y * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase.map { ($0 + y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self) }
            for x in stride(from: xStart, to: xEnd, by: 2) {
                if let confidenceRow, confidenceRow[x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let depth = depthRow[x]
                if depth.isFinite, depth > minRange, depth < maxRange {
                    samples[zone].append(depth)
                }
            }
        }

        var result = clear
        for zone in 0..<3 where samples[zone].count >= minSamples {
            samples[zone].sort()
            result[zone] = samples[zone][Int(Double(samples[zone].count) * percentile)]
        }
        return result
    }
}
