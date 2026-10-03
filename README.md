# Firefly

An iPhone app worn on your chest that uses LiDAR, Gemini, and ElevenLabs to guide blind users. It buzzes and speaks when something is in the way, and leads you to where you want to go.

> Firefly doesn't need AI to keep you from walking into a wall. The phone handles immediate danger locally. Gemini helps Firefly understand the world around you.

## What it does

1. **Obstacle warnings (offline)** — ARKit LiDAR splits the view into left / center / right. Closer obstacles make haptics pulse faster, with a beep in the matching ear.
2. **Firefly voice** — short ElevenLabs phrases (bundled clips when available, live TTS otherwise).
3. **"Take me to the door"** — Gemini finds a door in the camera frame, LiDAR anchors it in world space, then a panned chime guides you locally.
4. **"What's in front of me?"** — tap, speak, Gemini answers from the current frame.
5. **Demo mode** — canned door / question responses if venue Wi‑Fi dies.

**Gemini sees. ElevenLabs speaks. Azure listens (optional). The safety loop runs offline.**

## Requirements

- iPhone **Pro** with LiDAR (12 Pro or later)
- Mac with Xcode 15+
- Stereo earbuds (direction is audio, not haptics)

## Quick start (Mac)

```bash
git clone <repo-url>
cd FireFly
chmod +x scripts/mac-bootstrap.sh
./scripts/mac-bootstrap.sh
```

1. Put API keys in `Firefly/Secrets.swift` (copied from the example by the script).
2. In Xcode: **Signing & Capabilities → Team**.
3. Run on the physical Pro iPhone (simulator has no LiDAR).
4. Confirm left/right with a chair before anything else.

Obstacle warnings work with every key left empty. See [SETUP.md](SETUP.md) for details, phrase generation, and the optional Azure Function.

## Architecture

| Layer | Internet? |
|---|---|
| LiDAR depth zones → Core Haptics + stereo beeps | No |
| Cached ElevenLabs phrases | No |
| Door beacon chime (after Gemini places the anchor) | No |
| Gemini scene / door / Q&A | Yes |
| Azure Speech (falls back to Apple Speech) | Yes |
| Azure Function key proxy | Yes (optional) |

## Demo script (2 min)

1. Hook: phones should help people navigate, not just describe.
2. Static proof: chair ahead → distances drop, pulses speed up; move left/right → matching ear.
3. Wi‑Fi off: walk the course on LiDAR alone.
4. Wi‑Fi on: "Take me to the door" → follow the chime; obstacle interrupts, then resumes.
5. Optional: "What's in front of me?"
6. Close: adds another sense to a phone people already carry — not a cane/dog replacement.

## Tracks

First Place · Best Use of ElevenLabs · Best Use of Gemini API · Best Enchanted Grove Vibes · Best Use of Azure by Avanade (optional)

## Team

GirlHacks 2026 · 3 people · NJIT Campus Center
