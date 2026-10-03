# Firefly: Mac Setup

The repo already includes `Firefly.xcodeproj`. You do **not** need to create a new Xcode project.

## What you need

- A Mac with Xcode 15+
- An iPhone **Pro** (12 Pro or later) with LiDAR
- Cable, Apple ID, stereo earbuds

## 1. Bootstrap

```bash
git clone <repo-url>
cd FireFly
chmod +x scripts/mac-bootstrap.sh
./scripts/mac-bootstrap.sh
```

That creates `Firefly/Secrets.swift` if missing and opens the project.

## 2. Fill in keys

Open `Firefly/Secrets.swift`. Get keys from the team privately.

| Value | Needed for | If left empty |
|---|---|---|
| `geminiKey` | Door finding, voice questions, scene descriptions | Those features say "I can't reach the network" |
| `elevenLabsKey`, `elevenLabsVoiceID` | Firefly voice for live answers | Falls back to the iPhone's built-in voice |
| `azureSpeechKey`, `azureSpeechRegion` | Azure speech-to-text | Falls back to Apple speech recognition |
| `backendURL`, `backendKey` | Azure Function key proxy | App calls Gemini and ElevenLabs directly |

Obstacle warnings need **no keys**. Build with empties first if you want.

### Keeping keys out of GitHub

- Never paste a key into `Secrets.swift.example`
- Never `git add -f` Secrets.swift
- Before every push: `git check-ignore Firefly/Secrets.swift` should print the path
- If a key is committed, revoke it immediately

## 3. Sign and run

1. Xcode → Firefly target → **Signing & Capabilities** → your Team
2. Plug in the Pro iPhone, select it, hit Run
3. Trust the developer on the phone if asked
4. Allow Camera, Microphone, Speech

You should see LEFT / CENTER / RIGHT distances and a glowing dot.

## 4. First two checks (do these before anything else)

1. **Left and right.** Phone upright, camera forward, chair on your left → LEFT column smallest + left-ear beep. If swapped, change the marked line in `Firefly/DepthZoneAnalyzer.swift`.
2. **Floor vs low obstacles.** Middle band only. Tune `bandBottom` on the real course.

## 5. Using the app

- **Obstacles:** pulses speed up closer; beep in matching ear. Silent beyond 3 m. Works offline.
- **Ask:** tap anywhere, speak, tap again or wait for silence.
  - "Take me to the door" → chime beacon. "Stop" / "Cancel" ends it.
  - Anything else → question about the camera view.
- **Demo mode:** toggle at the bottom → Door / Question / Cancel with canned results.

## 6. Optional: Firefly voice clips

```bash
ELEVENLABS_API_KEY=... ELEVENLABS_VOICE_ID=... python3 scripts/generate_phrases.py
```

Writes MP3s to `Firefly/Phrases/` (already in the Xcode target). Fine to commit.

## 7. Optional: Azure Function

Only after the core demo works.

```bash
cd azure-function
npm install
func azure functionapp publish <your-function-app-name>
```

Set `GEMINI_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID` in the Function App env. Then set `backendURL` (ending in `/api`) and `backendKey` in `Secrets.swift`.
