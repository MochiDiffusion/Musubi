# Architecture and roadmap

## Scope

Musubi separates image containers from generation-metadata dialects. A PNG text
chunk and a JPEG Exif value are physical carriers; Draw Things, ComfyUI, and
A1111/Civitai are codecs that interpret their contents.

The package is intended to:

- locate generation metadata without decoding pixels
- keep the exact bytes of every payload it reads, in file order
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

- `MetadataInspector` scans encoded `Data` or a file URL. Its `interpret`
  function runs the same codecs on payloads that another framework extracted.
- `MetadataInspection` contains the container, dimensions, ordered payloads,
  interpretations, and non-fatal diagnostics.
- `EmbeddedMetadataPayload` preserves carrier bytes and decoded text when
  available.
- `MetadataInterpretation` attributes one or more payloads to a metadata
  format. Its producer is the application that the metadata names as its
  writer, or `nil` when it names none. The format alone does not identify the
  producer: many applications write AUTOMATIC1111-compatible text.
- `GenerationRecord` contains common fields for one generation operation.
  Settings with no common field stay in `parameters`, in source order.
- `GenerationSelection` names the generation an image most likely records, or
  reports that several are equally plausible. It never merges records.
- `GenerationResource` keeps independent names, hashes, AIR identifiers, and
  Civitai version IDs instead of manufacturing identity. Each hash records its
  algorithm when the source identifies it. Resource kinds are open strings, so
  an unrecognized source spelling is kept.

Seeds are exposed as text so clients do not have to choose a numeric width.
Source text and JSON integers through `Int64` remain exact; preserving larger
JSON numeric literals without conversion is a post-0.1 parser improvement.

## Safety model

Image metadata is untrusted. Container readers use checked offsets and reject
truncated structures. `InputLimits` bounds everything that grows with the
input: metadata bytes per container, decompressed bytes across all compressed
payloads, the payload count, JSON and XML nesting, ComfyUI graph size, and
nested Exif directories. Exif text copies cannot exceed the size of their
block. JSON and XML nesting is checked before any recursive decoding, and XML
with a document type declaration is rejected, which rules out entity
expansion.

A payload that is malformed or over a limit produces a diagnostic, and valid
payloads and interpretations beside it remain available. Fatal container
corruption throws a `MetadataInspectionError`.

## Writing design

The [metadata wire contract](MetadataWireContract.md) records the carriers,
encodings, limits and ownership rules for Mochi's output, backed by executable
carrier and external-reader probes.

`MochiNativeCodec` writes Mochi's native record as JSON and as an XMP packet.
`A1111ParametersEncoder` writes AUTOMATIC1111-compatible text and lists every
value it leaves out. Both take the same `MochiGenerationSnapshot`, so the two
payloads cannot disagree. The XMP packet may also carry the AUTOMATIC1111 text
as `dc:description`, which Spotlight imports as the file's description for
Finder and search. `PNGMetadataWriter` places them in a PNG. It owns only the
`parameters` chunk and an XMP chunk that holds the native record and at most
that description. It copies every other chunk and the pixel data byte for
byte, refuses to overwrite foreign XMP, and replaces an existing record only
when the caller asks. Writing is synchronous, accepts and returns `Data`, and
never touches a file.

### Mochi integration seam

Mochi constructs a snapshot from the effective per-image generation values
after its engine has resolved pipeline defaults. Musubi does not accept Mochi's
UI request or duplicate its capability model.

```text
effective generation values + CGImage
                 │
                 ▼
        ImageIO pixel encoding (Mochi)
                 │
                 ▼
       PNGMetadataWriter (Musubi)
                 │
                 ▼
          final encoded image
```

Mochi's released IPTC captions remain a separate legacy read codec. The v2.2
through v6.0 caption joins fields with semicolons, and the v6.1 through v6.1.2
caption declares `Metadata Version: 2` and writes one escaped field per line.
The semicolon-delimited values are ambiguous and both omit some settings, so
the raw caption must remain available. The native record is its own codec, and
the legacy grammar does not change.

## Roadmap

Reading, parser hardening and PNG writing for Mochi Diffusion are implemented;
the changelog lists them. Candidates for later work:

- JPEG writing
- WebP reading and writing
- HEIC container reading; Mochi reads HEIC through ImageIO and
  `MetadataInspector.interpret(_:)`
- a small redistributable real-world fixture corpus
- additional generators driven by obtainable fixtures
- optional provenance detection or validated C2PA integration
