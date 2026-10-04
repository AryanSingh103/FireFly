import ARKit
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var engine = FireflyEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Full-bleed camera + red near-depth wash (no grids).
            CameraStage(session: engine.session, preview: engine.preview, obstacleNear: engine.obstacleNear)
                .ignoresSafeArea()

            // Firefly orb + captions
            VStack {
                Spacer()
                FireflyOrb(mood: engine.mood, isSpeaking: engine.isSpeaking, target: engine.obstacleTarget)
                    .padding(.bottom, 8)

                Text(engine.caption)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4, y: 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 56)

                Text(statusLine)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.bottom, 28)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            engine.start()
        }
        .onChange(of: scenePhase) { phase in
            engine.setForeground(phase == .active)
        }
    }

    private var statusLine: String {
        let mode = engine.isHandling ? "Thinking" : "Watching · say “Firefly …”"
        let line = engine.quietMode ? "Quiet · haptics only · \(mode)" : mode
        return engine.frameRates.isEmpty ? line : "\(line)\n\(engine.frameRates)"
    }
}

// MARK: - Camera

/// Live camera straight from the ARKit session (rendered on the GPU at full frame rate), with the
/// LiDAR heat map on top. The heat map updates a few times a second; the camera never waits for it.
struct CameraStage: View {
    let session: ARSession
    let preview: DebugPreview?
    let obstacleNear: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                LiveCameraView(session: session)
                if let preview {
                    // Red wash for nearby depth — no grid lines.
                    Image(decorative: preview.depth, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(obstacleNear ? 0.55 : 0.25)
                        .blendMode(.screen)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct LiveCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        // Shares the engine's session; the engine stays the session's delegate.
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}

// MARK: - Firefly

/// The Firefly creature: a little fire phoenix with a glowing body, big eyes, firefly antennae, flapping
/// flame-feather wings, a streaming flame tail and rising embers. Mood changes its colours and how lively
/// it is. It flies toward the side of the nearest obstacle (faster when it's closer) and leaves a fading
/// trail. Drawn with Canvas at up to 30 fps.
struct FireflyOrb: View {
    let mood: FireflyEngine.Mood
    let isSpeaking: Bool
    let target: FireflyEngine.ObstacleTarget?

    /// Where it is and where it's been. A class so the Canvas can update it each frame without re-rendering.
    private final class Flight {
        /// Horizontal position: -1 is the left end of its range, 0 home, 1 the right end.
        var x = 0.0
        /// Sideways speed in points per second, smoothed. Leans the tail away from the direction of travel.
        var velocity = 0.0
        var lastTime: Double?
        var trail: [(point: CGPoint, time: Double)] = []
    }

    /// Fire colours from the hot centre outward.
    private struct Palette {
        let core: Color
        let gold: Color
        let flame: Color
        let deep: Color
    }

    @State private var flight = Flight()
    private let trailLifetime = 0.6

    private var palette: Palette {
        switch mood {
        case .danger:
            return Palette(core: Color(red: 1.0, green: 0.85, blue: 0.7), gold: Color(red: 1.0, green: 0.5, blue: 0.25),
                           flame: Color(red: 1.0, green: 0.3, blue: 0.12), deep: Color(red: 0.85, green: 0.1, blue: 0.05))
        case .happy:
            return Palette(core: Color(red: 1.0, green: 1.0, blue: 0.9), gold: Color(red: 1.0, green: 0.9, blue: 0.45),
                           flame: Color(red: 1.0, green: 0.7, blue: 0.25), deep: Color(red: 1.0, green: 0.45, blue: 0.15))
        default:
            return Palette(core: Color(red: 1.0, green: 0.97, blue: 0.85), gold: Color(red: 1.0, green: 0.8, blue: 0.3),
                           flame: Color(red: 1.0, green: 0.55, blue: 0.18), deep: Color(red: 0.95, green: 0.32, blue: 0.12))
        }
    }

    /// How lively it is: wing speed, bob and ember count all scale with this.
    private var energy: Double {
        switch mood {
        case .idle: return 0.35
        case .listening: return 0.8
        case .thinking: return 0.7
        case .happy: return 1.0
        case .danger: return 1.3
        }
    }

    private var visible: Bool { mood != .idle || isSpeaking }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, time: t)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .opacity(visible ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.4), value: visible)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let colors = palette

