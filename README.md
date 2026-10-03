# Firefly

Chest-worn iPhone guide for blind and low-vision navigation. Voice-first: Firefly greets you, remembers your name, watches obstacles with LiDAR, and can lead you to an exit or a place on the map.

> Firefly doesn't need AI to keep you from walking into a wall. The phone handles danger locally. Gemini helps Firefly understand the world.

## Product

- **Passive** — named obstacle callouts + haptics (Quiet = haptics only)
- **Navigate** — indoor exit/door via vision + LiDAR; outdoor walking via MapKit
- **Always listening** — say **“Firefly, …”**
- **Screen** — full camera, red near-depth wash, corner minimap, captions, glowing firefly orb

Design lock: [`firefly-design.md`](firefly-design.md) · Mac setup: [`SETUP.md`](SETUP.md)

## Quick start (Mac)

```bash
./scripts/mac-bootstrap.sh
```

Sign in Xcode, run on a **LiDAR iPhone Pro**, fill `Firefly/Secrets.swift`.

## Demo voice lines

- “Firefly, nowhere” / “just help me” → Passive  
- “Firefly, quiet on” / “quiet off”  
- “Firefly, take me to the exit”  
- “Firefly, take me to the library” → confirm → start nav  
- “Firefly, what's in front of me?”

## Stack

ARKit LiDAR · Core Haptics · Gemini · ElevenLabs · MapKit · Apple Speech
