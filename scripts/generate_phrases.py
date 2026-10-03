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
]
DIRECTIONS = ["left", "ahead", "right"]
EXTRAS = [
    "Stop",
    "Clear path",
    "Step down",
    "Turn slowly",
    "Okay",
    "I didn't catch that",
    "I can't reach the network",
    "I can't see a door",
    "Found the door. Follow the chime.",
    "You're at the door",
    "Doorway, slightly right",
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


def main() -> None:
    api_key = os.environ.get("ELEVENLABS_API_KEY")
    voice_id = os.environ.get("ELEVENLABS_VOICE_ID")
    if not api_key or not voice_id:
        sys.exit("Set ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID first.")

    phrases = [f"{obj}, {direction}" for obj in OBJECTS for direction in DIRECTIONS] + EXTRAS
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for phrase in phrases:
        path = OUTPUT_DIR / f"{slug(phrase)}.mp3"
        if path.exists():
            continue
        path.write_bytes(synthesize(phrase, api_key, voice_id))
        print(f"{path.name}  <-  {phrase}")


if __name__ == "__main__":
    main()
