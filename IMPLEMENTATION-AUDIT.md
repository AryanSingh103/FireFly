# Implementation vs design — audit

Checked against `firefly-design.md` before push.

## Implemented

| Design item | Status |
|---|---|
| Full camera UI, no L/C/R grid | Done |
| Red near-depth wash on camera | Done (DebugPreview heat) |
| Corner minimap pie + route | Done |
| Captions | Done |
| Firefly orb (mostly hidden while idle) | Done |
| Voice onboarding + on-device profile | Done |
| Always listen + **Firefly** prefix | Done |
| Passive callouts + steps/feet | Done |
| Quiet = haptics only (incl. Stop) | Done |
| Exit/door vision → LiDAR beacon | Done |
| MapKit search + confirm + walking nav | Done |
| Ask exit-first when likely indoors | Done (once; fixed loop bug) |
| Offline Navigate → offer Passive | Done |
| Flip-once warning | Done |
| Emergency light response | Done |
| Speaker-only (no stereo pan pitch) | Done |
| Arrival + “Anything else?” | Done |
| Siri open | OS-level (“Open Firefly”); no custom intent needed |

## Gaps / deferred (not blockers for first device build)

| Item | Notes |
|---|---|
| True Gemini tool-calling agent | Hybrid: local command router + Gemini for vision/Q&A (more reliable for hackathon) |
| Cached offline map tiles | Skipped per design; Navigate refuses offline |
| Generate+download phrases over time | Script + fixed bank only |
| Verbosity “brief” | Now shortens Gemini hazard lines; generic obstacle lines still longer |
| Live ARSCNView | Using frame snapshots (works; not SceneKit camera) |
| Close app by voice | Best-effort `suspend` hack |

## Bugs fixed in this pass

1. **Dual AVAudioEngine** (TonePlayer + AlwaysListener) → TonePlayer now uses WAV + `AVAudioPlayer`
2. **Mic never coming back** after ElevenLabs TTS (async gap) → `watchSpeechEnd()`
3. **Indoor “exit first?” yes-loop** → `askedExitFirst` flag + outdoor/exit follow-ups
4. **Onboarding said “say nowhere” without prefix** → prompt now says `Firefly, nowhere`
5. **Compile break in `announceHazard`** after verbosity edit → fixed `name` binding
