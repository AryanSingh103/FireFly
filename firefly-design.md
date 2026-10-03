# Firefly — Product Design (GirlHacks 2026)

Source of truth for what we are building. Derived from the team vision + Q&A. Older “glow + three meters, no maps” design is superseded.

---

## 1. Product summary

Firefly is a **chest-worn iPhone Pro app** that acts as a **voice-first guide** for blind and low-vision people.

- **Passive mode:** aware of surroundings; natural-language callouts + haptics.
- **Navigate mode:** go somewhere (MapKit outdoors / vision-assisted indoors); guidance spoken by Firefly; obstacles still handled.
- **Firefly** is a small animated glowing orb/bug with Enchanted Grove personality — mostly invisible while walking, expressive when speaking or in danger.
- **Screen** is full camera view (what LiDAR/camera see), with a corner minimap, red obstacle highlights, captions for helpers/judges/low-vision users. UI is secondary; **voice + haptics are primary**.

**One line:** Open Firefly → it greets you by name → asks where you want to go (or stay passive) → watches the world and talks you through it.

---

## 2. Demo hardware & wear

| Choice | Decision |
|---|---|
| Device | One LiDAR iPhone Pro |
| Mount | Chest lanyard on case, portrait, camera forward |
| Audio | **iPhone speaker only** (no earbuds for demo) |
| Haptics | Always part of the product; primary channel in Quiet mode |
| Flip | If phone appears flipped/upside-down, **alert once**: “I might be flipped — check the lanyard.” |

**Implication of speaker-only:** no stereo left/right ear panning. Direction is **spoken** (“on your left”) + distance via **haptic rate**. Do not pitch “sound jumps to the other ear.”

**Filming:** teammates may film a blindfolded walk for the **demo video**. Live judges do **not** walk blindfolded; a teammate wears it and judges watch/listen.

---

## 3. Users

- **Primary:** blind and low-vision (including “lost my glasses / can’t see well”).
- **Secondary viewers of the screen:** teammates, judges, helpers.
- **Language:** English only.
- **One profile per phone** (hackathon). No multi-user, no “forget me,” no favorites list required.

---

## 4. Design principles

1. **Voice + haptics first**; screen is trust/debug/low-vision aid.
2. **Safety never depends on the network.** Offline = passive obstacle callouts + cached phrases + haptics.
3. **LiDAR wins conflicts** with map instructions (barrier ahead → stop/sidestep, don’t obey a blind turn).
4. **Natural language, not robot codes** — but keep phrases short enough to hear while walking.
5. **Honest limits.** No claiming perfect glass detection, full indoor floor plans, or flawless crosswalk AI.
6. **Enchanted Grove = Firefly creature**, not a forest game.
7. **Two modes only:** Passive and Navigate. Mode changes by voice.

---

## 5. Personality (Enchanted Grove)

**Vibe:** curious, warm, lightly magical, protective — like a small light that stays with you in the dark. Not sarcastic, not corporate, not hyper.

**Form:** glowing orb / firefly-bug hybrid. Soft yellow-green light. Simple enough to animate under time pressure.

**Screen presence**
- Walking / scanning: **mostly invisible** (maybe a tiny idle glow in a corner).
- Speaking / listening / thinking: light animation near caption or lower third.
- Danger (`Stop` / urgent): brighter, tighter pulse; voice shifts urgent but still clear.

**Emotions to support:** calm hello, focused guiding, worried/urgent danger, happy arrival.

---

## 6. Modes

### Passive
Default when user says they don’t need a destination (“nah,” “just help me walk,” etc.).

- Continuous awareness callouts (see §9).
- Stays Passive until they ask to go somewhere again.
- Works offline (core promise).

### Navigate
User named a place (or confirmed a search result).

- Outdoor / campus paths: MapKit walking route + Firefly-rewritten instructions.
- Indoor / “get me out”: vision + LiDAR (exit signs / doors) — see §10.
- Obstacle handling **merges** into guidance when mild; **interrupts** with Stop/haptics when close danger. Map step pauses until clear.
- Needs network for search + routing. If offline at start: *“Sorry, no connection right now — I can stay in Passive and watch for obstacles.”*

Quiet mode (voice toggle): **haptics only** — no spoken callouts at all, including `Stop`. Critical danger = a distinct strong haptic pattern only.

---

## 7. Voice agent (how control works)

### Best-for-hackathon stack (locked)

| Role | Choice | Why |
|---|---|---|
| Eyes + agent brain | **Gemini** (vision + tool calling) | Already a track; one model for scene, exit, and dialogue tools |
| Voice out | **ElevenLabs** + **~20–40 cached clips** offline | Persona + offline |
| Speech in | **Apple Speech** on-device first; Azure optional | Fast; always-listening in-foreground |
| Maps | **MapKit** walking directions | Native, enough for basic outdoor |
| Memory | **On-device** (`UserDefaults` / small JSON profile) | Easiest secure hackathon option |
| Keys | Direct in app for speed; Azure Function only if time | Don’t block demo |

