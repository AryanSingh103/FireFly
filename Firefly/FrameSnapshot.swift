import ARKit
import CoreImage

/// A camera frame frozen at the moment a Gemini request is sent, so the reply can be placed in the world
/// even though the wearer has moved by the time it arrives.
struct FrameSnapshot {
    let jpeg: Data
    private let cameraTransform: simd_float4x4
    private let intrinsics: simd_float3x3
    private let imageSize: CGSize
    private let depth: [Float32]
    private let depthWidth: Int
    private let depthHeight: Int

    init?(frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else { return nil }

        // .right turns the landscape sensor image upright for a phone held in portrait.
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let scale = 768 / max(upright.extent.width, upright.extent.height)
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = CIContext().jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]
        ) else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        var values = [Float32](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                values[y * width + x] = row[x]
            }
        }

        self.jpeg = jpeg
        self.cameraTransform = frame.camera.transform
        self.intrinsics = frame.camera.intrinsics
        self.imageSize = frame.camera.imageResolution
        self.depth = values
        self.depthWidth = width
        self.depthHeight = height
    }

    /// World position of a point in the upright photo, given as fractions from the left and top.
    /// isApproximate is true when LiDAR had no reading there (usually too far) and a distance was assumed.
    func worldPoint(atPhotoPoint point: SIMD2<Float>) -> (position: SIMD3<Float>, isApproximate: Bool) {
        // Upright photo back to the landscape sensor buffer: buffer x runs top to bottom, buffer y runs right to left.
        let bufferX = point.y
        let bufferY = 1 - point.x

        let centerX = Int(bufferX * Float(depthWidth))
        let centerY = Int(bufferY * Float(depthHeight))
        var samples: [Float] = []
        for y in (centerY - 4)...(centerY + 4) where y >= 0 && y < depthHeight {
            for x in (centerX - 4)...(centerX + 4) where x >= 0 && x < depthWidth {
                let value = depth[y * depthWidth + x]
                if value.isFinite, value > 0.15, value < 5 { samples.append(value) }
            }
        }
        samples.sort()
        let distance = samples.isEmpty ? 4 : samples[samples.count / 2]

        let pixelX = bufferX * Float(imageSize.width)
        let pixelY = bufferY * Float(imageSize.height)
        // ARKit camera space: x right, y up, looking down negative z.
        let local = SIMD4<Float>(
            (pixelX - intrinsics[2][0]) / intrinsics[0][0] * distance,
            -(pixelY - intrinsics[2][1]) / intrinsics[1][1] * distance,
            -distance,
            1
        )
        let world = cameraTransform * local
        return (SIMD3(world.x, world.y, world.z), samples.isEmpty)
    }
}
