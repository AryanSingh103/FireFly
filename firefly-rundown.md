# Firefly: Full Project Rundown
GirlHacks 2026, NJIT Campus Center, Oct 3-4, 2026 (24 hours)

---

## 1. The Pitch

**One sentence (the 10-second rule):**
We built Firefly, an iPhone app worn on your chest that uses LiDAR, Gemini and ElevenLabs to guide blind users: it buzzes and speaks when something is in the way, and leads you to where you want to go.

**Core framing line:**
"Firefly doesn't need AI to keep you from walking into a wall. The phone handles immediate danger locally. Gemini helps Firefly understand the world around you."

**Closing line:**
"Firefly doesn't replace a cane or a guide dog. It adds another sense to a device people already carry."

**Why the name works:** a firefly is a tiny point of light that helps you navigate darkness.

---

## 2. Goals and Targets

**Primary objective: First Place. It is non-negotiable.** Every decision is judged by whether it helps the core demo. If a track or feature hurts the chance of first place, it gets cut.

| Target | Status | How we win it |
|---|---|---|
| First Place (AirPods Pro 3 each) | Primary | One flawless, memorable demo |
| [MLH] Best Use of ElevenLabs | Going for it | The Firefly voice is part of the product identity, not just a text reader |
| [MLH] Best Use of Gemini API | Going for it | Gemini does scene understanding and door finding, not basic distance detection |
| Best Enchanted Grove Vibes Hack | Going for it | The firefly persona and glowing dot, nothing more |
| Best Use of Azure by Avanade | Going for it, lowest priority | Azure Speech for questions, Azure Function for keys. Cut if it threatens the core |
| Best Beginner Hack | Free extra if eligible | Needs at least 50% first-time hackers |
| Best Diversity Hack | Free extra if eligible | Needs at least 75% women or non-binary members |
| AI for the Modern Enterprise by ADP | Dropped | Workplace framing would distort the project |
| Solana, Tiger Data, GoDaddy Registry | Skipped | They would bolt on features and dilute the pitch |

**Note:** the HackHERS notes mention a two-track cap, which may not apply here. Ask the organizers how many tracks you can submit to.

---

## 3. Judging Criteria and How Firefly Hits Each

1. **Creativity and Innovation:** a phone that senses the physical world and communicates it through another sense, with a firefly guide leading you.
2. **Design and UX:** calm short voice, haptic pulses, ear-panned audio, one glowing dot on screen.
3. **Functionality and Implementation:** the offline safety loop works with Wi-Fi off, shown live.
4. **Value and Impact:** needs no extra hardware, built on a phone people already own, versus assistive devices that cost hundreds or thousands of dollars.
5. **Presentation and Demo Quality:** a teammate wears it, the judge watches obstacles trigger changes in real time, plus an honest closing.

---

## 4. Hackathon Strategy Rules (from the brief)

- **10-second test:** the pitch must fit in one sentence ("We built X that uses Y to solve Z").
- **Master one feature:** the obstacle warning loop is the one feature built exceptionally well.
- **Magic moment:** a 5-second moment where judges react (chair moves closer, buzzing speeds up, sound follows into the other ear).
- **Polished Apple frameworks:** ARKit, Core Haptics and AVAudioEngine make the app look finished.
- **Physicality:** a phone worn on the body that perceives the room beats another browser-based AI app.
- **Balanced pitch:** technical flex plus a relatable problem with a real-world hook.
- **Demo gods:** hardcode backups, record a short backup video, keep a fail-safe that does not need venue Wi-Fi.
- **Ruthless scope:** no dashboard, login, profile, caregiver portal, social network, database or blockchain.

---

## 5. Key Decisions Made

