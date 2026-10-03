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
            CameraStage(preview: engine.preview, obstacleNear: engine.obstacleNear)
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
                FireflyOrb(mood: engine.mood, pulseCount: engine.pulseCount, isSpeaking: engine.isSpeaking, glow: glow)
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
        case .onboarding: return "Setup"
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

struct CameraStage: View {
    let preview: DebugPreview?
    let obstacleNear: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let preview {
                    Image(decorative: preview.camera, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    // Red wash for nearby depth — no grid lines.
                    Image(decorative: preview.depth, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(obstacleNear ? 0.55 : 0.25)
                        .blendMode(.screen)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Orb

struct FireflyOrb: View {
    let mood: FireflyEngine.Mood
    let pulseCount: Int
    let isSpeaking: Bool
    let glow: Color

    private var visible: Bool {
        switch mood {
        case .idle: return false
        case .listening, .thinking, .guiding, .danger, .happy: return true
        }
    }

    private var scale: CGFloat {
        if mood == .danger { return pulseCount % 2 == 0 ? 1.15 : 1.45 }
        if isSpeaking { return 1.35 }
        return pulseCount % 2 == 0 ? 1.0 : 1.12
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(glow.opacity(mood == .danger ? 1 : 0.95))
                .frame(width: 28, height: 28)
                .shadow(color: glow, radius: mood == .danger ? 28 : 18)
                .scaleEffect(scale)
            // Tiny wing hints
            Capsule()
                .fill(glow.opacity(0.45))
                .frame(width: 18, height: 6)
                .offset(x: -16, y: -2)
                .rotationEffect(.degrees(-20))
            Capsule()
                .fill(glow.opacity(0.45))
                .frame(width: 18, height: 6)
                .offset(x: 16, y: -2)
                .rotationEffect(.degrees(20))
        }
        .opacity(visible ? 1 : 0.15)
        .animation(.easeOut(duration: 0.15), value: pulseCount)
        .animation(.easeInOut(duration: 0.25), value: isSpeaking)
        .animation(.easeInOut(duration: 0.3), value: mood)
        .accessibilityHidden(true)
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
