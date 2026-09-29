// scripts/test/slug_js_test.mjs — the Obsidian slug agrees with vigil's.
//
// `_templates/_scripts/vigil_title.js` names notes created in Obsidian, and
// its `slugify` is a JavaScript copy of `Vigil.Slug.slugify/1`. A copy
// drifts unless something holds it to the original: this checks it against
// test/fixtures/slug_examples.json, the table test/vigil/obsidian_templates_test.exs
// checks the Elixir against. `expected: null` is a title with no slug
// (`{:error, :empty}`), which the JavaScript answers with "".
//
// Plain Node, no dependencies.
//
// Usage: node scripts/test/slug_js_test.mjs

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const require = createRequire(import.meta.url);
const { slugify } = require(
  join(root, "scripts/templates/obsidian/_templates/_scripts/vigil_title.js"),
);
const examples = JSON.parse(
  readFileSync(join(root, "test/fixtures/slug_examples.json"), "utf8"),
);

let passed = 0;
let failed = 0;

for (const { input, expected, why } of examples) {
  const actual = slugify(input);
  if (actual === (expected ?? "")) {
    console.log(`  ok   - ${why}`);
    passed++;
  } else {
    console.error(`  FAIL - ${why}`);
    console.error(
      `         ${JSON.stringify(input)}: expected ${JSON.stringify(expected ?? "")}, got ${JSON.stringify(actual)}`,
    );
    failed++;
  }
}

console.log(`\n  passed: ${passed}    failed: ${failed}`);
process.exit(failed === 0 && passed > 0 ? 0 : 1);
