# Compatibility and testing

Generation metadata formats are evolving conventions rather than one common
standard. The tables below describe Musubi 0.1's tested behavior, not universal
support for every image an application can produce.

## Container support

| Container | Read carriers | Write |
| --- | --- | :---: |
| PNG | `tEXt`, `zTXt`, compressed and uncompressed `iTXt`, `eXIf`, XMP | `parameters` and native XMP |
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

The model comes from the sampler's `model` link. The size comes from its
`latent_image` link: the nearest node that sets a width and height, passing
only through other samplers. A scale-by upscale or an encoded image stops the
walk, so no size is reported. When the nodes on a link give several different
values, such as two merged checkpoints, the field stays unset with a
diagnostic. Node IDs carry no meaning, so they never decide between values.

### Automatic1111 and Civitai

Musubi reads A1111-compatible text the way the WebUI does. The last line is
the settings line when it has at least three settings, one of them a common
generation setting. Text in a `UserComment` or JPEG comment also needs `Steps`,
so an ordinary photo comment is not mistaken for generation data. Text in a
`parameters` chunk without `Steps` is still read, so Musubi understands sparse
records that the Civitai reader rejects. Earlier lines are trimmed, and a line
that starts with `Negative prompt:` begins the negative prompt. The prompt is
always present, possibly empty.

Quoted values are unquoted as JSON strings. A value that starts with `[` or
`{` runs to its closing bracket, so JSON extensions keep their commas. A common
setting with an invalid value, such as `CFG scale: nan`, is reported and kept
as a parameter. A common setting that repeats with different values is left
out of the common fields and every value is kept. Other settings stay in order
as parameters.

Each `<lora:name>` or `<lora:name:weight>` tag in the prompt becomes a LoRA
resource, joined with its `Lora hashes` entry and with a Civitai LoRA of the
same name. The tags stay in the prompt, because there the user typed them.
Text that names Mochi Diffusion as its producer is the exception: its trailing
run of space-separated tags was added by `A1111ParametersEncoder`, so it is
removed from the prompt. A tag that is not preceded by a space stops the
removal.

Musubi recognizes Civitai resource and metadata JSON fields. The producer comes
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

### Choosing a generation

`MetadataInspection.selection` names one generation only when that involves no
guess. A single generation from a primary format, such as a Mochi native
record, a ComfyUI graph with one sampler, or Draw Things XMP, is selected even
when AUTOMATIC1111 text is also present, because that text is usually a copy
the same application added. Several primary generations, such as a graph with
two samplers or records from two applications, are ambiguous. Without a primary
format, one AUTOMATIC1111 generation is selected. Records are never merged, and
every interpretation stays available.

### Limits

Musubi reads at most 16 MiB of metadata per container and decompresses at most
32 MiB in total. It keeps the first 1,024 payloads, accepts 64 levels of JSON
or XML nesting and ComfyUI graphs of up to 4,096 nodes, and follows 4 levels of
nested Exif directories. JSON seeds are exact up to 64-bit integers. A larger
JSON seed is left out with a diagnostic instead of being rounded, and the raw
payload keeps its digits. Seeds in text formats are exact at any length.

### Mochi Diffusion native

Musubi reads the versioned native record from the `mochi:Generation` XMP
property, matched by namespace URI in element or attribute form. A record with
an unsupported version, a repeated JSON key or a wrong value type produces a
diagnostic and no interpretation, so a compatibility interpretation in the
same image stays readable. Mochi-specific details appear as parameters in the
normalized record. `MochiNativeCodec` also returns them as typed values.

### Mochi Diffusion legacy

Musubi recognizes both released Mochi captions in PNG and JPEG XMP. Versions
2.2 through 6.0 wrote a semicolon-delimited caption that cannot escape every
possible prompt or filename, so parsing it is necessarily best-effort. Versions
6.1 through 6.1.2 wrote `Metadata Version: 2` on the first line and then one
`Label: value` field per line, escaping backslash, line feed and carriage
return; `Input Images` repeats once per image and is reported as one
`Input Image` parameter each. A caption declaring any other version is not
read. The raw XMP is preserved in every case.
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

The metadata wire probe checks written images with pinned AUTOMATIC1111 and
Civitai readers. Its fixtures are tiny, neutral synthetic images, each paired
with hand-reviewed expectations; Mochi Diffusion writes its own fixtures the
same way. [Tools/MetadataWireProbe](../Tools/MetadataWireProbe/README.md)
describes how to run it, and the
[wire contract](MetadataWireContract.md#evidence) records the results.

## Important 0.1 limitations

- PNG writing only, and only of the `parameters` chunk and an XMP chunk that
  holds Mochi's native record and at most its `dc:description`
- no complete mapping of arbitrary ComfyUI custom nodes
- JSON integers beyond 64 bits are left out of normalized fields; their raw
  payload remains intact
- no general Exif/IPTC API
- no pixel decoding or image validation beyond the scanned structures
- no WebP, HEIC, C2PA, or SynthID support
- no promise that unknown source data can yet be round-tripped into a new file