- **iPhone only. No ESP32, no sensors, no buzzers, no extra hardware.**
- **LiDAR iPhone** (Pro models, 12 Pro or later) replaces the ultrasonic setup.
- **No blindfolded judge walking.** Even with a spotter, one LiDAR miss turns the demo into a safety incident. A teammate wears it and the judge watches. The judge can listen to the audio and feel the haptics while standing still.
- **Dropped the "glass door" joke** from the hook, because LiDAR can miss glass and shiny surfaces and a judge may know that.
- **Navigation is included**, but as an indoor "Take me to the door" beacon, not GPS turn-by-turn (see section 8). GPS is useless indoors, which is where the demo happens.
- **Safety is never handed to AI.** The local safety loop runs without internet. Gemini and Azure are enhancements.
- **ADP is out** (workplace framing distorts the project).
- **Azure is the lowest priority** and gets deleted first if the core is not perfect.

---

## 6. Architecture

### Local safety loop (no internet, the headline)
- **ARKit scene depth:** `.sceneDepth` frame semantics gives a depth map from LiDAR.
- **Zones:** split the depth map into left, center and right columns. Use only a middle horizontal band so the floor does not register as an obstacle. Take a low percentile (not the raw minimum) of valid pixels per zone, then smooth over roughly 5 frames.
- **Fallback if the full depth map fights you:** sample a coarse 3x3 grid at chest height instead of processing every pixel. Less pretty, much faster to build, enough for the demo.
- **Alert policy:** silent beyond about 3 m. Pulse interval shrinks from roughly 1 s at 2.5 m to about 0.1 s at 0.4 m. Only the nearest zone speaks.
- **Core Haptics:** pulse rate driven by distance.
- **Spatial audio (AVAudioEngine):** pan set to left or right so the direction is obvious. The iPhone has only one vibration motor, so haptics carry closeness and stereo audio carries direction.
- **Phrase bank:** pre-generated ElevenLabs clips bundled in the app, for example "Chair, left", "Doorway, ahead", "Step down", "Stop", "Clear path". Add a cooldown so phrases never stack on alerts or talk over a safety warning.

### AI perception layer (needs internet, never safety-critical)
- **Gemini scene description:** every ~4 seconds, send a downscaled camera frame with a strict prompt: nearest hazard only, under 10 words, in left/ahead/right terms. ElevenLabs speaks it only when no safety alert is active.
- **"What's in front of me?"** the wearer taps a button and asks out loud. The question goes to Gemini with the current frame, and ElevenLabs speaks the answer.
- **Speech-to-text behind a small protocol (interface):** build it first with Apple's on-device speech recognition (fast, reliable), then swap in Azure Speech only if you are ahead of schedule. This keeps Azure from ever blocking the core build.
- **Azure Functions:** one small backend that holds the Gemini and ElevenLabs keys so they stay out of the app. Last priority, fine to cut.
- **Demo mode:** one button that replays a recorded Gemini and voice-question response if the network fails.

### Layers at a glance

| Layer | What it does | Internet? |
|---|---|---|
| LiDAR (ARKit scene depth) | Left/center/right nearest obstacle | No |
| Core Haptics | Pulses faster as obstacles get closer | No |
| Spatial audio (AVAudioEngine) | Warnings in the left or right ear | No |
| Cached ElevenLabs phrases | Instant spoken warnings | No |
| Door beacon (after setup) | Chime pans toward target, speeds up near it | No |
| Gemini vision | Scene descriptions, finds the door | Yes |
| Azure Speech | Spoken question transcription | Yes |
| Azure Functions | Hides API keys | Yes |

Story for judges: **"Gemini sees, Azure listens, ElevenLabs speaks, and the safety loop runs offline."**

---

## 7. The Firefly Persona (Enchanted Grove hook)

- A small, calm guide with short, warm, directional phrases: "I've got you, chair on your left."
- The voice should be calm, short, directional, never annoying, and never talking over safety alerts. Examples: "Chair, left." "Doorway, ahead." "Step down."
- A soft glowing dot on screen that pulses when Firefly speaks.
- That is all the theme needs. Do not build extra themed features and do not turn the app into a forest explorer.

---

## 8. The Features (all kept)

