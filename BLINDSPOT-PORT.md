# BlindSpot → FireFly port notes

Partner project: https://github.com/benz16107/BlindSpot

We are **not** running BlindSpot’s Flutter + LiveKit + laptop Python agent.
We **ported** the useful logic into native on-device FireFly.

## Taken from BlindSpot

| BlindSpot source | FireFly destination | What |
|---|---|---|
| `navigation.py` | `BlindSpotNav.swift` + `MapNavigator.swift` | Compass rewrite (head left/right + cardinal), 18s route-start grace, 45 m warn / 12 m “Now”, arrival wording |
| `google_maps.py` search flow | `FireflyEngine` + `MapNavigator` | List up to 3 places → pick by number/name; “nearest X” auto-picks; destination → distance → time → arrival → first step |
| `agent_config.py` | `Secrets.swift.example`, callouts | Default ElevenLabs Sarah voice ID; “Obstacle ahead: …” phrasing |
| `obstacle.py` class list | `GeminiClient.nearestHazard` | Richer obstacle name vocabulary (still LiDAR+Gemini on device, not YOLO laptop) |
| `agent.py` tools | Command handlers | “Where am I?”, facing/compass, nearest vs choose-place |

## Intentionally not ported

- LiveKit cloud room
- Python `agent.py` worker / `run_agent.sh`
- OpenCV HOG / YOLOv8 ONNX on a laptop
- Flutter UI
- Google Maps Directions API (we use **MapKit** instead)

## Result

Same partner UX ideas, FireFly constraints kept: **iOS native, LiDAR offline safety, no laptop always open.**
