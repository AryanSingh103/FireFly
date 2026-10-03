import ARKit
import CoreImage

/// What the obstacle detector sees, for checking it on the device: the camera image, the LiDAR depth
/// as a heat map, and where each zone's distance was measured. Both images are upright for a phone in portrait.
struct DebugPreview {
    let camera: CGImage
    let depth: CGImage
    let points: [SIMD2<Float>?]

    private static let context = CIContext()

    init?(frame: ARFrame, points: [SIMD2<Float>?]) {
        guard let depthData = frame.sceneDepth,
              let camera = DebugPreview.uprightCamera(frame.capturedImage),
              let depth = DebugPreview.heatMap(depthData)
        else { return nil }
        self.camera = camera
        self.depth = depth
        self.points = points
    }

    private static func uprightCamera(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        // .right turns the landscape sensor image upright for a phone held in portrait.
        let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let scale = 480 / max(upright.extent.width, upright.extent.height)
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
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