### Feature 1: Obstacle warnings (the demo)
LiDAR splits the view into left, center and right. Closer obstacles make the phone buzz faster, and a beep plays in the matching ear. Works with no internet.

### Feature 2: Firefly voice
Short ElevenLabs phrases, pre-generated and saved in the app so they play instantly.

### Feature 3: "Take me to the door" (navigation)
1. The wearer taps and says "take me to the door."
2. Gemini gets a camera frame and returns a bounding box for the door. (Gemini supports this, but check the docs for the exact format.) If it cannot see one, Firefly says "turn slowly" and retries.
3. Read the LiDAR depth at the box center and unproject it with the camera intrinsics into a 3D point in ARKit's world space. Anchor it.
4. From then on it is fully local. Every frame, compute the bearing and distance from the phone's pose to the anchor. A soft chime pans toward the target and speeds up as you close in. "You're at the door" plays at about 1 m.

**Channels stay separate:** chime = where to go, haptic pulses and spoken warnings = danger. If a chair is ahead, the warning interrupts the chime, the wearer sidesteps, and the chime resumes. After step 2, nothing needs internet.

**Be honest in the pitch:** this is a beacon, not a path planner. It points you at the goal, and the safety loop keeps you off obstacles. Do not claim it routes around things.

### Feature 4: "What's in front of me?"
The wearer asks out loud, Gemini looks at the camera, and Firefly answers in voice ("Doorway, slightly right").

### Feature 5: Azure
Azure Speech handles the spoken question (swapped in after Apple speech works). An Azure Function holds the API keys.

---

## 9. Build Order (each must work before the next starts)

1. Obstacle warnings: depth zones, haptics, ear-panned beeps, polished until flawless
2. Cached ElevenLabs Firefly voice clips
3. "Take me to the door" beacon (Gemini box, LiDAR anchor, panned chime)
4. "What's in front of me?" scene description with voice question (Apple speech first)
5. Azure Speech swap for Avanade, only if 1-4 are done
6. Azure Functions key backend, only if there is time left

Number 1 is the demo. If time gets tight, trim from the bottom. Items 4 and 5 are the first to go after that.

**Development mantra:** not "let's add Gemini," not "let's add Azure," not "let's make a cool onboarding screen." LiDAR to obstacle to direction to haptic/audio works beautifully first, then Gemini, then ElevenLabs, then Azure.

---

## 10. Before You Start (first hour)

- Confirm the iPhone is a **Pro model (12 Pro or later) with LiDAR**. If it has no LiDAR, the sensing approach changes entirely.
- Confirm you have **a Mac with Xcode and a teammate comfortable with Swift or ARKit**.
- **Build and signing first:** get an empty Xcode project running on the phone. A free Apple ID can sideload to your own phone, but the build expires after 7 days, which is fine for a weekend.
- Get **Gemini, ElevenLabs and Azure keys**. Azure for Students normally gives credits without a credit card (confirm current terms), or ask at the Avanade table.
- Split into three lanes: **iOS/LiDAR**, **AI/voice/Azure**, and **demo/pitch** (course, slides, Devpost). With a small team, one person covers demo and pitch alongside other work.
- Gather: chest strap or lanyard with phone holder, power bank, earbuds, and a headphone splitter or second pair so the judge can hear the stereo audio.

---

## 11. Hour-by-Hour Plan (hours from now)

The exact start of the clock is unknown, so shift these to match your real deadline.