        // Fly toward the obstacle's side, quicker the closer it is; drift home when the way is clear.
        let dt = min(t - (flight.lastTime ?? t), 0.1)
        flight.lastTime = t
        let goal = target.map { $0.zone == .left ? -1.0 : $0.zone == .right ? 1.0 : 0.0 } ?? 0
        let rate = target.map { [1.5, 3.0, 6.0][min($0.closeness, 2)] } ?? 1.2
        let range = Double(max(size.width / 2 - 80, 0))
        let step = (goal - flight.x) * (1 - exp(-rate * dt))
        flight.x += step
        if dt > 0 { flight.velocity += (step * range / dt - flight.velocity) * 0.2 }

        // Hover: a slow figure-eight, bigger when lively.
        let drift = 5 + 6 * energy
        let c = CGPoint(
            x: size.width / 2 + CGFloat(flight.x * range + sin(t * 0.9) * drift),
            y: size.height / 2 - 6 + CGFloat(sin(t * 1.8) * drift * 0.5)
        )

        // Trail: recent positions as small embers that shrink and fade.
        flight.trail.append((c, t))
        flight.trail.removeAll { t - $0.time > trailLifetime }
        for (point, time) in flight.trail.dropLast() {
            let life = 1 - (t - time) / trailLifetime
            let r = CGFloat(1 + 3 * life)
            context.fill(dot(at: CGPoint(x: point.x, y: point.y + 10), radius: r),
                         with: .color(colors.flame.opacity(0.55 * life)))
        }

        // Breathing glow; speaking makes it flicker like a voice.
        let breath = 0.5 + 0.5 * sin(t * (mood == .danger ? 9 : 2.2))
        let voice = isSpeaking ? 0.5 + 0.5 * sin(t * 17) * sin(t * 5.3) : 0
        let haloRadius = CGFloat(40 + 10 * breath + 14 * voice) * (mood == .danger ? 1.2 : 1)
        context.fill(
            dot(at: c, radius: haloRadius),
            with: .radialGradient(
                Gradient(colors: [colors.gold.opacity(0.5), colors.flame.opacity(0.18), .clear]),
                center: c, startRadius: 0, endRadius: haloRadius
            )
        )

