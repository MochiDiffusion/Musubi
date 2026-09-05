# Ecosystem research

Research snapshot: 2026-09-04. This is historical design context rather than a
current compatibility promise.

## Conclusion

This is a reasonable library to build if native Swift, exact Draw Things
support, and metadata-only rewrites are important requirements.

There are good implementations to learn from, especially in TypeScript, but no
mature Swift package was found that covers Draw Things, ComfyUI, and Civitai.
The closest general library still calls its Draw Things support experimental
and does not have real Draw Things fixtures. A small amount of Swift application
code exists, but not at the quality or packaging level needed for a reusable
dependency.

The recommended approach is therefore:

1. Build a focused Swift package.
2. Use the current Civitai and `sd-metadata` packages as behavioral references
   and development-time compatibility oracles.
3. Build the project's own legally clean fixture corpus, especially for Draw
   Things.
4. Preserve source payloads instead of pretending every ecosystem maps
   losslessly to one flat schema.

## Existing libraries

### Strong references

| Project | What it covers | Important limitation | Recommended use here |
| --- | --- | --- | --- |
| [`@enslo/sd-metadata`](https://github.com/enslo/sd-metadata) | MIT TypeScript library; read/write for PNG, JPEG, and WebP; 18+ tools; raw preservation; C2PA detection | Draw Things is explicitly experimental and unverified with real samples. Civitai PNG/WebP are also marked experimental. A JavaScript runtime is undesirable in the target Mac apps. | Broad architectural reference, parser oracle, and possible upstream fixture collaboration |
| [`@civitai/generation-metadata`](https://github.com/civitai/media-metadata) | MIT TypeScript package extracted from Civitai's application behavior; reads A1111, ComfyUI, SwarmUI, RuinedFooocus, and Civitai variants; preserves raw data; writes PNG/JPEG | Very new at this snapshot (`0.1.0`), narrower than this project, and has no Draw Things support | Primary oracle for Civitai ingest behavior and AIR/resource normalization |
| [`stable-diffusion-prompt-reader`](https://github.com/receyuki/stable-diffusion-prompt-reader) | MIT Python tool supporting A1111, ComfyUI, Draw Things, and several others | Older; writing is A1111-only; its documentation acknowledges that complex/custom ComfyUI graphs may not parse correctly | Historical behavior and sample-format reference |
| [`sd-parsers`](https://github.com/d3x-at/sd-parsers) | MIT Python, structured read-only parsing for A1111, ComfyUI, Fooocus, InvokeAI, and NovelAI | No Draw Things; custom ComfyUI node coverage is necessarily incomplete | Reference for representing multiple prompts, models, and samplers |

`@enslo/sd-metadata` is the closest off-the-shelf solution in terms of product
scope. If this were a web or Node application, trying it first would be the
obvious choice. For a native Swift package, wrapping it introduces a JavaScript
runtime and still leaves the most important source, Draw Things, at experimental
quality. Porting selected ideas and validating behavior against it is a better
fit than taking it as a runtime dependency.

The Civitai package is particularly valuable because the current Civitai app
uses it and its parsers are backed by a corpus of real images. It distinguishes
verbatim parsed metadata from an opinionated normalized view, supports
`Civitai resources:` and `Civitai metadata:` blocks, resolves AIR identifiers,
and preserves ComfyUI `prompt` and `workflow` payloads. That design is close to
what Musubi needs, even though the public API should be idiomatic Swift.

### Useful but not dependency candidates

| Project | Observation |
| --- | --- |
| [`draw-things-community`](https://github.com/drawthingsai/draw-things-community) | The official public Draw Things repository is the best upstream source for configuration data models and enums. It does not currently expose the complete app or a public metadata-format contract, so exported files remain essential evidence. |
| [`DrawThingsStudio`](https://github.com/IngoDuesentrieb/DrawThingsStudio) | Contains a Swift PNG metadata parser for Draw Things, A1111, and ComfyUI. It is application code rather than a package and uses simplified parsing and ComfyUI selection heuristics. It proves the basic native approach is practical, but is not a robust foundation. |
| [`drawthings-py`](https://github.com/kcjerrell/drawthings-py) | Its PNG writer documents the current Draw Things-shaped XMP packet and the large `v2` configuration object. It is GPL-3.0; use it as supporting evidence while keeping Musubi's implementation independently fixture-led. |
| [`comfyui-cyberdelia-metadata`](https://github.com/cyberdeliaAI/comfyui-cyberdelia-metadata) | A current GPL-3.0 ComfyUI save-node implementation aimed at Civitai-compatible metadata across complicated workflows and custom nodes. Useful for test scenarios and behavioral comparison. |
| [`civitai-metadata-studio`](https://github.com/chriscollins500/civitai-metadata-studio) | Browser tool for inspecting and repairing Civitai metadata. Its focus on payload preservation, AIR/hash ordering, and graph-aware ComfyUI extraction is useful design evidence. |

## What the formats actually look like

### Containers are separate from generator formats

The library needs two distinct layers:

- The image container says where and how bytes are embedded.
- The generator codec says what those bytes mean.

For PNG, generation data appears in combinations of `tEXt`, `zTXt`, `iTXt`,
`eXIf`, and XMP. The [PNG specification](https://www.w3.org/TR/png-3/)
requires different encodings for these chunks, permits multiple text chunks,
and defines CRC and ordering behavior. In particular, a parser must not reduce
chunks to a dictionary and silently lose duplicate keywords.

[XMP](https://developer.adobe.com/xmp/docs/xmp-specifications/) is a data model
and XML/RDF serialization with defined rules for embedding it in common file
formats. Apple's
[`CGImageMetadata`](https://developer.apple.com/documentation/imageio/cgimagemetadata)
can help interpret XMP, although low-level container rewriting should not rely
on an image re-encode.

Exif `UserComment` is one of the places generator payloads are hidden, but that
does not make the proposed library a general Exif library. The current
[CIPA standards page](https://www.cipa.jp/e/std/std-sec.html) is the reference
for the Exif specification and tag semantics.

### Draw Things

Observed Draw Things PNGs use an XMP packet in an `iTXt` chunk whose keyword is
`XML:com.adobe.xmp`. The packet identifies `Draw Things` as the creator tool and
stores a compact JSON configuration in XMP's Exif `UserComment` property. A
human-readable description may also be present.

The JSON commonly has a small compatibility surface such as:

- `c` and `uc` for positive and negative prompts
- model, sampler, scale, seed, steps, strength, and size
- a much richer `v2` object containing LoRAs, controls, seed mode, clip skip,
  high-resolution/refiner settings, model-specific guidance, tiling, and other
  configuration

There does not appear to be a formal, versioned public specification. That
makes actual files from known Draw Things releases the source of truth. The
`drawthings-py` writer is supporting evidence, not a substitute for fixtures
produced by the real application.

### ComfyUI

The default ComfyUI PNG save path writes JSON into a `prompt` text chunk and
writes entries from `extra_pnginfo`, normally including `workflow`, into
additional text chunks. The authoritative implementation is the current
[`SaveImage` node](https://github.com/Comfy-Org/ComfyUI/blob/master/nodes.py),
and ComfyUI publishes a formal
[`workflow` JSON schema](https://docs.comfy.org/specs/workflow_json).

These two JSON objects serve different purposes:

- `prompt` is the API/execution graph. Its nodes are keyed by ID and contain
  `class_type` and resolved inputs. It is generally the better extraction
  source.
- `workflow` is the UI graph used to reconstruct the editable canvas.

A correct parser cannot assume that the first text node is positive, the
second is negative, or the last sampler is the one that produced the image.
It should identify output nodes and walk their upstream dependencies. Multiple
output branches, multiple sampling stages, custom nodes, and dynamically
resolved values mean normalization can be partial or ambiguous. The original
graphs must always survive even when extraction is incomplete.

ComfyUI's built-in and extension save nodes also produce JPEG/WebP variants
using Exif fields or custom layouts. These should be fixture-driven additions,
not assumptions extrapolated from PNG.

### Civitai

There is no single “Civitai file format.” At least three related things exist:

1. A1111-style `parameters` text that Civitai recognizes on upload.
2. Civitai extensions to that details line, notably `Civitai resources:` and
   `Civitai metadata:` JSON blocks, plus AIR identifiers.
3. On-site and ComfyUI-shaped payloads emitted by Civitai itself.

The [Civitai Images API](https://github.com/civitai/civitai-developer-docs/blob/main/site/reference/images.md)
also exposes a free-form `meta` object. That API object is related to the file
metadata but should not be mistaken for a normative embedded-file schema.
Civitai's
[image resource documentation](https://github.com/civitai/civitai/blob/main/docs/features/image-resources.md)
describes automatic resource detection, while
[model version documentation](https://github.com/civitai/civitai-developer-docs/blob/main/site/reference/model-versions.md)
documents AIR identifiers and model hashes.

Musubi should therefore name its goal “Civitai ingest compatibility,” not
“the Civitai format.” Automatic1111 details-line reading belongs in the initial
release; writing belongs in the first compatibility-writing milestone.

One file can legitimately contain a ComfyUI graph and an A1111/Civitai
compatibility payload. Detection must not select one and throw the other away.

## Future commercial generators

OpenAI and Google metadata is a different category from diffusion settings.
OpenAI currently says generated images contain
[C2PA Content Credentials and SynthID](https://help.openai.com/en/articles/8912793-c2pa-in-images).
Google describes [SynthID](https://deepmind.google/models/synthid/) as an
imperceptible signal embedded in the generated media itself. Neither should be
expected to reveal a reusable prompt, seed, CFG, or model configuration.

C2PA is a signed provenance system with its own trust and validation model; see
the [C2PA specification](https://spec.c2pa.org/post/contentcredentials/). It
should be an optional provenance module or a separate dependency. Merely
finding a C2PA box is useful for an image viewer, but must be reported as
unverified unless signatures and trust chains are actually validated.

## Licensing note

Musubi is licensed under GPLv3. Some behavioral references above are MIT and
some are GPL-3.0, but the implementation should remain fixture-led rather than
copied from any one project. This keeps code provenance clear and makes observed
wire behavior, not another parser's assumptions, the compatibility contract.