| Hours | Goal |
|---|---|
| 0-1 | Roles, repo, keys, Xcode project builds on the phone |
| 1-3 | **iOS:** ARKit depth zones with nearest distance per zone shown on screen. **Hour-2 checkpoint:** live left/center/right distances change when you move a chair. If not, drop to the coarse 3x3 grid. **AI:** one camera frame to Gemini returns a directional description under 10 words |
| 3-5 | **iOS:** Core Haptics (pulse rate scales with distance) and stereo-panned beeps. **AI:** generate the ElevenLabs phrase bank and bundle the audio in the app |
| 5-7 | Hook depth zones to phrases (nearest obstacle on the left triggers "Chair, left" in the left ear). Add cooldowns so phrases never overlap |
| 7-9 | "Take me to the door": Gemini bounding box, LiDAR unprojection, world anchor, panned chime, arrival phrase |
| 9-10 | Gemini scene loop with the strict prompt, plus the "What's in front of me?" button. Speak results only when no safety alert is active |
| 10-11 | **Milestone: the full loop works end to end.** Wear it, walk a hallway, fix false alarms. Cut anything unfinished from here on |
| 11-13 | Build the real obstacle course (chair, backpack, doorway). Tune thresholds on it. Record a 15-second backup video of a clean run |
| 13-15 | Azure Speech swap and Azure Function, only if the core is solid. Otherwise use the time to rehearse |
| 15-18 | Sleep in shifts (3-4 hours each). Polish the UI and persona |
| 18-20 | Demo mode button, then full rehearsals |
| 20-22 | Devpost writeup, GitHub README, screenshots, optional 2-3 minute video |
| 22-23 | Submit early, then two timed demo rehearsals |
| 23-24 | Buffer: charge everything, set up the course at your table |

---

## 12. The 2-Minute Demo Script

A teammate wears Firefly. The judge watches and listens.

| Time | Beat |
|---|---|
| 0:00-0:15 | **Hook:** "Blind people don't need their phone to describe the world. They need it to help them navigate it." |
| 0:15-0:25 | **Pitch:** "We built Firefly, an offline navigation assistant that uses LiDAR to detect obstacles and communicates their direction through haptics and spatial audio." |
| 0:25-0:55 | **Static proof:** chair straight ahead, the screen shows CENTER 2.4 m, then 2.0, 1.5, 1.0, 0.7 while the pulses accelerate. Move the chair left (LEFT, left-ear warning), then right (RIGHT, right-ear warning). Judge listens on the second earbuds |
| 0:55-1:20 | **Wi-Fi off:** "This part doesn't need the internet." The teammate walks the course and Firefly warns as they go |
| 1:20-1:40 | **Door beacon:** Wi-Fi back on. "Firefly, take me to the door." The chime sounds in the left ear, the teammate turns until it centers and walks. A chair in the way triggers the haptics and "Chair, ahead." They sidestep, the chime resumes, then "You're at the door" |
| 1:40-1:50 | **Voice question:** the judge asks "What's in front of me?" and Firefly says "Doorway, slightly right" in the Firefly voice |
| 1:50-2:00 | **Close:** "Firefly doesn't replace a cane or a guide dog. It adds another sense to a device people already carry." Thank the judge |

If the demo runs long, cut the voice question first. The static proof and Wi-Fi-off segments are the heart of it.

Open with a relatable problem, not a text-heavy slide, and let a little humor in early so judges pay attention.

---

## 13. Risks and Protections

### Demo rules
- **Offline core is non-negotiable.** Turn Wi-Fi off mid-run in every rehearsal. The teammate must still complete the course on LiDAR, haptics and cached phrases alone.
- **Azure and Gemini are enhancements.** Use a phone hotspot, keep demo mode ready, and drop Azure entirely if you are behind at the hour-11 milestone.
- **Same chair, same backpack, same spacing, every time.**
- **Keep a 15-second screen recording** of a clean run as a backup.
- **Never use a blindfolded judge.** A teammate wears it.
- **Be honest:** it is a prototype and an assistive aid, not a replacement for a cane or guide dog.
- **Keep it to one flow.** No caregiver portal, maps or dashboards.

### Technical risks

