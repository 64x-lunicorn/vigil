// Templater user script: `tp.user.vigil_title(tp)`.
//
// Gives a note created in Obsidian the filename vigil would give it. A note
// that is still untitled is asked for a title; the file is renamed to the
// title's slug, and the title is returned for the H1.
//
// `slugify` is a copy of `Vigil.Slug.slugify/1` and has to stay in step with
// it: test/fixtures/slug_examples.json is checked against both, by
// test/vigil/obsidian_templates_test.exs and scripts/test/slug_js_test.mjs.

const MAX_LENGTH = 80;

// Applied before generic diacritic stripping: NFD decomposition would turn
// "ü" into "u", losing the information that German expects "ue".
const TRANSLITERATIONS = [
  ["ä", "ae"],
  ["ö", "oe"],
  ["ü", "ue"],
  ["ß", "ss"],
  ["å", "aa"],
  ["ø", "oe"],
  ["æ", "ae"],
  ["đ", "d"],
  ["ł", "l"],
  ["þ", "th"],
];

// The names Obsidian gives a new note before its author has named it.
const UNTITLED = /^(Untitled|Unbenannt)( \d+)?$/;

// The slug of a title, or "" where `Vigil.Slug.slugify/1` answers
// `{:error, :empty}` (nothing alphanumeric is left).
function slugify(text) {
  let slug = text.normalize("NFC").trim().toLowerCase();
  for (const [from, to] of TRANSLITERATIONS) slug = slug.split(from).join(to);
  slug = slug
    .normalize("NFD")
    .replace(/\p{Mn}/gu, "")
    .normalize("NFC")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (slug.length > MAX_LENGTH) {
    const cut = slug.slice(0, MAX_LENGTH);
    const hyphen = cut.lastIndexOf("-");
    slug = (hyphen === -1 ? cut : cut.slice(0, hyphen)).replace(/-+$/, "");
  }
  return slug;
}

async function vigil_title(tp) {
  let title = tp.file.title;
  if (UNTITLED.test(title)) {
    title = ((await tp.system.prompt("Title")) || "").trim();
  }
  const slug = slugify(title);
  if (slug === "") {
    throw new Error("vigil_title: the title needs at least one letter or digit");
  }
  if (slug !== tp.file.title) await tp.file.rename(slug);
  return title;
}

module.exports = vigil_title;
module.exports.slugify = slugify;
