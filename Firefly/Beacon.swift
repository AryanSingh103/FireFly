import Foundation
import simd

struct Beacon {
    let name: String
    var position: SIMD3<Float>
    var isApproximate: Bool

    struct Guidance {
        let pan: Float
        let distance: Float
        let interval: TimeInterval
    }

    /// Where the target is relative to the way the camera faces, flattened onto the floor plane.
    func guidance(from camera: simd_float4x4) -> Guidance {
        let here = SIMD2<Float>(camera.columns.3.x, camera.columns.3.z)
        let forward = SIMD2<Float>(-camera.columns.2.x, -camera.columns.2.z)
        let right = SIMD2<Float>(-forward.y, forward.x)
        let offset = SIMD2<Float>(position.x, position.z) - here

        let distance = simd_length(offset)
        let bearing = atan2(simd_dot(offset, right), simd_dot(offset, forward))
        let pan = max(-1, min(1, bearing / (Float.pi / 2)))
        let closeness = 1 - min(max((distance - 1) / 4, 0), 1)
        return Guidance(pan: pan, distance: distance, interval: 1.2 - Double(closeness) * 0.95)
    }
}
