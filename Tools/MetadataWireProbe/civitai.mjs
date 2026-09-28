import assert from 'node:assert/strict';
import { access, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { readCivitaiMetadata } from '@civitai/generation-metadata/civitai';
import { decodeUserComment } from '@civitai/generation-metadata/image';

const directory = process.argv[2];
if (!directory) throw new Error('Usage: node civitai.mjs /path/to/generated/fixtures');
const exists = file => access(file).then(() => true, () => false);

/** The value at a dot-separated path, or undefined when any step is missing. */
function valueAt(object, keyPath) {
  return keyPath.split('.').reduce((value, key) => (value == null ? undefined : value[key]), object);
}

const report = { package: '@civitai/generation-metadata@0.1.0', images: [] };
for (const filename of (await readdir(directory)).filter(name => name.endsWith('.expected.json')).sort()) {
  const name = filename.replace('.expected.json', '');
  const expected = JSON.parse(await readFile(path.join(directory, filename), 'utf8'));
  const files = [];
  for (const extension of ['png', 'jpeg']) {
    if (await exists(path.join(directory, `${name}.${extension}`))) files.push(`${name}.${extension}`);
  }
  assert.ok(files.length > 0, `${filename}: no fixture image`);
  for (const file of files) {
    const result = await readCivitaiMetadata(await readFile(path.join(directory, file)));
    const text = file.endsWith('.png')
      ? result.exif?.parameters
      : result.exif?.userComment && decodeUserComment(result.exif.userComment);
    assert.equal(text ?? null, expected.parameters, `${file}: carrier text`);
    for (const [keyPath, value] of Object.entries(expected.civitai)) {
      assert.deepEqual(valueAt(result, keyPath) ?? null, value, `${file}: ${keyPath}`);
    }
    report.images.push({ file, generator: result.generator, raw: result.raw, normalized: result.civitai?.generation });
  }
}
assert.ok(report.images.length > 0, 'Generate fixtures before running this oracle');
if (await exists(path.join(directory, 'unicode-imageio.jpeg'))) {
  const control = await readCivitaiMetadata(await readFile(path.join(directory, 'unicode-imageio.jpeg')));
  const original = JSON.parse(await readFile(path.join(directory, 'unicode.expected.json'), 'utf8'));
  report.imageioUnicodeControlPreserved = decodeUserComment(control.exif.userComment) === original.parameters;
}
await writeFile(path.join(directory, 'civitai-results.json'), JSON.stringify(report, null, 2) + '\n');
const control = 'imageioUnicodeControlPreserved' in report
  ? `; ImageIO Unicode control preserved: ${report.imageioUnicodeControlPreserved}` : '';
console.log(`Civitai: ${report.images.length} full-image checks passed${control}`);
