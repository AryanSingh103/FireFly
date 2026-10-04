import ARKit
import MapKit
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var engine = FireflyEngine()
    @Environment(\.scenePhase) private var scenePhase

    private let glow = Color(red: 0.85, green: 1.0, blue: 0.4)

    var body: some View {
        ZStack {
            // Full-bleed camera + red near-depth wash (no grids).
            CameraStage(session: engine.session, preview: engine.preview, obstacleNear: engine.obstacleNear)
                .ignoresSafeArea()

            // Corner minimap pie
            VStack {
                HStack {
                    Spacer()
                    MinimapPie(maps: engine.maps, glow: glow)
                        .frame(width: 120, height: 120)
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
                Spacer()
            }

            // Firefly orb + captions
            VStack {
                Spacer()
                FireflyOrb(mood: engine.mood, isSpeaking: engine.isSpeaking, glow: glow)
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
        if engine.quietMode { return "Quiet · haptics only · \(modeLabel)" }
        return modeLabel
    }

    private var modeLabel: String {
        switch engine.phase {
        case .awaitingNavConfirm: return "Confirm destination"
        case .handling: return "Thinking"
        case .ready:
            if engine.guideMode == .navigate {
                return engine.beaconName.map { "Guiding to \($0)" }
                    ?? engine.maps.destinationName.map { "Navigating to \($0)" }
                    ?? "Navigate"
            }
            return "Passive · say “Firefly …”"
        }
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

/// The Firefly creature: a glowing body with flapping wings, a breathing halo and drifting sparkles.
/// Mood changes its colour, speed and how much it moves. Drawn with Canvas at up to 30 fps.
struct FireflyOrb: View {
    let mood: FireflyEngine.Mood
    let isSpeaking: Bool
    let glow: Color

    private var tint: Color {
        switch mood {
        case .danger: return Color(red: 1.0, green: 0.42, blue: 0.25)
        case .happy: return Color(red: 1.0, green: 0.9, blue: 0.45)
        default: return glow
        }
    }

    /// How lively it is: wing speed, bob and sparkle count all scale with this.
    private var energy: Double {
        switch mood {
        case .idle: return 0.35
        case .guiding: return 0.6
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
        .frame(width: 140, height: 120)
        .opacity(visible ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.4), value: visible)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let color = tint
        // Hover: a slow figure-eight, bigger when lively.
        let drift = 6 + 8 * energy
        let center = CGPoint(
            x: size.width / 2 + CGFloat(sin(t * 0.9) * drift),
            y: size.height / 2 + CGFloat(sin(t * 1.8) * drift * 0.5)
        )

        // Breathing glow; speaking makes it flicker like a voice.
        let breath = 0.5 + 0.5 * sin(t * (mood == .danger ? 9 : 2.2))
        let voice = isSpeaking ? 0.5 + 0.5 * sin(t * 17) * sin(t * 5.3) : 0
        let haloRadius = CGFloat(26 + 10 * breath + 12 * voice) * (mood == .danger ? 1.25 : 1)

        // Sparkles orbiting and fading.
        let sparkleCount = Int(3 + 6 * energy)
        for i in 0..<sparkleCount {
            let phase = Double(i) / Double(sparkleCount) * 2 * .pi
            let speed = 0.6 + 0.25 * Double(i % 3)
            let angle = phase + t * speed
            let radius = 30 + 14 * sin(t * 0.7 + phase * 2)
            let point = CGPoint(x: center.x + CGFloat(cos(angle) * radius),
                                y: center.y + CGFloat(sin(angle) * radius * 0.6))
            let twinkle = 0.5 + 0.5 * sin(t * 4 + phase * 3)
            let r = CGFloat(1.2 + 1.6 * twinkle)
            context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(color.opacity(0.35 + 0.5 * twinkle)))
        }

        // Halo.
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: 2 * haloRadius, height: 2 * haloRadius)),
            with: .radialGradient(
                Gradient(colors: [color.opacity(0.55), color.opacity(0.15), .clear]),
                center: center, startRadius: 0, endRadius: haloRadius
            )
        )

        // Wings: translucent ellipses that flap by squashing.
        let flapSpeed = 8 + 18 * energy
        let flap = CGFloat(0.35 + 0.65 * abs(sin(t * flapSpeed)))
        for side in [-1.0, 1.0] {
            var wing = context
            wing.translateBy(x: center.x + CGFloat(side * 7), y: center.y - 6)
            wing.rotate(by: .degrees(side * 28))
            wing.scaleBy(x: flap, y: 1)
            let rect = CGRect(x: side > 0 ? 0 : -22, y: -8, width: 22, height: 13)
            wing.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.28)))
            wing.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.5)), lineWidth: 0.8)
        }

        // Body: a small dark head and a glowing abdomen, like a real firefly.
        let abdomen = CGRect(x: center.x - 7, y: center.y - 2, width: 14, height: 18)
        context.fill(Path(ellipseIn: abdomen.insetBy(dx: -4, dy: -4)), with: .color(color.opacity(0.35 + 0.3 * breath)))
        context.fill(Path(ellipseIn: abdomen), with: .color(color))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 11, width: 10, height: 10)),
                     with: .color(Color(white: 0.15)))
        // Antennae.
        var antennae = Path()
        let wiggle = CGFloat(sin(t * 3) * 2)
        antennae.move(to: CGPoint(x: center.x - 2, y: center.y - 10))
        antennae.addQuadCurve(to: CGPoint(x: center.x - 8 + wiggle, y: center.y - 20),
                              control: CGPoint(x: center.x - 3, y: center.y - 18))
        antennae.move(to: CGPoint(x: center.x + 2, y: center.y - 10))
        antennae.addQuadCurve(to: CGPoint(x: center.x + 8 - wiggle, y: center.y - 20),
                              control: CGPoint(x: center.x + 3, y: center.y - 18))
        context.stroke(antennae, with: .color(Color(white: 0.35)), lineWidth: 1.2)
    }
}

// MARK: - Minimap

struct MinimapPie: View {
    @ObservedObject var maps: MapNavigator
    let glow: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay(Circle().stroke(glow.opacity(0.7), lineWidth: 2))
            MinimapRepresentable(maps: maps)
                .clipShape(Circle())
                .padding(4)
        }
        .accessibilityLabel("Minimap")
    }
}

struct MinimapRepresentable: UIViewRepresentable {
    @ObservedObject var maps: MapNavigator

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.isUserInteractionEnabled = false
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.overrideUserInterfaceStyle = .dark
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // SwiftUI calls this on every parent redraw; re-centring the map each time is expensive.
        let coordinate = maps.userCoordinate
        let state = "\(maps.route.map { ObjectIdentifier($0).hashValue } ?? 0)|\(coordinate?.latitude ?? 0)|\(coordinate?.longitude ?? 0)"
        guard state != context.coordinator.lastState else { return }
        context.coordinator.lastState = state
        map.removeOverlays(map.overlays)
        if let route = maps.route {
            map.addOverlay(route.polyline)
            let rect = route.polyline.boundingMapRect
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), animated: false)
        } else if let coordinate = maps.userCoordinate {
            let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 180, longitudinalMeters: 180)
            map.setRegion(region, animated: false)
        }
        map.delegate = context.coordinator
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastState = ""
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.85, green: 1, blue: 0.4, alpha: 0.95)
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
