# Repository guidance

## Project

Musubi is a Swift package for reading, normalizing, and eventually writing
image-generation metadata. Its first consumers are Mochi Diffusion and a local
image viewer. The 0.1 contract is read-only PNG and JPEG inspection.

Open `Package.swift` directly; do not create an Xcode project for the library.
Keep the core target independent of SwiftUI, AppKit, image pixel types, network
clients, and the consuming applications.

## Architecture invariants

- Preserve ordered raw metadata payloads even when normalization succeeds.
- A file may have several valid source interpretations and generation records.
- Keep image-container scanning separate from generator codecs.
- Do not decode or re-encode pixels as part of metadata inspection.
- Treat image bytes and embedded metadata as untrusted input. Use bounded reads,
  checked arithmetic, and explicit decompression limits.
- Do not silently infer unknown values or resource identities.
- Keep Mochi legacy support based on its released `origin/main` behavior. Do not
  add support for unfinished or abandoned local branches.

## Development

Use Swift 6 and Swift Testing. Before committing behavior changes, run:

```sh
swift test
swift build -c release
```

The ignored `example images/` directory contains private exploratory inputs.
It may be inspected locally, but its images, prompts, filenames, or derived
fixtures must not be committed without explicit redistribution permission.
Tests should normally construct small synthetic containers in memory.

Keep public APIs documented. Prefer focused value types and small semantic
functions over loosely typed dictionaries or application-specific models.
Writing APIs must accept and return bytes without implicitly overwriting files.

## Relevant agent skills

When the skills are available, use them as follows:

- `self-documenting-code` for model, codec, and API design changes.
- `swift-testing` whenever adding, changing, or reviewing tests.
- `refactor-pass` after non-trivial implementation work or when simplifying
  existing code; verify the result with the full test and release builds.
- `swift-concurrency` only when introducing tasks, actors, async APIs, or new
  `Sendable` boundaries. Inspection is intentionally synchronous today.
- `swift-c-interop` when changing the Compression framework boundary or adding
  another C library.

