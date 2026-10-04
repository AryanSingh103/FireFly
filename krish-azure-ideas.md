# Firefly × Azure — strong, unique implementation ideas

Written against the code as of `d5485c9`. Today's Azure footprint is the weakest part of the
project and the rundown admits it: *"Azure is the lowest priority and gets deleted first."*
Right now it is one REST call to cloud STT (`SpeechTranscriber.swift:35`) and a key-forwarding
Function (`azure-function/src/functions/proxy.js`). Both are things any team can write in an hour,
and neither survives venue Wi-Fi going down.

## The thesis: Azure runs where the network doesn't

Every other team at this hackathon will use Azure as *a cloud endpoint they call*. Firefly's
whole doctrine is the opposite — **the safety loop never touches the network.** That reads like a
reason Azure can only ever be a bolt-on, which is exactly why the interesting move is available:

> Azure has surfaces that **ship models down to the device**. Use those, and Azure lands *inside*
> Firefly's offline core loop instead of beside it — demoable with Wi-Fi switched off.

That is the claim no one else will be making, and it inverts the current "Azure is optional"
story into "Azure is the part that still works in a dead zone." Tier 1 below is that bet.
Tier 2 is Azure doing what genuinely needs a cloud. Tier 3 is cheap polish with high judge-ROI.

---

## Tier 1 — Azure on the device (the unique part)

### 1. "Firefly" as a real wake word — Custom Keyword, on-device, offline

**The problem it fixes.** `AlwaysListener.swift` keeps Apple's `SFSpeechRecognizer` running
continuously and fakes end-of-utterance with a 1-second silence timer. The file's own comments
document the resulting pain: a pause/restart dance (`setPaused`, `scheduleRestart`,
`generation` counters) so Firefly doesn't transcribe its own voice — and commit `9c0c8ab` ("Stop
the mic hearing Firefly's own questions") was spent on exactly this. A full recognizer running
all day is also the single biggest battery draw in a chest-worn always-on app.

**The Azure version.** Speech Studio's **Custom Keyword** generates a `.table` keyword model for
any word or short phrase. It runs **at the edge via the Speech SDK, fully offline, and there is
no cost to run the model on-device.** It is not a Limited Access feature.

- Train the keyword `Firefly` in Speech Studio — pick the **Advanced** model (base-model
  adaptation with simulated training data; Basic is prototype-grade).
- Bundle the `.table`, load with `SPXKeywordRecognitionModel(fromFile:)` and run
  `SPXKeywordRecognizer` (iOS SDK: `MicrosoftCognitiveServicesSpeech-iOS`).
- Architecture becomes: **cheap local keyword spotter always on → on fire, hand the mic to the
  existing transcriber for the command.** The expensive recognizer only runs for ~3 seconds at a
  time instead of forever.

**Why it's strong:** the product's name *is* the wake word, it's a measurable battery win, it
removes a class of mic bugs they've already burned two commits on, and the demo beat is
"Wi-Fi off — *Firefly, what's in front of me?*" with Azure doing the listening. Skip Azure's
optional cloud keyword *verification* step; staying local is the entire point.

**Effort:** ~2–3 h (most of it adding the Speech SDK to the Xcode project).

### 2. A hazard namer trained on real hazards — Custom Vision → Core ML

**The problem it fixes.** `ObstacleNamer.swift` is the weakest AI in the app and it's honest
about it: a generic `VNClassifyImageRequest` filtered through a hand-written 22-entry label map
at `minimumConfidence: 0.25` — i.e. "below this it is guessing." It cannot see the things that
actually hurt a blind walker. The phrase bank already has clips for `Wet floor sign`, `Curb` and
`Open door` that the namer **can never produce**, because Apple's classifier has no such labels.

**The Azure version.** Azure Custom Vision trains an object detector in the cloud on a **compact
domain** (e.g. *General (compact)*) and **exports to Core ML** for iOS — a `.mlmodel` that runs
on-device, no network, no quota, no latency. Microsoft ships a Swift object-detection sample for
exactly this path. Drop it straight into the existing seam: `ObstacleNamer.name(in:at:)` already
receives the LiDAR crop and returns an optional name, so the swap touches one function.

Train the vocabulary blind users actually need and the current stack can't see: **wet floor
sign, curb, bollard, open door, e-scooter, trash can, stairs-up vs stairs-down, glass door
frame, pole.**

**The killer demo beat:** shoot ~50 images per class *in the venue that morning* and train it
there. "This model was trained on this building, three hours ago, and it runs on the phone with
the network off" is a far better sponsor story than any API call.

