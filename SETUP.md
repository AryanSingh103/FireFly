# Firefly: Mac Setup

How to get the app from this repo onto the iPhone. The Swift code was written on a Windows machine and has **never been compiled**, so expect a few compiler errors on the first build. Send them to Krish as you hit them.

## What you need

- A Mac with Xcode
- An iPhone **Pro** (12 Pro or later). The app needs LiDAR and shows "This iPhone has no LiDAR" on anything else. The simulator will not work.
- A cable, an Apple ID, and stereo earbuds for testing left/right audio

## 1. Get the code

```bash
git clone <repo-url>
cd firefly
git checkout maske
```

## 2. Create the secrets file

The API keys live in `Firefly/Secrets.swift`. That file is **gitignored and is not in the repo**, so you have to create it yourself. The app will not compile without it.

```bash
cp Firefly/Secrets.swift.example Firefly/Secrets.swift
```

Then open `Firefly/Secrets.swift` and fill in the values. Get the keys from Krish in a private message.

| Value | Needed for | If left empty |
|---|---|---|
| `geminiKey` | Door finding, voice questions, scene descriptions | Those features say "I can't reach the network" |
| `elevenLabsKey`, `elevenLabsVoiceID` | The Firefly voice for live answers | Falls back to the iPhone's built-in voice |
| `azureSpeechKey`, `azureSpeechRegion` | Azure speech-to-text | Falls back to Apple speech recognition |
| `backendURL`, `backendKey` | Routing Gemini and ElevenLabs through the Azure Function | The app calls Gemini and ElevenLabs directly |

Obstacle warnings need no keys at all. You can build with every value empty to test them first.

### Keeping the keys out of GitHub

- **Never paste a key into `Secrets.swift.example`.** That file is committed. Only `Secrets.swift` is ignored.
- Do not rename `Secrets.swift`. The ignore rule matches that exact file name, anywhere in the repo, so a renamed copy (`Secrets 2.swift`, `Keys.swift`) would be committed.
- Do not use `git add -f`, and do not paste keys into any other file, commit message, issue or public chat.
- Before every push, run `git status` and confirm `Secrets.swift` is not listed. To double-check, this should print the path back:

  ```bash
  git check-ignore Firefly/Secrets.swift
  ```

  If Xcode copied the file into the project folder, run the same check on that copy's path.

- If a key is ever committed, tell the team and **revoke it** in the provider's dashboard straight away. Deleting the file in a later commit does not remove it from the history.

## 3. Create the Xcode project

The repo has the Swift source files but no Xcode project.

1. In Xcode: File > New > Project > iOS > App.
2. Product Name `Firefly`, Interface `SwiftUI`, Language `Swift`.
3. Save it **outside** this repo's `Firefly/` folder (for example in a new `xcode/` folder in the repo) so the two do not collide.
4. Delete the `FireflyApp.swift` and `ContentView.swift` that Xcode generated.
5. Drag everything from the repo's `Firefly/` folder into the project, including the `Secrets.swift` you just made. Leave out `Secrets.swift.example`. Tick the Firefly target when asked.
6. Commit the Xcode project so the rest of the team has it. Run `git status` first and check that no secrets file is in the list.

## 4. Project settings

In the Firefly target:

- **Signing & Capabilities:** pick your Apple ID team. A free account works; the build expires after 7 days.
- **Info tab:** add these three keys, each with a short sentence explaining why. The app crashes on launch without them.
  - Privacy - Camera Usage Description
  - Privacy - Microphone Usage Description
  - Privacy - Speech Recognition Usage Description
- **General > Deployment Info:** tick only Portrait. The left/right logic assumes the phone is upright.
- **Minimum Deployments:** iOS 16 or later.

## 5. Build and run

Plug in the iPhone, select it as the run destination and press Run. The first time, the phone asks you to trust the developer under Settings > General > VPN & Device Management, then asks for camera, microphone and speech permissions.

You should see three columns (LEFT, CENTER, RIGHT) with live distances and a glowing dot.

## 6. Check these first

Do these two checks before testing anything else, because every other feature builds on them.

1. **Left and right.** Hold the phone upright with the camera facing forward and put a chair on your left. The LEFT column should show the smallest distance and the beep should be in the left earbud. If the sides are swapped, change the marked line in `Firefly/DepthZoneAnalyzer.swift` (the comment there gives the replacement).
2. **Low obstacles and the floor.** Only a middle band of the view is scanned so the floor does not trigger alerts. A backpack on the floor will probably be missed. Raising `bandBottom` in `Firefly/DepthZoneAnalyzer.swift` catches lower things but starts picking up the floor, so tune it on the real demo course.

## 7. Using the app

- **Obstacles:** haptic pulses speed up as something gets closer, with a beep in the matching ear. Silent beyond 3 m. Works with Wi-Fi off.
- **Ask something:** tap anywhere, speak, and it stops listening when you go quiet (or tap again).
  - "Take me to the door" starts the chime beacon. Saying "stop" or "cancel" ends it.
  - Anything else is treated as a question about what the camera sees.
- **Demo mode:** the toggle at the bottom shows Door, Question and Cancel buttons that use canned results and need no network. Use it if the venue Wi-Fi fails.

## 8. Optional: bundled voice clips

Without these, short phrases like "Stop" use the iPhone's built-in voice. To get them in the Firefly voice:

```bash
ELEVENLABS_API_KEY=... ELEVENLABS_VOICE_ID=... python3 scripts/generate_phrases.py
```

This writes MP3 files to `Firefly/Phrases/`. Drag that folder into the Xcode project with the Firefly target ticked. The clips contain no secrets and are fine to commit. Typing the key inline like this keeps it out of any file, but it does land in your shell history.

## 9. Optional: Azure Function for the keys

Lowest priority. Only do this once everything above works. It needs Node 18 or later, the Azure CLI and Azure Functions Core Tools.

```bash
cd azure-function
npm install
func azure functionapp publish <your-function-app-name>
```

In the Azure portal, add these under the Function App's environment variables: `GEMINI_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`. Then set `backendURL` (ending in `/api`) and `backendKey` (the function key from the portal) in `Secrets.swift`.

If you test it locally, the keys go in `azure-function/local.settings.json`, which is also gitignored.