### Agent loop (app open, foreground)

1. Always listening while the app is foreground, but commands must start with **“Firefly …”** (e.g. “Firefly, take me to the exit”) so loud rooms don’t false-trigger. VAD / pause ends the utterance.
2. Transcript → Gemini with tools + short memory (name, prefs, mode, last destination).
3. Model may call tools; app executes; model speaks result (or app plays cached phrase).
4. Target **≤ 3 s** to first audio for normal asks. Safety loop never waits on this.

### Tools the agent can call (v1)

- `set_mode(passive | navigate)`
- `search_places(query)` → MapKit
- `confirm_destination(place_id)` / `start_navigation` / `stop_navigation`
- `set_quiet(on/off)`
- `describe_surroundings` (Gemini + frame)
- `find_exit` / `find_door` (Gemini box → LiDAR anchor → local chime/spoken bearing)
- `save_profile(...)` during onboarding
- `close_app` (best-effort; iOS may only background — say “Closing Firefly” and exit if allowed)

### Hard rules (model must not violate)

- Never disable the LiDAR safety loop.
- Never invent a crosswalk, light color, or indoor hallway that isn’t evidenced.
- Never claim glass is detected.
- If unsure: say so, suggest a cane check / slow down, or offer options — don’t bluff.
- Prefer confirm when place search returns multiple hits (“I found X — start nav?”).

---

## 8. Lifecycle & memory

### First launch (all voice)

Firefly appears, greets, runs setup:

1. Name  
2. Preferred verbosity (brief / normal)  
3. Units preference (hear **both** steps and feet/meters in callouts; ask if they prefer steps-first or distance-first)  
4. Walking pace (careful / normal)  
5. Quiet-mode default (off unless they ask)  
6. Confirm: “Thanks, {name}. I’m Firefly — I’ll watch with you.”

Saved on device. No account.

### Every later open

1. (Optional) Siri only **launches** the app — no destination handoff.  
2. Firefly: “Hi {name}, how can I help? Where do you want to go?”  
3. If “nowhere / just watch me” → Passive.  
4. Else → search / confirm → Navigate.

### Arrival

Celebrate briefly + “Anything else?” → back to Passive or new Navigate.

---

## 9. Passive callouts (awareness)

**Named objects** when Gemini/scene layer can name them; otherwise “obstacle.”

**Timing (combined policy)**
- Only if closer than threshold **X** (tune on course; start ~2.0 m speak, ~1.0 m urgent).
- Re-announce same hazard at most every few seconds unless it gets much closer or side changes.
- Every *new* hazard gets a callout.
- “Clear path” — **once** when space opens after being close.

**Content examples (natural, short)**

- “Chair on your left, about two steps, maybe three feet.”
- “Person ahead — slow down.”
- “Stairs going down, center.”
- “Open door on your right.”
- “Wet floor sign ahead.”
- “Obstacle front-right — move about two steps left… wait.”

**Also try (vision, best-effort, never overclaim):** curbs, stairs up/down, open doors, wet-floor signs, people. Outdoor crosswalks/signs are **out of live demo focus** (mostly indoors) but can be stretch phrases if a frame clearly supports them.

**Haptics:** pulse rate = closeness (same core as before). Quiet mode = this channel only.

**Offline phrase bank:** fixed **~20–40** ElevenLabs MP3s for common templates (`Stop`, `Clear path`, `Obstacle left/ahead/right`, `Move left/right`, `Stairs`, `Person ahead`, `No connection — Passive is on`, greetings with name slot via live TTS when online). Generate more over time later; not required for weekend.

---

## 10. Indoor vs outdoor navigation

### Reality for GirlHacks venue

Live judging/demo is **mostly indoors (Campus Center)**. Outdoor MapKit is still in product scope but **not the live test path** unless you step outside on purpose.

### Outdoor / “next building” (MapKit)

1. User: “Take me to the library.”  
2. MapKit search → Firefly: “I found _____ Library, about 0.5 miles — start nav?”  
3. On confirm: walking route, **reroute on drift**, Firefly rewrites steps in its voice.  
4. Minimap shows route (Apple polyline is fine).  
5. If LiDAR says blocked: interrupt map instruction.

**Scope control:** any MapKit search is OK technically; for reliability, bias results to **nearby / walking distance** and always confirm before start.

### Indoor destination / leave building

- No floor plans. **Pure vision + LiDAR.**
- If user picks an **outdoor** destination while **indoors**: **ask** — “We’re inside — should I take you to an exit first?”
- Exit finding: Gemini looks for **EXIT signs / exterior doors** → box → LiDAR depth → world anchor → spoken bearing + optional soft guide tones on speaker (not stereo pan). Same pattern as old “door beacon,” generalized.
- Multi-floor / elevator preference: **ask once** if stairs vs elevator is ambiguous; default “safest obvious exit path I can see.”