**Caveats, stated honestly:** Custom Vision is on a retirement path — **retires 25 Sept 2028**,
with Microsoft advising a transition plan since Sept 2026. It is still GA and still the
supported custom-model path (Image Analysis 4.0's *custom* classification/detection preview was
itself retired in March 2025, with customers pointed back at Custom Vision). Fine for a
hackathon; say so in the writeup rather than letting a judge catch it.

**Effort:** ~3–4 h including shooting and labelling images. This is the highest-upside item here.

---

## Tier 2 — Azure cloud doing what only a cloud can

### 3. "Firefly, read that" — Azure AI Vision Read OCR, anchored to LiDAR

**The missing sense.** Nothing in the stack reads text, and text is most of what a blind person
is denied indoors: room numbers, EXIT signs, elevator panels, door plates, bus numbers, menu
boards. `GeminiClient.answer` is explicitly capped at "under 18 words" and paraphrases — it is
the wrong tool for *exact strings*.

**The compound feature.** Azure AI Vision **Image Analysis 4.0** returns `read` (exact text, with
bounding boxes) and `denseCaptions` in **one call**. The bounding box is the interesting half:
Firefly already converts a normalised box centre into a walkable LiDAR beacon
(`GeminiClient.locate` → `Beacon.swift` → the panned chime). So:

> **read the sign → anchor it in LiDAR → walk the user to it.**

"Firefly, find room 214" becomes real. Nothing else in the stack — Gemini included — does
read + anchor + guide, and it reuses machinery that already works.

Route it through the existing Function as a third endpoint, `/vision`.
**Effort:** ~2 h.

### 4. Prosody as a distance channel — Azure Neural TTS + SSML

**Two problems, one fix.** First, `scripts/generate_phrases.py` pre-renders a combinatorial mp3
bank (`about_1_step` … `about_35_feet`, every object × every direction) and `Speaker` stitches
comma-separated parts back together. It works, but every new word needs a regen and a bigger
bundle. Second — and more interesting — the newest commit (`d5485c9`) commits to *haptics*
carrying side and closeness. **The voice carries none of it.** A chair 3 m away and a chair 0.4 m
away are read in the identical tone.

**The Azure version.** Azure Neural TTS takes SSML `<prosody rate/pitch/volume>` and
`<mstts:express-as>` styles. `AlertPolicy` *already computes* a `closeness` value in 0…1 — map it
straight onto rate and volume so the same sentence tightens as the obstacle nears. Urgency
becomes a third channel alongside haptic rhythm and the spoken words, with no extra verbosity —
which fits the design lock's "calm voice, never talks over a safety warning."

Also move clip pre-rendering server-side: an Azure Function renders the phrase list to **Blob
Storage + CDN**, the app pulls on first launch. That closes the audit's deferred
*"Generate+download phrases over time"* gap and shrinks the app bundle.

**Caveat worth knowing before you plan around it:** Azure **Embedded** Speech (on-device neural
TTS) is GA but **Limited Access — registration only, and eligibility is restricted to customers
working directly with Microsoft account teams.** You cannot get it for a hackathon. So offline
speech stays bundled-clip based; Azure owns the cloud voice and the clip pipeline.

**Effort:** ~2 h for SSML urgency; ~2 h for the Blob/CDN pipeline.

### 5. The governance play — Groundedness detection as a gate on AI speech

**The problem it fixes.** The prompts in `GeminiClient.swift` carry hard safety rules — *"Never
claim you can detect glass. Never invent crosswalks or signal colors."* Those are **hopes, not
controls.** Nothing enforces them. A hallucinated "the light is green" to a blind user at a curb
is the worst failure this product can have.

**The Azure version.** Azure AI Content Safety **Groundedness detection** checks whether an LLM
response is grounded in source material you supply, returns a `reasoning` field explaining any
ungroundedness, and can **auto-correct** the text against those sources. Firefly has unusually
good grounding sources to hand: the LiDAR depth facts, the Read OCR strings, the on-device
detector labels. If Gemini's answer isn't grounded in them, Firefly speaks the conservative line
instead of the confident one.

**Why this is the most Avanade-friendly idea on the list:** it's a responsible-AI control in a
safety-critical assistive product — enterprise governance, not a toy feature. It also gives the
writeup its best sentence: *Azure is what stops the AI from guessing at a blind person.*

**Caveats:** public preview, English-only, and it adds a round trip — so apply it **only** to the
spoken Q&A path, never to the offline safety loop. Budget it inside the existing 10 s timeout and
fall back to the canned honest line on timeout.

