import ARKit

/// What the obstacle detector sees: the LiDAR depth as a heat map, upright for a phone in portrait,
/// and where each zone's distance was measured. Drawn over the live camera view.
struct DebugPreview {
    let depth: CGImage
    let points: [SIMD2<Float>?]


    init?(frame: ARFrame, points: [SIMD2<Float>?]) {
        guard let depthData = frame.sceneDepth,
              let depth = DebugPreview.heatMap(depthData)
        else { return nil }
        self.depth = depth
        self.points = points
    }


    /// Red is near, blue is at the edge of the alert range. Pixels the detector ignores (low confidence) are left clear.
    private static func heatMap(_ depthData: ARDepthData) -> CGImage? {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // Upright output: buffer x becomes the row (top to bottom), buffer y becomes the column (right to left).
        let outWidth = height
        let outHeight = width
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<height {
            let depthRow = (depthBase + y * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase.map { ($0 + y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self) }
            for x in 0..<width {
                if let confidenceRow, confidenceRow[x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let depth = depthRow[x]
                guard depth.isFinite, depth > 0 else { continue }

                let color = heatColor(depth)
                let alpha: Float = depth < AlertPolicy.silentBeyond ? 0.6 : 0.25
                let index = (x * outWidth + (height - 1 - y)) * 4
                // Premultiplied alpha.
                pixels[index] = UInt8(color.x * alpha * 255)
                pixels[index + 1] = UInt8(color.y * alpha * 255)
                pixels[index + 2] = UInt8(color.z * alpha * 255)
                pixels[index + 3] = UInt8(alpha * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Red at the "near" distance, through yellow and green, to blue at the silent range.
    private static func heatColor(_ depth: Float) -> SIMD3<Float> {
        let stops: [SIMD3<Float>] = [[1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0.4, 1]]
        let range = AlertPolicy.silentBeyond - AlertPolicy.nearDistance
        let t = min(max((depth - AlertPolicy.nearDistance) / range, 0), 1) * Float(stops.count - 1)
        let index = min(Int(t), stops.count - 2)
        let fraction = t - Float(index)
        return stops[index] + (stops[index + 1] - stops[index]) * fraction
    }
}
