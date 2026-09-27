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

- `GenerationSelection`, through `MetadataInspection.selection`, names the
  generation an image most likely records or reports ambiguity.
- AUTOMATIC1111 text is read as the WebUI reads it: sparse settings lines,
  unquoted values, empty prompts, ordered unrecognized settings, reported
  invalid or conflicting values, and `<lora:>` tags as resources.
- Limits on decompressed bytes, payload count, JSON and XML nesting, ComfyUI
  graph size and Exif directories. XML document type declarations are rejected.
- JSON seeds up to 64 bits are exact, and larger ones are left out instead of
  rounded.
- `MetadataInspector.interpret(_:)` and the native decoders apply the same
  payload and size limits as `inspect`.
- The ComfyUI model and size follow the sampler's own links. Several different
  candidates leave a field unset with a diagnostic instead of the first by
  node ID.
- `MetadataInspector.interpret(_:)` interprets payloads that another framework
  extracted, such as XMP from a HEIC image.
- `GenerationRecord.generatedAt` for metadata that records a generation time.
- The `Software` setting in AUTOMATIC1111-compatible text names the producer.
- `MochiNativeCodec` reads and writes Mochi Diffusion's versioned native record
  as JSON and as an XMP packet. `MochiGenerationSnapshot` holds its values.
- `A1111ParametersEncoder` writes AUTOMATIC1111-compatible text and reports
  every value it leaves out. It writes no text when readers would misread it.
  Named LoRAs are appended to the prompt line as `<lora:name:weight>` tags.
- `MetadataFormat.mochiDiffusion` for native records found during inspection.
- `PNGMetadataWriter` inserts or replaces the `parameters` chunk and the native
  XMP chunk, and copies all other chunks and pixel data exactly.

## 0.1.1 - 2026-09-22

### Fixed

- Treat PNG pixel and unrelated chunk payloads as opaque during metadata
  inspection, avoiding size-dependent CRC work.

## 0.1.0 - 2026-09-05

### Added

- `GenerationSelection`, through `MetadataInspection.selection`, names the
  generation an image most likely records or reports ambiguity.
- AUTOMATIC1111 text is read as the WebUI reads it: sparse settings lines,
  unquoted values, empty prompts, ordered unrecognized settings, reported
  invalid or conflicting values, and `<lora:>` tags as resources.
- Limits on decompressed bytes, payload count, JSON and XML nesting, ComfyUI
  graph size and Exif directories. XML document type declarations are rejected.
- JSON seeds up to 64 bits are exact, and larger ones are left out instead of
  rounded.
- `MetadataInspector.interpret(_:)` and the native decoders apply the same
  payload and size limits as `inspect`.
- The ComfyUI model and size follow the sampler's own links. Several different
  candidates leave a field unset with a diagnostic instead of the first by
  node ID.

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