**Effort:** ~2 h.

---

## Tier 3 — Make the backend look professional (cheap, high judge-ROI)

### 6. Harden the Function that already exists

`proxy.js` works but reads as hackathon code, and a judge who opens it will see that. All of this
is ~1–2 h total:

- **Managed Identity + Key Vault references** (`@Microsoft.KeyVault(SecretUri=…)`) so no API key
  exists in app settings at all. This is the real version of the claim the writeup already
  makes — "keys off the device" — and it's the single cheapest credibility win.
- **A 429 shield.** `GeminiClient` already parses Gemini's `retryDelay` on the *client*. Move that
  to the Function: circuit breaker + last-good cached answer, so free-tier quota can't kill the
  live demo. The rundown flags quota as a real risk; this is the fix.
- **Validate the request.** `/gemini` currently forwards `await request.text()` unvalidated and
  unbounded — cap the body size and check the schema. `/tts` already does this well (1–300 chars);
  match it.
- **Frame-hash response cache** (Blob or Redis) keyed on a perceptual hash, so a wearer standing
  still re-asking the same question costs nothing and answers instantly.

### 7. Application Insights with a privacy-first schema

Log **numbers, never frames or transcripts** — opt-in, no PII, matching a profile that today
lives only in `UserDefaults`:

- alert → haptic latency (p50/p99)
- **% of safety callouts served fully offline** ← this is the slide
- AI fallback rate, quota hits, keyword false-accept rate

It turns the architecture doctrine into a measured claim: *"97% of safety callouts never touched
the network."* Avanade is a consulting firm; observability reads as adult engineering to them.

---

## Tier 4 — Deliberately not doing (and say why out loud)

Naming these in the writeup is worth points, because it shows the Azure choices were reasoned
rather than grabbed:

- **Azure Maps / indoor wayfinding.** Not buildable: **Azure Maps Creator was retired after
  30 Sept 2025**, and Microsoft tells new users not to start with it. Indoor routing is the holy
  grail for blind navigation, so if it's ever picked up, the path is the open **IMDF** standard —
  which Apple MapKit consumes directly, no Azure dependency. MapKit stays for outdoor.
- **Azure cloud STT as the primary path.** Slower than Apple's on-device recognition and dies on
  venue Wi-Fi. Keep `AzureSpeechTranscriber` as the existing optional fallback; don't promote it.
  Idea #1 is the better use of the Speech resource.
- **Embedded Speech.** Limited Access, Microsoft-managed customers only — unobtainable in time.
- **Caregiver portals, Cosmos dashboards, Event Grid SOS.** Turns Firefly into a platform. The
  rundown already rules these out; agree with it.

---

## If you only do two things

**#1 (Custom Keyword) + #2 (Custom Vision → Core ML).** Both run **on-device and offline**, both
replace a part of the app that is currently weak and documented as weak, and both can be demoed
with **Wi-Fi switched off** — which is the one demo no other team's Azure integration can
survive. Together they're ~6 hours and they move Azure from "lowest priority, cut it first" to
load-bearing. Add **#6 (Key Vault + 429 shield)** if an hour is left; it's the cheapest
credibility per minute on the list.

Then rewrite the sponsor line. Currently:

> *Azure: listens (Speech) and can secure the keys (Functions).*

Instead:

> **Azure ships its models down to the phone — the wake word and the hazard namer both run
> on-device with the network off. And when Firefly does reach the cloud, Azure's groundedness
> check is what stops the AI from guessing at a blind person.**

## Sources

- [Keyword recognition overview](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/keyword-recognition-overview) · [Create a custom keyword](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/custom-keyword-basics)
- [Export your model to mobile (Core ML)](https://learn.microsoft.com/en-us/azure/ai-services/custom-vision-service/export-your-model) · [iOS Core ML sample](https://github.com/Azure-Samples/cognitive-services-ios-customvision-sample) · [Custom Vision migration options](https://learn.microsoft.com/en-us/azure/ai-services/custom-vision-service/migration-options)
- [Groundedness detection (preview)](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/quickstart-groundedness)
- [Limited Access to Embedded Speech](https://learn.microsoft.com/en-us/azure/ai-foundry/responsible-ai/speech-service/embedded-speech/limited-access-embedded-speech) · [Embedded Speech](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/embedded-speech)
- [Azure Maps Creator retirement](https://learn.microsoft.com/en-us/answers/questions/2223706/azure-maps-creator-services-have-been-retired-and)
