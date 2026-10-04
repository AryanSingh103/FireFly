# Devpost — paste-ready

## Tagline
A chest-worn iPhone guide for blind and low-vision people: offline obstacle warnings on any iPhone, on-device AI, a calm ElevenLabs voice, and a map that learns the places you walk.

## Inspiration
Most mobility aids cost hundreds or thousands of dollars, but millions of people already carry an iPhone. A firefly is a tiny light that helps you find your way in the dark, so that's who our guide became. Many assistive alerts are loud and frightening, so Firefly is calm and reassuring instead.

## What it does
Firefly is a voice-first guide worn on a chest lanyard.

- **Warns, names, and advises.** "Chair on your left, about 7 feet, roughly 3 steps, move right." LiDAR finds obstacles and naming runs on the device, so it works with no internet.
- **Feel it.** A soft heartbeat tap means the path is clear. Taps speed up as something gets closer. Quiet mode is haptics only.
- **Ask about your surroundings.** "What's in front of me?" "Are there any cars on the road?" "Is this crossing sign white or red?" "Is this ___ Ave?" Answers are short, and Firefly says when it isn't sure.
- **An emergency use case, not a navigator.** If a blind person has to make their way somewhere in an emergency, such as a pharmacy a block away, Firefly doesn't route them. It gives them information they can act on: where cars are, what the signal looks like, which street they're on.
- **Works on any iPhone.** Without LiDAR, a trained vision model estimates distance from the camera.
- **AI that works offline.** An on-device Gemma model answers when there's no connection; Gemini takes over when there is.
- **Learns the places you walk.** Firefly builds a LiDAR map of familiar areas and can be used to plan navigation in the future.
- **A calm ElevenLabs voice**, with ~130 bundled clips that play instantly offline, and a glowing firefly on screen that flies toward the nearest obstacle.
- **Hands-free** with a wake word: "Firefly…"

## How we built it
SwiftUI and ARKit, built on one rule: safety never waits on the network. LiDAR depth is split into left, center and right zones over a chest-height band so the floor doesn't count. Within 2 m, Core Haptics pulses faster for closer obstacles. Apple Vision names objects on the device, Apple Speech handles voice commands on the device, ElevenLabs is the voice, and Gemini or Gemma answers questions about the camera view.

## Challenges we ran into
The depth buffer arrives in landscape, so left and right came out sideways. The floor looked like an obstacle until we limited the scan band. Firefly kept hearing its own voice as commands. Heavy work on the main thread made ARKit stop delivering frames.

## What we learned
AI is great at naming things and the wrong tool for "something is close." The depth sensor decides where an obstacle is; the model says what it is. Accessibility is mostly restraint.

## What's next
Testing with blind and low-vision users and mobility experts, especially around street crossings, and checking camera-only distance against LiDAR in more places.

Firefly is not a replacement for a white cane or a guide dog. It's a 24-hour prototype that adds another sense to a phone people already carry.

## Built with
ARKit, Core Haptics, ElevenLabs, Google Gemini, iOS, LiDAR, MapKit, Python, Swift, SwiftUI, Xcode
