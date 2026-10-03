# Devpost — paste-ready

## Tagline
A chest-worn iPhone guide that uses LiDAR for offline obstacle warnings and Gemini + ElevenLabs to lead you to the door.

## Inspiration
Blind navigation aids often mean expensive dedicated hardware. Almost everyone already carries a LiDAR-capable phone. Firefly turns that phone into another sense — calm voice, haptic pulses, and ear-panned audio — without replacing a cane or guide dog.

## What it does
- Detects obstacles left / center / right with ARKit scene depth
- Speeds up Core Haptics as you get closer; plays a beep in the matching ear
- Speaks short Firefly phrases (ElevenLabs)
- Finds a door with Gemini, anchors it with LiDAR, then guides with a local panned chime
- Answers "what's in front of me?" from a camera frame
- Keeps the safety loop fully offline; AI is an enhancement with a demo-mode fallback

## How we built it
SwiftUI + ARKit (`.sceneDepth`) for left/center/right zones with a middle band and percentile depth so the floor does not alert. Core Haptics for closeness. AVAudioEngine for stereo direction. Gemini for scene labels, door bounding boxes, and spoken Q&A. ElevenLabs for the Firefly voice (bundled clips + live TTS). Apple Speech first, Azure Speech optional. Optional Azure Function to keep API keys off the device.

## Challenges
LiDAR depth buffers arrive in sensor orientation and can invert left/right relative to a portrait display. Floor pixels look like obstacles unless you restrict to a middle band. Venue Wi‑Fi is unreliable, so the offline loop and demo mode are non-negotiable.

## Accomplishments
A wearable demo that works with Wi‑Fi off. Direction through stereo audio, not just vibration. A door beacon that stays local after one Gemini lookup. A voice that stays short and never talks over a safety warning.

## What we learned
Safety-critical sensing must stay on-device. AI is best for naming and targeting, not for the "something is close" loop. Stereo earbuds matter more than a second motor.

## What's next
Better low-obstacle coverage, step/edge cues, stronger glass handling honesty in UX, and more robust door re-localization in crowded halls.

## Built with
ARKit, Core Haptics, AVAudioEngine, SwiftUI, Google Gemini API, ElevenLabs, Azure Speech (optional), Azure Functions (optional)

## Sponsor one-liners
- **Gemini:** sees the scene and finds the door.
- **ElevenLabs:** speaks as Firefly.
- **Azure:** listens (Speech) and can secure the keys (Functions).

## Try it
LiDAR iPhone Pro required. Clone the repo, run `./scripts/mac-bootstrap.sh`, add keys to `Firefly/Secrets.swift`, sign in Xcode, run on device.
