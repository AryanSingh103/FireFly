# Firefly — Mac setup

```bash
cd FireFly
chmod +x scripts/mac-bootstrap.sh
./scripts/mac-bootstrap.sh
```

1. Copy `Firefly/Secrets.swift.example` → `Firefly/Secrets.swift` (gitignored) and add Gemini + ElevenLabs keys.
2. Open `Firefly.xcodeproj` → Signing → Team.
3. Run on a **physical iPhone** (simulator has no camera / depth). LiDAR Pro preferred; other models use camera distance.
4. Allow Camera, Microphone, and Speech Recognition.
5. Say **“Firefly, …”** — e.g. “Firefly, what's in front of me?”

## Optional phrase bank

```bash
ELEVENLABS_API_KEY=... ELEVENLABS_VOICE_ID=... python3 scripts/generate_phrases.py
```

Clips land in `Firefly/Phrases/` and ship with the app for instant offline speech.
