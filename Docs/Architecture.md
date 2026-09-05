# Architecture and roadmap

## Scope

Musubi separates image containers from generation-metadata dialects. A PNG text
chunk and a JPEG Exif value are physical carriers; Draw Things, ComfyUI, and
A1111/Civitai are codecs that interpret their contents.

The package is intended to:

- locate generation metadata without decoding pixels
- preserve every relevant payload in file order
- provide typed common fields for galleries and inspector interfaces
- represent more than one source or generation when an image contains them
- eventually add compatibility payloads without damaging native metadata

It is not a general Exif editor, image decoder, archive reader, Civitai API
client, or C2PA validator.

## Read pipeline

```text
Encoded image bytes
        │
        ▼
Container scanner ──► ordered payload bytes + image dimensions
        │
        ▼
Source codecs ──────► zero or more source interpretations
        │
        ▼
Generation records ► common fields for application use
```

`MetadataInspection` intentionally exposes the raw and normalized layers. A
ComfyUI graph can describe several samplers or outputs, and a file can contain
both its native graph and an A1111-compatible payload intended for Civitai.
Returning an array avoids forcing either case into a fictional single record.

Normalization is best-effort. Dynamic values and unknown ComfyUI nodes remain
available in their original graphs even when Musubi cannot confidently project
them into common fields.

## Public model

- `MetadataInspector` scans encoded `Data` or a file URL.
- `MetadataInspection` contains the container, dimensions, ordered payloads,
  interpretations, and non-fatal diagnostics.
- `EmbeddedMetadataPayload` preserves carrier bytes and decoded text when
  available.
- `MetadataInterpretation` attributes one or more payloads to a source.
- `GenerationRecord` contains common fields for one generation operation.
- `GenerationResource` keeps independent names, hashes, AIR identifiers, and
  Civitai version IDs instead of manufacturing identity.

Seeds are exposed as text so clients do not have to choose a numeric width.
Source text and JSON integers through `Int64` remain exact; preserving larger
JSON numeric literals without conversion is a post-0.1 parser improvement.

## Safety model

Image metadata is untrusted. Container readers use checked offsets, reject
truncated structures, cap total metadata reads, and cap decompressed text.
Malformed individual text payloads can produce diagnostics while valid
payloads remain available. Fatal container corruption throws a
`MetadataInspectionError`.

Future work should add explicit limits for JSON/XML depth and ComfyUI graph
size before claiming hardened processing of arbitrary internet downloads.

## Writing design

Writing is deliberately excluded from 0.1. The intended design has three
separate concerns:

1. A `GenerationRecord` describes effective values used for one output image.
2. An encoding profile creates only the payload it owns, such as an
   A1111/Civitai-compatible `parameters` value.
3. A container rewriter inserts or replaces that payload while copying encoded
   pixels and unrelated metadata byte-for-byte.

Conceptually:

```swift
let request = MetadataWriteRequest(
    generation: generation,
    profiles: [.civitaiCompatible],
    existingPayloads: .preserveUnowned
)

let result = try MetadataWriter.rewrite(encodedImageData, using: request)
```

The concrete API should remain synchronous and `Sendable`, accept and return
`Data`, report lossy omissions, and never overwrite a source file implicitly.

### Mochi integration seam

Mochi should construct a Musubi record from effective per-image generation
metadata after its generator has resolved pipeline defaults. Musubi should not
accept Mochi's UI request or duplicate its capability model.

```text
effective generation metadata + CGImage
                 │
                 ▼
        ImageIO pixel encoding
                 │
                 ▼
       Musubi metadata rewriting
                 │
                 ▼
          final encoded image
```

The classic Mochi v2.2-and-later caption remains a separate legacy read codec.
Its semicolon-delimited values are ambiguous and omit some settings, so the raw
caption must remain available. A future Mochi format should be added as a new
codec rather than changing the legacy grammar.

## Roadmap

### 0.1 — read-only inspection

- PNG and JPEG container scanning
- Draw Things, ComfyUI, A1111/Civitai, and Mochi legacy decoding
- raw payload preservation and typed common fields
- development CLI and synthetic tests

### 0.2 — hardening and normalization

- parser limits for JSON, XML, and graph traversal
- better ambiguity diagnostics and preferred-result policy
- broader container and codec edge-case tests
- small redistributable real-world fixture corpus when available

### 0.3 — PNG compatibility writing

- lossless PNG chunk rewriting
- A1111/Civitai-compatible payload encoding
- unchanged `IDAT` and foreign-payload assertions
- parser-oracle and manual Civitai upload verification

### Later

- JPEG writing
- WebP reading and writing
- HEIC support appropriate for Mochi
- the future Mochi metadata codec
- additional generators driven by obtainable fixtures
- optional provenance detection or validated C2PA integration
