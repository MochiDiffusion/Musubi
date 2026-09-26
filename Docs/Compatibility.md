# Compatibility and testing

Generation metadata formats are evolving conventions rather than one common
standard. The tables below describe Musubi 0.1's tested behavior, not universal
support for every image an application can produce.

## Container support

| Container | Read carriers | Write |
| --- | --- | :---: |
| PNG | `tEXt`, `zTXt`, compressed and uncompressed `iTXt`, `eXIf`, XMP | — |
| JPEG | APP1 Exif, APP1 XMP, COM segments | — |
| WebP | — | — |
| HEIC | — | — |

PNG CRC failures are reported as diagnostics when the payload remains readable.
Malformed lengths, truncated containers, excessive metadata, and invalid zlib
streams fail safely.

## Codec behavior

### Draw Things

Musubi recognizes Draw Things XMP and its JSON `UserComment`. It extracts the
common top-level configuration and known model, size, and resource values from
the `v2` object. The complete XMP carrier remains available when unknown keys
are present.

### ComfyUI

Musubi preserves `prompt` execution graphs and `workflow` UI graphs separately.
It follows links through common core sampler, conditioning, model-loader, LoRA,
latent, and text nodes. It can return several generation records for several
samplers.

Custom nodes, dynamic values, and complicated output association can result in
partial records. Musubi does not guess that the first text node is positive or
that the last sampler produced the displayed image.

### Automatic1111 and Civitai

Musubi parses A1111-compatible `parameters` text as an open-ended settings line
and recognizes Civitai resource and metadata JSON fields. The producer comes
from a `Software` setting. Without one, Civitai is the producer only when the
text has a `Civitai metadata` field or the image has an Exif Artist of `ai`.
Other applications also write `Civitai resources`, so that field does not
identify the producer.

A `Model hash` of 8, 10 or 64 hexadecimal digits is labeled as AUTOMATIC1111's
original short hash, its current short hash, or a full SHA-256. A hash of any
other length keeps no algorithm. A Civitai `textualinversion` or `embedding`
resource is an embedding, not a text encoder.

There is no single Civitai file format. Musubi 0.1 targets the embedded layouts
observed in Civitai-produced files and compatibility payloads that Civitai
commonly ingests.

### Mochi Diffusion legacy

Musubi recognizes the released v2.2-and-later semicolon-delimited caption in
PNG and JPEG XMP. The legacy format cannot escape every possible prompt or
filename, so parsing is necessarily best-effort and the raw XMP is preserved.
The caption's `Scheduler` names a sampling method, so Musubi reports it as the
sampler.

## Test strategy

Committed tests build tiny synthetic PNG and JPEG containers in memory. They
cover:

- Draw Things XMP and LoRA extraction
- core and advanced ComfyUI graph traversal
- Civitai UTF-16 Exif and resource extraction
- Mochi legacy PNG and JPEG XMP
- ordinary metadata that must not be attributed to a generator
- readable PNG metadata with a bad CRC

Private reference images in `example images/` are ignored by Git and used only
for exploratory manual checks. Their prompts, filenames, and pixels must not
appear in a public fixture corpus without explicit permission.

Future public fixtures should be tiny, neutral, redistributable, and paired
with hand-reviewed expected results. Exact producing-app versions are useful
but are not required for the initial proof-of-concept release.

## Important 0.1 limitations

- no metadata writing
- no preferred interpretation when several are present
- no complete mapping of arbitrary ComfyUI custom nodes
- JSON integer literals larger than `Int64` may lose their original spelling in
  normalized fields; their raw payload remains intact
- no general Exif/IPTC API
- no pixel decoding or image validation beyond the scanned structures
- no WebP, HEIC, C2PA, or SynthID support
- no promise that unknown source data can yet be round-tripped into a new file
