# Mochi metadata wire contract

Decision for **MochiDiffusion-e4v.6**, verified 2026-09-10. This specifies the
next implementation; Musubi's public API is still read-only. The executable
evidence is in [the wire probe](../Tools/MetadataWireProbe/README.md).

## Decision

Write a compact, versioned Mochi JSON snapshot in XMP and a separate
AUTOMATIC1111 infotext projection. Both originate from one per-output record.
The native snapshot preserves exact prompts, absence, engine identity and
settings with no portable equivalent. Infotext provides upload compatibility;
it is not a lossless serialization or proof of which application generated an
image.

Mochi writes PNG only. Use ImageIO for pixels and a focused chunk writer for
the PNG native XMP and parameters. Mochi reads released JPEG and HEIC images and
converts them to PNG on export. Do not build a custom HEIF parser or general
Exif editor.

The JPEG carriers below were verified but have no writer. If JPEG output is
added, it needs a narrow Exif writer for newly encoded images: ImageIO's
ordinary UserComment path corrupts Unicode in the tested environment.

## Exact carriers

| Container | Native snapshot | AUTOMATIC1111 projection |
| --- | --- | --- |
| PNG | XMP in `iTXt`, keyword `XML:com.adobe.xmp` | Uncompressed UTF-8 `iTXt`, keyword `parameters` |
| JPEG | Standard APP1 XMP, identifier `http://ns.adobe.com/xap/1.0/\0` | APP1 `Exif\0\0`, Exif IFD tag `0x9286` (UserComment), type UNDEFINED |
| HEIC | XMP through ImageIO | No compatibility claim. Export converts to PNG. |

The native property is the **simple string** `Generation` in the namespace
`https://github.com/MochiDiffusion/MochiDiffusion/ns/metadata/1.0/`, conventionally
written `mochi:Generation`. A reader matches namespace URI and local name, not
the prefix spelling. The URI identifies a vocabulary; it is not fetched.
The string contains UTF-8 JSON, with normal JSON escaping inside the XMP XML
encoding. Do not put JSON in the legacy caption, in `exif:UserComment`, or in
an unversioned serialization of a public Swift type.

The same packet may set `dc:description` to the AUTOMATIC1111 text, as an
`x-default` language alternative. Spotlight imports it as `kMDItemDescription`,
so Finder's Get Info shows it and Spotlight search matches the prompt. It
repeats the record for people and is never read back as generation metadata.
It is omitted when it holds a character XML cannot carry or would push the
packet over the size limit; the record itself is never dropped for it.

For PNG parameters, compression flag and method are zero; language tag and
translated keyword are empty. Use UTF-8 even for ASCII text, allowing one
predictable carrier. The existing reader still accepts tEXt/zTXt variants.

For new JPEG UserComment, use `UNICODE\0` followed by UTF-16BE, without a BOM or
trailing terminator. Use a big-endian TIFF header and a real Exif IFD pointer
from IFD0. UserComment in IFD0 alone is insufficient for A1111's reader. Both
external readers and Musubi recover the tested BMP and surrogate-pair text.

## Native version 1

The root is an object with `format: "mochi-diffusion"`, integer `version: 1`,
`producer` and `generation` objects, and an optional `mochi` object. Reject
duplicate JSON object keys and invalid types. Unknown additional keys can be
ignored for interpretation while the original payload remains available.

`producer.application` is the emitting application name; `producer.version` is
its version string. Neither is the metadata version or the engine. Exporting
a foreign image does not make Mochi its original producer.

`generation` uses the following keys. Omit unknown or unsupported values;
do not write null, NaN or infinity. Empty strings and arrays are distinct
from omission. Positive dimensions and step counts are integers, finite real
settings are JSON numbers, and **seeds are decimal strings**.

| Keys | Wire value and meaning |
| --- | --- |
| `prompt`, `negativePrompt` | Exact text associated with the output |
| `submittedPrompt` | Original submission when an engine reports a different effective prompt |
| `model` | Known model name, not an inferred checkpoint identity |
| `sampler`, `scheduler` | Independent opaque names; map to known engine options only at use |
| `steps`, `cfgScale`, `denoise` | Applicable step count, classifier-free guidance and denoising strength |
| `seed` | Exact decimal spelling; no fixed-width conversion in the codec |
| `width`, `height` | Generation/output dimensions, separate from later container dimensions |
| `generatedAt` | UTC RFC 3339 timestamp, optional fractional seconds; not filesystem modification time |
| `resources` | Ordered resource objects, described below |

