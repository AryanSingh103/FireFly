import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var engine = FireflyEngine()

    private let glow = Color(red: 0.85, green: 1.0, blue: 0.4)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: engine.showCamera ? 16 : 32) {
                Spacer()

                if engine.showCamera, let preview = engine.preview {
                    DebugCameraView(preview: preview, activeZone: engine.alert?.zone, glow: glow)
                        .frame(maxHeight: 300)
                } else {
                    Circle()
                        .fill(glow)
                        .frame(width: 44, height: 44)
                        .shadow(color: glow, radius: 24)
                        // Swells while Firefly speaks; otherwise flickers with each haptic pulse.
                        .scaleEffect(engine.isSpeaking ? 1.4 : engine.pulseCount % 2 == 0 ? 1.0 : 1.15)
                        .opacity(engine.isSpeaking || engine.alert != nil || engine.mode != .idle ? 1.0 : 0.5)
                        .animation(.easeOut(duration: 0.12), value: engine.pulseCount)
                        .animation(.easeInOut(duration: 0.3), value: engine.isSpeaking)
                        // With VoiceOver on, a single tap only selects, so expose asking as a button action too.
                        .accessibilityElement()
                        .accessibilityLabel("Ask Firefly")
                        .accessibilityHint("Double tap, then speak a question or say where to go.")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { engine.handleTap() }
                }

                Text(engine.caption)
                    .font(.title3.weight(.medium))
                    .foregroundColor(glow)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 60)

                HStack(spacing: 12) {
                    ForEach(Zone.allCases, id: \.self) { zone in
                        zoneColumn(zone)
                    }
                }

                Text(statusLine)
                    .font(.footnote)
                    .foregroundColor(.gray)

                Spacer()

                demoControls
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.handleTap() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            engine.start()
        }
    }

    private var statusLine: String {
        switch engine.mode {
        case .listening:
            return "Listening. Tap to finish."
        case .thinking:
            return "Thinking"
        case .idle:
            if let name = engine.beaconName { return "Guiding to the \(name)" }
            return engine.status == "Scanning" ? "Tap anywhere to ask" : engine.status
        }
    }

    private var demoControls: some View {
        VStack(spacing: 10) {
            if engine.demoMode {
                HStack(spacing: 12) {
                    Button("Door") { engine.demoDoor() }
                    Button("Question") { engine.demoQuestion() }
                    Button("Cancel") { engine.cancelBeacon() }
                }
                .buttonStyle(.bordered)
                .tint(glow)
            }
            Toggle("Camera view", isOn: $engine.showCamera)
                .font(.footnote)
                .foregroundColor(.gray)
                .tint(glow)
            Toggle("Demo mode", isOn: $engine.demoMode)
                .font(.footnote)
                .foregroundColor(.gray)
                .tint(glow)
        }
    }

    private func zoneColumn(_ zone: Zone) -> some View {
        let distance = engine.distances[zone.rawValue]
        let isActive = engine.alert?.zone == zone
        return VStack(spacing: 8) {
            Text(zone.label)
                .font(.caption.bold())
            Text(distance < AlertPolicy.silentBeyond ? String(format: "%.1f m", distance) : "clear")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .foregroundColor(isActive ? .black : .white)
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(isActive ? glow : Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Testing aid: the camera with the LiDAR heat map on top, the three scanned zones, and the point each
/// zone's distance comes from. Red is near, blue is the edge of the 3 m alert range, uncoloured is ignored.
struct DebugCameraView: View {
    let preview: DebugPreview
    let activeZone: Zone?
    let glow: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let bandTop = size.height * CGFloat(DepthZoneAnalyzer.bandTop)
            let bandHeight = size.height * CGFloat(DepthZoneAnalyzer.bandBottom - DepthZoneAnalyzer.bandTop)
            ZStack(alignment: .topLeading) {
                Image(decorative: preview.camera, scale: 1)
                    .resizable()
                Image(decorative: preview.depth, scale: 1)
                    .resizable()
                    .interpolation(.none)

                ForEach(Zone.allCases, id: \.self) { zone in
                    let isActive = zone == activeZone
                    Rectangle()
                        .strokeBorder(isActive ? glow : Color.white.opacity(0.7), lineWidth: isActive ? 3 : 1)
                        .frame(width: size.width / 3, height: bandHeight)
                        .offset(x: size.width / 3 * CGFloat(zone.rawValue), y: bandTop)
                }

                ForEach(Zone.allCases, id: \.self) { zone in
                    if let point = preview.points[zone.rawValue] {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .background(Circle().fill(zone == activeZone ? glow : Color.black.opacity(0.5)))
                            .frame(width: 14, height: 14)
                            .position(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height)
                    }
                }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }
}