        drawTail(in: &context, at: c, time: t, colors: colors)
        drawEmbers(in: &context, at: c, time: t, colors: colors)
        drawWings(in: &context, at: c, time: t, colors: colors)
        drawBody(in: &context, at: c, time: t, breath: breath, colors: colors)
    }

    /// Three flame plumes that stream down from the body, sway, and lean away from the direction of travel.
    /// Each is a run of dots that shrink and fade toward the tip, so it reads as fire rather than lines.
    private func drawTail(in context: inout GraphicsContext, at c: CGPoint, time t: Double, colors: Palette) {
        let lean = CGFloat(min(max(flight.velocity * 0.12, -28), 28))
        let root = CGPoint(x: c.x, y: c.y + 16)
        for i in [-1.0, 1.0, 0.0] {
            let side = CGFloat(i)
            let sway = CGFloat(sin(t * 3 + i * 1.3) * 6)
            let length: CGFloat = i == 0 ? 50 : 40
            let end = CGPoint(x: root.x + side * 22 - lean + sway, y: root.y + length)
            let control = CGPoint(x: root.x - side * 4 - lean * 0.3 - sway, y: root.y + length * 0.55)
            let samples = 16
            for k in stride(from: samples, through: 0, by: -1) {
                let u = CGFloat(k) / CGFloat(samples)
                let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, d = u * u
                let point = CGPoint(x: a * root.x + b * control.x + d * end.x,
                                    y: a * root.y + b * control.y + d * end.y)
                let r = 6 * (1 - u) + 0.8
                let flicker = 0.85 + 0.15 * sin(t * 12 + Double(k) + i)
                context.fill(dot(at: point, radius: r * 1.7),
                             with: .color(colors.flame.opacity(0.18 * Double(1 - u) * flicker)))
                context.fill(dot(at: point, radius: r),
                             with: .color((u < 0.35 ? colors.gold : colors.flame).opacity(Double(1 - u * 0.85) * flicker)))
            }
        }
    }

    /// Sparks that rise from the body and fade out.
    private func drawEmbers(in context: inout GraphicsContext, at c: CGPoint, time t: Double, colors: Palette) {
        let count = min(Int(5 + 7 * energy), 14)
        for i in 0..<count {
            let seed = Double(i) * 2.399
            let age = (t * (0.45 + 0.15 * Double(i % 3)) + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let point = CGPoint(x: c.x + CGFloat(sin(seed * 3) * 34 + sin(t * 2 + seed) * 4),
                                y: c.y + 20 - CGFloat(age * 75))
            let r = CGFloat(0.8 + 1.8 * (1 - age))
            context.fill(dot(at: point, radius: r), with: .color(colors.gold.opacity(0.85 * (1 - age))))
        }
    }

    /// Two wings of flame-feathers that fan up and out and flap.
    private func drawWings(in context: inout GraphicsContext, at c: CGPoint, time t: Double, colors: Palette) {
        let flapSpeed = 5 + 7 * energy
        let flap = sin(t * flapSpeed)
        // (angle out from straight up, length, width) for each feather, inner to outer.
        let feathers: [(Double, CGFloat, CGFloat)] = [(8, 34, 8), (22, 44, 10), (36, 48, 11), (50, 42, 10), (64, 32, 9), (78, 22, 7)]
        for side in [-1.0, 1.0] {
            var wing = context
            wing.translateBy(x: c.x + CGFloat(side * 9), y: c.y + 2)
            wing.scaleBy(x: CGFloat(side), y: 1)
            wing.rotate(by: .degrees(20 + flap * 18))
            for (angle, length, width) in feathers {
                var feather = wing
                feather.rotate(by: .degrees(angle))
                var path = Path()
                path.move(to: .zero)
                path.addQuadCurve(to: CGPoint(x: width * 0.5, y: -length), control: CGPoint(x: width, y: -length * 0.45))
                // Curl at the tip.
                path.addQuadCurve(to: CGPoint(x: width * 0.1, y: -length * 0.8), control: CGPoint(x: width * 0.9, y: -length * 1.05))
                path.addQuadCurve(to: .zero, control: CGPoint(x: -width * 0.5, y: -length * 0.5))
                feather.fill(path, with: .linearGradient(
                    Gradient(colors: [colors.gold, colors.flame.opacity(0.9), colors.deep.opacity(0.7)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: -length)
                ))
                feather.stroke(path, with: .color(colors.core.opacity(0.5)), lineWidth: 0.7)
            }
        }
    }

    /// The chick: round glowing body and head, big eyes, a tiny beak and curly firefly antennae.
    private func drawBody(in context: inout GraphicsContext, at c: CGPoint, time t: Double, breath: Double, colors: Palette) {
        let fire = Gradient(colors: [colors.core, colors.gold, colors.flame])
        let bodyRect = CGRect(x: c.x - 10, y: c.y - 2, width: 20, height: 22)
        context.fill(Path(ellipseIn: bodyRect.insetBy(dx: -4, dy: -4)),
                     with: .color(colors.gold.opacity(0.25 + 0.25 * breath)))
        context.fill(Path(ellipseIn: bodyRect), with: .radialGradient(
            fire, center: CGPoint(x: c.x, y: c.y + 6), startRadius: 0, endRadius: 14))

        let head = CGPoint(x: c.x, y: c.y - 8)
        context.fill(dot(at: head, radius: 12), with: .radialGradient(
            fire, center: CGPoint(x: head.x - 2, y: head.y - 3), startRadius: 0, endRadius: 15))

        // Antennae with glowing tips.
        let wiggle = CGFloat(sin(t * 3) * 2)
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            let tip = CGPoint(x: head.x + s * (11 + wiggle), y: head.y - 22)
            var antenna = Path()
            antenna.move(to: CGPoint(x: head.x + s * 3, y: head.y - 10))
            antenna.addQuadCurve(to: tip, control: CGPoint(x: head.x + s * 2, y: head.y - 24))
            context.stroke(antenna, with: .color(colors.gold), lineWidth: 1.3)
            context.fill(dot(at: tip, radius: 2.4), with: .color(colors.core))
        }

        // Eyes, with an occasional blink.
        let blink = (t.truncatingRemainder(dividingBy: 4.0) < 0.12) ? 0.15 : 1.0
        for side in [-1.0, 1.0] {
            let eye = CGPoint(x: head.x + CGFloat(side * 4.5), y: head.y - 1)
            context.fill(Path(ellipseIn: CGRect(x: eye.x - 2.8, y: eye.y - 3.4 * blink, width: 5.6, height: 6.8 * blink)),
                         with: .color(Color(red: 0.2, green: 0.08, blue: 0.02)))
            if blink == 1 {
                context.fill(dot(at: CGPoint(x: eye.x + 1, y: eye.y - 1.4), radius: 1.1), with: .color(.white))
            }
        }

        // Beak.
        var beak = Path()
        beak.move(to: CGPoint(x: head.x - 2, y: head.y + 3))
        beak.addLine(to: CGPoint(x: head.x + 2, y: head.y + 3))
        beak.addLine(to: CGPoint(x: head.x, y: head.y + 6))
        beak.closeSubpath()
        context.fill(beak, with: .color(colors.deep))
    }

    private func dot(at point: CGPoint, radius r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
    }
}
