#!/usr/bin/env bash
# Run this once on the Mac before opening Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f Firefly/Secrets.swift ]]; then
  cp Firefly/Secrets.swift.example Firefly/Secrets.swift
  echo "Created Firefly/Secrets.swift — fill in keys (Gemini + ElevenLabs at minimum)."
else
  echo "Firefly/Secrets.swift already exists."
fi

# Optional: generate Firefly-voice clips if keys are in the environment.
if [[ -n "${ELEVENLABS_API_KEY:-}" && -n "${ELEVENLABS_VOICE_ID:-}" ]]; then
  python3 scripts/generate_phrases.py
  echo "Phrase clips written to Firefly/Phrases/."
else
  echo "Skipping phrase generation (set ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID to generate)."
fi

echo
echo "Next:"
echo "  1. Open Firefly.xcodeproj"
echo "  2. Signing & Capabilities → select your Team"
echo "  3. Plug in the LiDAR iPhone, pick it as the run destination, hit Run"
echo "  4. First test: chair on LEFT should light LEFT column + left-ear beep"
open Firefly.xcodeproj
