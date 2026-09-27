# Musubi

Musubi is a native Swift library for reading and normalizing image-generation
metadata written by different applications.

It scans encoded images without decoding their pixels, preserves the original
metadata payloads, and presents common generation details through typed Swift
models. An image can contain several valid metadata dialects, so Musubi returns
every interpretation instead of discarding all but one.

## Supported metadata

Musubi 0.1 reads:

| Source | PNG | JPEG | Notes |
| --- | :---: | :---: | --- |
| Draw Things | Tested | Best effort | XMP configuration and common `v2` values |
| ComfyUI | Tested | — | Execution prompt and workflow graphs; common core samplers and loaders |
| Civitai | Best effort | Tested | A1111-compatible parameters and Civitai resource fields |
| Automatic1111-compatible | Best effort | Best effort | Common parameters and open-ended settings lines |
| Mochi Diffusion native | Tested | Tested | Versioned JSON record in XMP |
| Mochi Diffusion legacy | Tested | Tested | Classic v2.2-and-later XMP captions |

Support means Musubi recognizes the formats represented by its tests and local
reference corpus. Unknown source fields remain available in the raw payloads.
Custom ComfyUI nodes and application updates can produce partial normalized
results without preventing access to their original graphs.

Writing, WebP, HEIC, general Exif editing, and C2PA validation are not included
in 0.1.

## Requirements

- Swift 6.0 or newer
- macOS 13 or newer

Musubi has no third-party runtime dependencies and performs no network access.
Open `Package.swift` directly in Xcode or add the repository as a Swift package
dependency after it has been published.

## Library usage

```swift
import Musubi

let inspection = try MetadataInspector.inspect(contentsOf: imageURL)

for interpretation in inspection.interpretations {
    print(interpretation.format)
    print(interpretation.producer?.name ?? "Unknown producer")

    for generation in interpretation.generations {
        print(generation.positivePrompt ?? "No prompt")
        print(generation.model ?? "Unknown model")
    }
}
```

`inspection.selection` names the generation the image most likely records, or
reports that several are equally plausible. Use `inspection.payloads` when
source-specific or lossless access matters. The payload array is ordered and
can contain duplicate keywords.

If you read metadata with another framework, for example XMP from a HEIC image
through ImageIO, pass the payloads to `MetadataInspector.interpret(_:)`. It
uses the same codecs as `inspect`.

## Command-line inspector

The package includes a small development tool for exploring an image or a
directory of images:

```sh
swift run musubi-inspect /path/to/image-or-directory
```

Run the test suite with:

```sh
swift test
```

If the standalone Command Line Tools cannot load Swift Testing, select a full
Xcode toolchain or prefix the command with an appropriate `DEVELOPER_DIR`.

## Design principles

- Preserve raw payloads before attempting lossy normalization.
- Return multiple interpretations and generations when the file contains them.
- Never invent a plausible value when the source is ambiguous.
- Treat container parsing and generator-specific decoding as separate layers.
- Keep parsing local, synchronous, and safe for untrusted image files.

The public API is intentionally small in 0.1 and may evolve before 1.0.

## Documentation

- [Architecture and roadmap](Docs/Architecture.md)
- [Next metadata wire contract and compatibility probe](Docs/MetadataWireContract.md)
- [Compatibility and testing](Docs/Compatibility.md)
- [Ecosystem research](Docs/Research.md)
- [Release process](Docs/Releasing.md)
- [Contributing](CONTRIBUTING.md)

## License

Musubi is available under the [GNU General Public License v3](LICENSE).
