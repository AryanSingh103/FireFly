import SwiftUI

struct ContentView: View {
    @StateObject private var engine = FireflyEngine()

    private let glow = Color(red: 0.85, green: 1.0, blue: 0.4)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()

                Circle()
                    .fill(glow)
                    .frame(width: 44, height: 44)
                    .shadow(color: glow, radius: 24)
                    .scaleEffect(engine.pulseCount % 2 == 0 ? 1.0 : 1.3)
                    .opacity(engine.alert == nil && engine.mode == .idle ? 0.5 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: engine.pulseCount)

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