| Risk | Fix |
|---|---|
| One vibration motor | Direction comes from stereo audio. Everyone in the demo needs earbuds. Bring a splitter or second pair for the judge |
| LiDAR is Pro-only | Confirm the model first |
| Left/right swapped or rotated in ARKit depth | The depth buffer comes in sensor orientation (landscape), and its X axis can be inverted relative to the portrait display. Fix the mounting (portrait, camera forward, chest strap) and test with an object on a known side before building on top of it |
| Floor registering as an obstacle | Use a middle horizontal band and a low percentile per zone |
| Jittery readings | Smooth over about 5 frames |
| LiDAR misses glass and shiny surfaces | Do not claim it detects glass, and keep glass out of the demo course |
| Battery and heat | ARKit plus camera drains fast. Bring a power bank and keep the screen dim in rehearsals |
| Xcode build or signing delay | Do it in the first hour |
| Gemini or speech lag on bad Wi-Fi | Phone hotspot, plus demo mode with a recorded response |
| Gemini door box wrong or missing | Say "turn slowly" and retry, and keep a recorded run for demo mode |
| Door beacon claims too much | Pitch it as a beacon, not a path planner |

---

## 14. Azure Plan (for Avanade, optional)

- **Azure Speech** (about 1-2 hours): tap-to-talk question ("where's the door?" or "what's in front of me?"). The app transcribes it with Azure Speech, sends it to Gemini with the current frame, and ElevenLabs speaks the answer. Use a tap button, not wake-word detection. Azure has a Speech SDK for iOS (Swift).
- **Azure Functions** (about 30 minutes): a small backend between the app and the Gemini and ElevenLabs keys. Keeps keys out of the app, which is a real security point for the writeup, and gives one place to add logging or caching.
- **Azure AI Vision as a fallback** (only if everything else is done): if Gemini times out, a basic object list ("chair, person, door") so the wearer still hears something. The weakest of the three.
- **Skip:** Azure Maps, Cosmos DB dashboards, caregiver portals and anything that turns Firefly into a platform.
- **Rule:** do the Azure work only after the core loop works (the hour-10-to-11 milestone). If it takes three hours and the core is not perfect, delete Azure. First place is worth more than a backpack.
- Don't demo Azure Speech live on venue Wi-Fi without a fallback. Prepare a recorded transcript of a sample question for demo mode.

---

## 15. Overlap With Shepherd (TreeHacks 2026 Grand Prize)

Shepherd is a motorized smart cane that also uses iPhone LiDAR split into left/center/right zones with haptic pulses, so do not pitch the depth zones as novel.

**Your differentiators:**
- Needs no extra hardware: just a phone, versus their motorized cane with an ESP32 and motor.
- Voice-first: the Firefly voice and spoken questions.
- Follow-the-light door beacon with a chime that pans toward the target.
- Ear-panned audio direction.

Also make sure your Devpost writeup does not copy their phrasing. GirlHacks judges probably have not seen Shepherd, but be ready for the question.

---

## 16. Submission Checklist

- [ ] Devpost project with a clear description
- [ ] GitHub repository link
- [ ] One line per sponsor: "Gemini: sees. ElevenLabs: speaks. Azure: listens and secures the keys."
- [ ] Optional 2-3 minute demo video
- [ ] Tracks selected: First Place, ElevenLabs, Gemini, Enchanted Grove, Avanade (plus Beginner or Diversity if eligible)
- [ ] At least one team representative present at the venue during judging (all teams present in person)
- [ ] Submit before the deadline
- [ ] Join the Discord (listed in the hackathon to-dos)
- [ ] Charge everything and set up the course at your table

---

## 17. Open Questions to Confirm Early

1. Is the iPhone a Pro model with LiDAR?
2. Is there a Mac with Xcode, and has anyone written Swift or used ARKit?
3. How many tracks can you submit to?
4. What is the actual submission deadline (so the hour plan can be shifted)?
5. Are you eligible for Best Beginner (50% first-time hackers) or Best Diversity (75% women or non-binary)?
6. How many people are on the team?

---

## 18. Next Step

Starter Swift code for obstacle warnings (ARKit depth zones, alert policy, Core Haptics and spatial audio) so your first hour ends with a working screen.