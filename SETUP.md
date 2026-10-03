# Firefly: Mac Setup

Repo includes `Firefly.xcodeproj`. Open it — do not create a new project.

## Quick start

```bash
cd FireFly
chmod +x scripts/mac-bootstrap.sh
./scripts/mac-bootstrap.sh
```

1. Fill `Firefly/Secrets.swift` (Gemini + ElevenLabs at minimum).
2. Xcode → Signing → Team.
3. Run on a **LiDAR iPhone Pro** (not simulator).
4. Allow Camera, Mic, Speech, Location.
5. First launch is **voice onboarding** (name, verbosity, units, pace, quiet).
6. After that: say **“Firefly, …”** for commands (e.g. “Firefly, take me to the exit”).

## What you should see / hear

- Full camera view with red near-depth wash, corner minimap, captions, glowing firefly when speaking.
- Passive obstacle callouts + haptics (or haptics-only in Quiet).
- “Firefly, take me to the exit/door” → vision + LiDAR beacon guidance.
- “Firefly, take me to …” → MapKit search → confirm → walking nav on minimap.

## Optional phrase bank

```bash
ELEVENLABS_API_KEY=... ELEVENLABS_VOICE_ID=... python3 scripts/generate_phrases.py
```

## Design

See `firefly-design.md` for the locked product design.
