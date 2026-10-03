import ARKit
import Vision

/// Names the obstacle LiDAR found, on the device: no network, no quota. Apple's built-in image classifier
/// looks at a crop around the obstacle's nearest point, and the human detector catches people.
/// Returns nil when nothing it recognises is there, and the caller says "Obstacle".
enum ObstacleNamer {
    /// Fraction of the upright image, in each direction, looked at around the obstacle.
    static let cropSize: CGFloat = 0.35
    /// The classifier scores each label independently; below this it is guessing.
    static let minimumConfidence: Float = 0.25

    /// Vision identifier -> what Firefly says. Names must match OBJECTS in scripts/generate_phrases.py.
    static let spokenNames: [String: String] = [
        "chair": "Chair", "armchair": "Chair", "folding_chair": "Chair",
        "table": "Table",
        "desk": "Desk",
        "sofa": "Couch",
        "door": "Door",
        "stairs": "Stairs",
        "people": "Person", "adult": "Person",
        "backpack": "Backpack",
        "bag": "Bag",
        "trash_can": "Trash can",
        "bench": "Bench",
        "bicycle": "Bicycle",
        "car": "Car",
        "dog": "Dog",
        "sign": "Sign", "street_sign": "Sign",
        "cabinet": "Cabinet",
        "bookshelf": "Shelf",
        "cardboard_box": "Box",
    ]

    /// `point` is where LiDAR measured the obstacle, as fractions of the upright image (x from the left, y from the top).
    nonisolated static func name(in frame: ARFrame, at point: SIMD2<Float>) -> String? {
        // Vision works in the upright image with a bottom-left origin.
        let centre = CGPoint(x: CGFloat(point.x), y: 1 - CGFloat(point.y))
        let crop = CGRect(x: centre.x - cropSize / 2, y: centre.y - cropSize / 2, width: cropSize, height: cropSize)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }

        let classify = VNClassifyImageRequest()
        classify.regionOfInterest = crop
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false

        // .right turns the landscape sensor image upright for a phone held in portrait.
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right)
        do {
            try handler.perform([classify, humans])
        } catch {
            return nil
        }

        if let people = humans.results, people.contains(where: { $0.confidence > 0.5 && $0.boundingBox.intersects(crop) }) {
            return "Person"
        }
        for observation in classify.results ?? [] where observation.confidence >= minimumConfidence {
            if let name = spokenNames[observation.identifier] { return name }
        }
        return nil
    }
}
