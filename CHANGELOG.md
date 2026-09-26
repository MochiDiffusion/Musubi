# Changelog

Musubi follows [Semantic Versioning](https://semver.org/). Changes before 1.0
may include source-breaking API refinements and will be called out here.

## Unreleased

### Changed

- `MetadataInterpretation` reports a `format` and an optional `producer`
  instead of a `source` and `sourceVersion`. An AUTOMATIC1111-compatible record
  with `Civitai resources` is no longer attributed to Civitai.
- `GenerationRecord.guidance` is now `cfgScale`, and `additionalValues` is now
  `parameters`, an ordered list that can repeat keys.
- `GenerationResource.hash` is now `hashes`, and each hash records its
  algorithm when the source identifies it.
- `GenerationResourceKind` is an open string type. Unrecognized source kinds
  keep their spelling, and textual-inversion embeddings have their own kind.
- The legacy Mochi Diffusion `Scheduler` value is reported as the sampler.
- Explicitly empty legacy Mochi Diffusion and Draw Things prompts stay empty
  instead of becoming missing.

### Added

- `MetadataInspector.interpret(_:)` interprets payloads that another framework
  extracted, such as XMP from a HEIC image.
- `GenerationRecord.generatedAt` for metadata that records a generation time.
- The `Software` setting in AUTOMATIC1111-compatible text names the producer.

## 0.1.1 - 2026-09-22

### Fixed

- Treat PNG pixel and unrelated chunk payloads as opaque during metadata
  inspection, avoiding size-dependent CRC work.

## 0.1.0 - 2026-09-05

### Added

- Bounded PNG and JPEG metadata scanning without pixel decoding.
- Ordered preservation of PNG text, XMP, Exif, JPEG Exif, and JPEG comment
  payloads.
- Normalized metadata inspection for Draw Things, ComfyUI,
  Automatic1111-compatible/Civitai, and classic Mochi Diffusion metadata.
- Common prompt, model, sampler, scheduler, seed, dimensions, denoise, and
  resource fields.
- Multiple interpretations and generation records for hybrid or multi-stage
  images.
- `musubi-inspect` command-line development tool.
- Synthetic Swift Testing coverage for the primary codecs and container error
  handling.
