# /// script
# requires-python = ">=3.11"
# dependencies = ["Pillow==11.3.0", "piexif==1.1.3"]
# ///
"""Run pinned upstream image/text reader functions without launching WebUI.

Only WebUI style, emphasis and version-migration hooks are disabled. The image
reader, field scanner, unquoting and parse_generation_parameters bodies run
unchanged. This is parser evidence, not a full WebUI/UI integration test.
"""

import ast
import hashlib
import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace
from urllib.request import urlopen

from PIL import Image
import piexif
import piexif.helper

REVISION = "82a973c04367123ae98bd9abdf80d9eda9b910e2"
SOURCES = {
    "infotext_utils.py": "8e2520d172dd7f66648ad3712b8b6a834e544d4e6dc3ad556e3144a1af235200",
    "images.py": "c1370f739d0ec64d2798a4ad3aab65cc191b817bba390f7f260129fd3ab40586",
}
FUNCTIONS = {"unquote", "restore_old_hires_fix_params", "parse_generation_parameters", "read_info_from_image"}
CONSTANTS = {"re_param_code", "re_param", "re_imagesize", "IGNORED_INFO_KEYS"}


def upstream_readers(cache):
    namespace = {
        "json": json, "re": re, "Image": Image, "piexif": piexif,
        "shared": SimpleNamespace(opts=SimpleNamespace(infotext_styles="Ignore", use_old_hires_fix_width_height=False)),
        "prompt_parser": SimpleNamespace(parse_prompt_attention=lambda text: []),
        "infotext_versions": SimpleNamespace(backcompat=lambda values: None),
    }
    cache.mkdir(parents=True, exist_ok=True)
    for filename, checksum in SOURCES.items():
        path = cache / filename
        if not path.exists():
            url = f"https://raw.githubusercontent.com/AUTOMATIC1111/stable-diffusion-webui/{REVISION}/modules/{filename}"
            with urlopen(url, timeout=30) as response:
                data = response.read()
            assert hashlib.sha256(data).hexdigest() == checksum, filename
            path.write_bytes(data)
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == checksum, filename
        tree = ast.parse(data, filename=filename)
        selected = [ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)]
        for node in tree.body:
            if isinstance(node, ast.FunctionDef) and node.name in FUNCTIONS:
                selected.append(node)
            elif isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in CONSTANTS for t in node.targets):
                selected.append(node)
        module = ast.fix_missing_locations(ast.Module(body=selected, type_ignores=[]))
        exec(compile(module, filename, "exec"), namespace)
    return namespace["read_info_from_image"], namespace["parse_generation_parameters"]


def main(directory):
    read_image, parse_text = upstream_readers(directory / "a1111-source")
    report = {"revision": REVISION, "images": []}
    for expected_path in sorted(directory.glob("*.expected.json")):
        name = expected_path.name.removesuffix(".expected.json")
        expected = json.loads(expected_path.read_text())
        images = [directory / f"{name}.{extension}" for extension in ("png", "jpeg")]
        images = [path for path in images if path.exists()]
        assert images, f"No fixture image for {expected_path.name}"
        for image_path in images:
            with Image.open(image_path) as image:
                image.load()
                text, _ = read_image(image)
            assert text == expected["parameters"], f"Carrier changed: {image_path.name}"
            parsed = parse_text(text, skip_fields=[]) if text is not None else {}
            for key, value in expected["a1111"].items():
                assert parsed.get(key) == value, f"{image_path.name}: {key} is {parsed.get(key)!r}, not {value!r}"
            report["images"].append({"file": image_path.name, "parsed": {k: v for k, v in parsed.items() if isinstance(v, str)}})
    assert report["images"], "Generate fixtures before running this oracle"
    control = directory / "unicode-imageio.jpeg"
    if control.exists():
        with Image.open(control) as image:
            text, _ = read_image(image)
        original = json.loads((directory / "unicode.expected.json").read_text())["parameters"]
        report["imageioUnicodeControlPreserved"] = text == original
    (directory / "a1111-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    summary = f"A1111: {len(report['images'])} full-image checks passed"
    if "imageioUnicodeControlPreserved" in report:
        summary += f"; ImageIO Unicode control preserved: {report['imageioUnicodeControlPreserved']}"
    print(summary)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: uv run a1111.py /path/to/generated/fixtures")
    main(Path(sys.argv[1]))
