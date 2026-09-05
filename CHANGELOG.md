# Changelog

Musubi follows [Semantic Versioning](https://semver.org/). Changes before 1.0
may include source-breaking API refinements and will be called out here.

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