### Offline Navigate attempt

Speak apology → offer Passive → keep cached voice + LiDAR. No fake routing.

---

## 11. Screen UI (builders / judges / low-vision)

```
┌─────────────────────────────────────┐
│████████ FULL CAMERA VIEW ███████████│
│█                                 █│
│█     (red tint / outline on       █│
│█      nearby obstacle regions)    █│
│█                          ┌─────┐ █│
│█                          │ mini│ █│
│█                          │ map │ █│
│█                          │ pie │ █│
│█                          └─────┘ █│
│█  [tiny firefly when speaking]    █│
│█  Caption: "Chair on your left…"  █│
└─────────────────────────────────────┘
```

| Element | Spec |
|---|---|
| Background | Live camera only — **no grid**, no L/C/R debug columns in the product UI |
| Obstacles | Highlight on **camera feed** (red wash/outline on near depth zones) |
| Minimap | **Corner pie** — user arrow + route if Navigate (MapKit overlay when available) |
| Firefly | Light animation when talking/listening; mostly gone while walking |
| Captions | Last spoken line(s) for judges/helpers/low-vision |
| No | Settings maze, login, caregiver UI, big button grids |

---

## 12. Safety & honesty

**Refuse to claim:** reliable glass detection; perfect crosswalk/light reading; mapped knowledge of every corridor; replacement for cane/dog.

**Uncertainty:** mix of “I think…”, silence when below confidence, and “I’m not sure — slow down / cane check.”

**Emergency (in, light version):** on “help” / “emergency,” Firefly switches urgent voice: stay put if unsafe to move, call out for people nearby, offer to describe surroundings; **no** SMS/caregiver pipeline this weekend.

**Blindfolded video:** allowed for recorded demo with spotters. Live judging: teammate wears, judge watches.

---

## 13. What’s in / out for GirlHacks

### Must ship for the story

1. Chat-style voice agent on open (greet + name memory + ask where to go)  
2. Passive callouts + haptics + full camera UI + captions  
3. Quiet mode (haptics-only)  
4. Animated Firefly (even if simple)  
5. Indoor exit/door finding (vision → LiDAR anchor → spoken guide)  
6. Offline degrade → Passive + cached phrases  
7. Siri can **open** the app  
8. Basic MapKit search + walking nav + confirm + rewritten prompts (even if demo stays indoors)  
9. Flip-once warning  
10. Arrival beat + “anything else?”

### Explicitly out / later

- Earbuds / stereo panning  
- Caregiver sharing, multi-stop trips, “be quiet 5 minutes,” user corrections training  
- Battery/heat nag UX  
- Full outdoor hazard demo (crosswalks etc.) as a judged live beat  
- Downloaded full offline map tiles (nice idea; **not** required if Navigate simply refuses offline)  
- Closing the app by voice if iOS blocks it — best effort only  

---

## 14. Demo script (aligned to this design)

1. Siri/open app → “Hi {name}, where do you want to go?”  
2. “Nowhere — just help me.” → Passive: walk toward a chair → named callout + haptics + red highlight on screen.  
3. Quiet mode toggle → show haptics-only.  
4. “Get me to an exit / the door.” → find exit/door → guide by voice.  
5. (Optional if Wi‑Fi) “Take me to {nearby place}.” → confirm distance → start nav → minimap route — or show offline apology → Passive.  
6. Close: Firefly is another sense on a phone you already carry — not a cane replacement.

Backup video: blindfolded teammate Passive + door/exit, spotters present.

---

## 15. Decisions we locked when you said “whatever is best”

| Topic | Lock |
|---|---|
| LLM / tools | Gemini + explicit tools |
| STT | Apple first |
| Memory | On-device profile |
| Nav vs obstacle | Merge mild; interrupt on close danger; LiDAR > map |
| Outdoor in live demo | Supported in product; **not** the main stage beat |
| Offline maps | Skip tile download; refuse Navigate, keep Passive |
| Phrase count | 20–40 fixed bank + live TTS online |
| Always listening | Foreground continuous; commands require **“Firefly …”** prefix |
| Quiet mode | Haptics only — **no spoken Stop** |
| Live Navigate hero | **Exit / door** (indoor vision + LiDAR), not outdoor Maps |
| Emergency | Light in-app guidance only |
| Minimap route drawing | Use MapKit polyline (easier) |

---

## 16. Design locked

These final calls are decided:

1. Quiet mode = **no voice at all** (including Stop); danger is haptic-only.  
2. Commands require **“Firefly …”** while always listening.  
3. Live demo Navigate beat = **take me to the exit/door**.

This document is the build target unless the team explicitly revises it.