A resource has a string `kind` and optional `name`, finite `weight`, `hashes`,
`air`, and decimal-string `civitaiModelVersionID`. Initial kinds are
`checkpoint`, `lora`, `vae`, `textEncoder`, `embedding`, `upscaler`, `control`,
and `other`. Preserve unknown kind spellings as source data. Each hash has
string `algorithm` and `value`; distinguish full `sha256` from
`a1111-auto-v1` and `a1111-auto-v2`. A hash of a converted directory does not
identify its original checkpoint. Names, hashes and Civitai IDs are independent
evidence, not interchangeable lookup keys. No network lookup is part of coding.

`mochi` contains only current app-specific generation details: optional string
`engine`, `modelKey`, `quality`, `computeUnit`, `startingImage`, `controlNetImage`;
ordered string array `inputImages`; and ordered `parameters`, each an object
with string `key` and `value`. Parameters retain known engine settings without
making every engine's configuration a common public field. Input images are
basenames; never include connection secrets or absolute paths. Additional
optional keys can be introduced without changing existing meanings. Incompatible
grammar or semantic changes require a new version.

`MochiNativeCodec` and `A1111ParametersEncoder` implement this contract. The
probe's fixtures for Mochi output come from them, so the external readers check
their actual output. Each engine's field mapping belongs to Mochi. A metadata
snapshot does not make an opaque engine reproducible.

## Portable projection and known losses

Write prompt lines, optional `Negative prompt:`, then one final settings line.
For diffusion records, start the latter with `Steps: `. Include all meaningful
known conventional settings and tested resource extensions; omissions must be
accounted for in the engine mapping. Quote scalar settings with JSON string
escaping when punctuation or whitespace would affect parsing. Keep numbers
locale-independent. Never invent steps, CFG, a sampler, seed or identity.
Write the producer as `Software: <name> <version>`. Do not use `Version`,
which names the WebUI version.

The pinned-reader probes establish these boundaries:

| Fixture, in both PNG and JPEG | AUTOMATIC1111 | Civitai reader |
| --- | --- | --- |
| Diffusion, seed 4294967296, denoise 0.42 | Common fields retained | Common fields retained |
| Unicode/multiline prompt and quoted model | Retained with the chosen carriers | Retained with the chosen carriers |
| Hosted, only Model/Size/Software | Settings parsed; no invented Steps/Seed/CFG | Not recognized |
| Only Model/Size | Settings line becomes prompt text | Not recognized |
| Positive prompt containing Negative prompt/Steps lines | Prompt split; final real Steps retained | Prompt split; earlier false Steps selected |
| Hashes and Civitai resource extension | Standard fields and quoted LoRA hash retained | Hashes, synthetic version ID and weight extracted |

A1111 requires at least three recognizable pairs on its final details line.
Civitai's detector requires `Steps: ` and selects a Steps-prefixed line. Genuine
Model/Size/Software values can help A1111 read sparse hosted output, but cannot
make the tested Civitai detector recognize it. Do not add dummy Steps or misleading
markers. Report sparse output as limited compatibility, retaining native fidelity.

Infotext has no generally interoperable escaping for prompt section markers.
For a marker collision that would attribute false settings, the production
encoder must return a projection diagnostic and omit the unsafe compatibility
payload rather than knowingly publish wrong settings. Exact text remains native.
Other documented whitespace normalization is a lossy projection. An empty prompt
must remain explicitly empty natively. The compatibility text appends a
`<lora:name:weight>` tag to the prompt line for each named LoRA, the form the
WebUI writes. With the tag, the tested Civitai reader joins the LoRA's name,
weight, hash and version ID into one resource. The native prompt never
contains these tags.

The resource fixture's hashes and ID are synthetic. Tests verify extraction,
not existence or a real model association. Civitai can keep the same resource
as separate hash-based and ID-based entries; parsing all identifiers does not
prove deduplication or website resource matching. A1111 does not interpret raw
Civitai JSON as structured resources. Do not claim it does.

## Ownership, limits and errors

- A new Mochi output owns its native property and its compatibility payload.
  For PNG, replacing `parameters` includes tEXt/zTXt/iTXt representations; remove
  stale owned duplicates while preserving all unowned chunks and IDAT bytes.
- Owning `mochi:Generation` does not confer ownership of an entire foreign XMP
  packet. Preserve unrelated properties or reject an unsupported edit. Never
  reduce ordered duplicate payloads to a dictionary before applying ownership.
- No JPEG writer exists. If one is added, limit it to fresh pixel output.
  Rebuild that output's Exif with the Unicode comment and known image
  properties. Keep its XMP, other application segments and scan bytes. Do not replace arbitrary foreign
  Exif, discard its MakerNotes, or append a competing Exif segment.
