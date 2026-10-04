import ARKit
import CoreImage
import ImageIO

/// A camera frame as a small JPEG, for asking Gemini about what's in front of the wearer.
struct FrameSnapshot {
    /// Creating a CIContext is expensive, so one is shared across snapshots.
    private static let context = CIContext()

    let jpeg: Data

    init?(frame: ARFrame) {
        // .right turns the landscape sensor image upright for a phone held in portrait.
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let scale = 768 / max(upright.extent.width, upright.extent.height)
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = FrameSnapshot.context.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]
        ) else { return nil }
        self.jpeg = jpeg
    }
}
