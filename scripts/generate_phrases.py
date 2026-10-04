"""Generate the bundled Firefly voice clips with ElevenLabs.

Usage:
    ELEVENLABS_API_KEY=... ELEVENLABS_VOICE_ID=... python scripts/generate_phrases.py

Clips are written to Firefly/Phrases/ and existing ones are skipped.
"""

import json
import os
import re
import sys
import urllib.request
from pathlib import Path

OBJECTS = [
    "Obstacle", "Chair", "Table", "Desk", "Couch", "Person", "Wall",
    "Door", "Doorway", "Backpack", "Bag", "Stairs", "Trash can",
    "Wet floor sign", "Curb", "Open door",
    # Names from the on-device namer (Firefly/ObstacleNamer.swift).
    "Bench", "Bicycle", "Car", "Dog", "Sign", "Cabinet", "Shelf", "Box",
]
# Must match FireflyEngine.directionWord.
DIRECTIONS = ["on your left", "ahead", "on your right"]
# Distance parts from UserProfile.formatDistance. Callouts start at about 2 m (6.5 ft), so these
# ranges cover every callout with room to spare.
MAX_STEPS = 8
MAX_FEET = 12
EXTRAS = [
    "Stop",
    "Clear path",
    "Okay",
    "move left",
    "move right",
    "turn left",
    "turn right",
    "Hi, I'm Firefly. I'll watch the path with you.",
    "I'm here. Ask me what's in front of you.",
    "I might be flipped — check the lanyard.",
    "Quiet mode on. I'll tap only.",
    "Quiet mode off. I'll speak again.",
    "Closing Firefly.",
    "I'm not sure what's there.",
    "I can't reach the internet right now, but I'm still watching for obstacles.",
    "I've used up my AI requests for now, but I'm still watching for obstacles.",
    "Something went wrong asking the AI, but I'm still watching for obstacles.",
    "I'm with you. Stay still if it feels unsafe. Call out for people nearby. I can describe what's around — ask me.",
]

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "Firefly" / "Phrases"


def slug(text: str) -> str:
    """Must match Speaker.slug in Firefly/Speaker.swift."""
    return "_".join(re.findall(r"[a-z0-9]+", text.lower()))


def synthesize(text: str, api_key: str, voice_id: str) -> bytes:
    request = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128",
        data=json.dumps({"text": text, "model_id": "eleven_flash_v2_5"}).encode(),
        headers={"xi-api-key": api_key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request) as response:
        return response.read()


def all_phrases() -> list[str]:
    # Lines like "Chair on your left, about 3 steps, maybe 7 feet" are played as one clip per
    # comma-separated part (see Speaker.clipURLs), so each part is generated on its own.
    phrases = [f"{obj} {direction}" for obj in OBJECTS for direction in DIRECTIONS]
    for n in range(1, MAX_STEPS + 1):
        unit = "step" if n == 1 else "steps"
        phrases += [f"about {n} {unit}", f"roughly {n} {unit}"]
    for n in range(1, MAX_FEET + 1):
        phrases += [f"about {n} feet", f"maybe {n} feet"]
    phrases += EXTRAS
    return list(dict.fromkeys(phrases))


def main() -> None:
    api_key = os.environ.get("ELEVENLABS_API_KEY")
    voice_id = os.environ.get("ELEVENLABS_VOICE_ID")
    if not api_key or not voice_id:
        sys.exit("Set ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID first.")

    phrases = all_phrases()
    # Clips for lines the app no longer says are removed.
    wanted = {f"{slug(p)}.mp3" for p in phrases}
    for old in OUTPUT_DIR.glob("*.mp3"):
        if old.name not in wanted:
            old.unlink()
            print(f"removed {old.name}")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for phrase in phrases:
        path = OUTPUT_DIR / f"{slug(phrase)}.mp3"
        if path.exists():
            continue
        path.write_bytes(synthesize(phrase, api_key, voice_id))
        print(f"{path.name}  <-  {phrase}")


if __name__ == "__main__":
    main()
