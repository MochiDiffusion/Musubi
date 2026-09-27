import assert from 'node:assert/strict';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { readCivitaiMetadata } from '@civitai/generation-metadata/civitai';
import { decodeUserComment } from '@civitai/generation-metadata/image';

const directory = process.argv[2];
if (!directory) throw new Error('Usage: node civitai.mjs /path/to/generated/fixtures');
const report = { package: '@civitai/generation-metadata@0.1.0', images: [] };
for (const filename of (await readdir(directory)).filter(name => name.endsWith('.expected.json')).sort()) {
  const name = filename.replace('.expected.json', '');
  const expected = JSON.parse(await readFile(path.join(directory, filename), 'utf8'));
  for (const extension of ['png', 'jpeg']) {
    const file = `${name}.${extension}`;
    const result = await readCivitaiMetadata(await readFile(path.join(directory, file)));
    const text = extension === 'png' ? result.exif.parameters : decodeUserComment(result.exif.userComment);
    assert.equal(text, expected.parameters, `${file}: carrier text`);
    if (name === 'hosted' || name === 'two-fields') {
      assert.equal(result.generator, null);
      assert.deepEqual(result.raw, {});
    } else if (name === 'markers') {
      assert.equal(result.raw.steps, 99);
      assert.equal(result.raw.prompt, 'a cube');
    } else {
      assert.equal(result.raw.prompt, expected.prompt, file);
      assert.equal(result.raw.steps, 8);
      assert.equal(result.raw.width, 32);
      assert.equal(result.raw.height, 32);
    }
    if (name === 'diffusion') {
      assert.equal(result.raw.seed, 4294967296);
      assert.equal(result.raw.cfgScale, 4.5);
      assert.equal(result.raw.sampler, 'Euler');
      assert.equal(result.raw['Schedule type'], 'Normal');
      assert.equal(result.raw.Model, 'Example');
      assert.equal(result.raw.negativePrompt, 'blur');
      assert.equal(result.civitai.generation.denoise, 0.42);
    }
    if (name === 'unicode') assert.equal(result.raw.Model, 'café, "猫"');
    if (name === 'resources') {
      assert.equal(result.raw.hashes.model, '0123456789');
      assert.equal(result.raw.hashes['lora:detail'], 'abcdef0123');
      assert.deepEqual(result.raw.civitaiResources, [{ type: 'lora', weight: 0.75, modelVersionId: 123456 }]);
      // The prompt's <lora:> tag joins the LoRA's name, weight, hash and version ID into one resource.
      assert.equal(result.civitai.generation.prompt, 'a red cube');
      const lora = result.civitai.generation.resources.find(resource => resource.kind === 'lora');
      assert.deepEqual(
        { name: lora.name, weight: lora.weight, hash: lora.hash, modelVersionId: lora.modelVersionId },
        { name: 'detail', weight: 0.75, hash: 'abcdef0123', modelVersionId: 123456 });
    }
    report.images.push({ file, generator: result.generator, raw: result.raw, normalized: result.civitai.generation });
  }
}
assert.equal(report.images.length, 12, 'Generate all six fixtures before running this oracle');
const control = await readCivitaiMetadata(await readFile(path.join(directory, 'unicode-imageio.jpeg')));
const original = JSON.parse(await readFile(path.join(directory, 'unicode.expected.json'), 'utf8'));
report.imageioUnicodeControlPreserved = decodeUserComment(control.exif.userComment) === original.parameters;
await writeFile(path.join(directory, 'civitai-results.json'), JSON.stringify(report, null, 2) + '\n');
console.log(`Civitai: ${report.images.length} full-image checks passed; ImageIO Unicode control preserved: ${report.imageioUnicodeControlPreserved}`);