- An unchanged same-format export copies original bytes. Format conversion
  preserves supported generation information and original attribution; it does
  not promise preservation of every foreign tag. General metadata repair is deferred.
- Limit the serialized native XMP packet to **60 KiB**, including XML escaping
  and packet overhead, in this initial writing contract. Check the final emitted
  carrier too. This fits ordinary JPEG APP1 XMP without extended-XMP machinery.
  The probe also verifies a long JSON prompt containing CRLF and NUL escapes.
- Limit PNG compatibility text to **1 MiB UTF-8**. For JPEG, check the actual
  complete APP1 length, including its two length bytes, against **65,535**.
  The probe's minimal TIFF fits 32,725 UTF-16 code units; the next unit is rejected.
  Production must calculate this from its actual Exif layout, not reuse that count
  as a universal character limit. Surrogate pairs consume two units.
- Native overflow/serialization failure fails the save before replacing any
  destination. Compatibility overflow or unrepresentable text yields an explicit
  omission diagnostic; saving a native-only image must never report full portable
  compatibility. Do not truncate prompts or silently drop required native data.
  Embedded NUL in infotext is unrepresentable; it stays escaped in native JSON.

Reader limits, XML entity and depth handling, and malformed-payload isolation
are described under Limits in [Compatibility](Compatibility.md). The probe's
small helpers only operate on synthetic ImageIO output and are not production
container editors.

## Selection and compatibility

Prefer one valid, supported native record for a new dual-written Mochi image.
An unsupported version or malformed native payload cannot hide a valid
compatibility interpretation. Conflicts stay inspectable; do not fill missing
native values from a different interpretation. Multiple unrelated records or
unresolved ComfyUI stages remain ambiguous. This is interpretation policy,
not verification of provenance or an assertion that embedded data is truthful.

Continue reading released Mochi's captions: the semicolon caption of 2.2
through 6.0 and the line caption of 6.1 through 6.1.2. No legacy transition
payload is written, and old Mochi reading the new native format is not required.
This does not rewrite existing files.

Reproducing the released writer, including its program-name/version tags,
produces PNG/JPEG files that Musubi reads directly. A separate caption-only
variation produces a JPEG without the XMP carrier Musubi expects. ImageIO can
expose that caption as XMP for the library codec. This variation is a robustness
probe, not evidence that the released writer routinely loses metadata.
Use the narrow ImageIO-to-payload fallback for HEIC and for legacy captions that
direct inspection misses. All caption grammar stays in Musubi. Direct and bridged
results for both variants are recorded separately in `legacy-results.json`.

## Evidence

The recorded environment is macOS 27 beta, Xcode beta / Swift 6.4. Tests verify
decodable synthetic images, exact native XMP through ImageIO and Musubi's PNG/JPEG
payload scanning, legacy library-codec bridging, and encoded-size limits. Re-run
on supported release macOS before declaring cross-version ImageIO behavior proven.

External evidence uses A1111 commit
`82a973c04367123ae98bd9abdf80d9eda9b910e2` (downloaded source SHA-256 checked),
Pillow 11.3.0, piexif 1.1.3, and the published
`@civitai/generation-metadata` 0.1.0 with a locked dependency graph. The latter
is pinned by npm integrity, not asserted to equal a particular GitHub revision.
Each fixture's `.expected.json` states what both readers must parse, so the same
readers check any fixture directory.

Mochi Diffusion writes its own fixtures through its generation and export
paths: Core ML text-to-image, image-to-image with ControlNet and SD3; Iris with
reference images; a sparse hosted record; a Unicode prompt; a prompt with
section markers; and released 6.0 JPEG, 6.1.2 HEIC and foreign JPEG images
converted to PNG. Its `scripts/external_readers.sh` runs these readers against
them. The results match the table above: complete records are read by both, the
hosted record only by A1111, and the marker prompt carries no compatibility
text. Mochi records a model by name only, so the Civitai reader identifies a
checkpoint without a hash.

A live upload was checked once, on 2026-09-28, with Core ML and Iris PNGs from
Mochi Diffusion's development build at commit `2bbbed9`. Civitai's upload
preview filled in the prompt, negative prompt, steps, CFG scale, sampler and
seed. It did not identify the model, as expected for a name without a hash;
a hash of a converted Core ML directory would not identify the original
checkpoint either. Nothing was published, and no resource lookup was run.

ImageIO stays outside Musubi's core target. The probe adds no runtime
dependency or production writer to either application.
