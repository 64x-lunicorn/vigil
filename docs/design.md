# Design

Why vigil is built the way it is. The [README](../README.md) covers what it
does and how to run it; this document covers the reasoning, the vault model,
and the decisions that were deliberately *not* taken.

---

## Principles

These five determine every implementation decision. Where a choice is
ambiguous, the smaller solution is the right one.

**1. Only derivable things are stored.** Status, age, backlinks — all computed,
never written into files. A stored status is a `now` that was frozen and now
lies.

**2. One writer.** Only vigil writes to the vault. Obsidian and every other
client are read-only. It follows that there is no merge, no locking protocol,
no conflict handling — none of it is needed.

**3. Git is the metadata database.** Creation date = first commit. Provenance =
commit author. History = `git log`. No frontmatter field for anything Git
already knows.

**4. Context is the bottleneck, not the CPU.** Every tool returns as few tokens
as it can. Search returns cards, not content. Reads return sections, not files.

**5. The server has no opinion.** It computes functions over the data. It
summarizes nothing, interprets nothing, and writes nothing on its own
initiative.

---

## The vault model

### Domains are directories

A domain is any directory directly under `VIGIL_VAULT_PATH`, except `skills/`,
except anything in `VIGIL_EXCLUDE`, and except anything starting with `.` or
`_`. **The server never creates directories.**

Notes live *flat* inside their domain, exactly one level deep. Adding a domain
means creating a directory and an entry in `_domains.yml`, then calling
`reload` — no code change, no restart.

**`projects/` is the one exception the code knows by name.** It may have
exactly one extra level — one directory per project. The reasoning: a project
is a namespace with a sharp boundary, not a topic. There are no borderline
cases like "tires: gear or training?". Deeper nesting (`projects/vigil/docs/`)
is rejected.

**`projects/<name>/` is also the one exception to "the server never creates
directories".** `create`'s `create_dirs` flag auto-creates exactly that one
missing directory level — matching the "one directory per project" rule above
— when writing the first note into a not-yet-existing project. No other
domain, and no deeper level, gets this treatment: a two-level path outside
`projects/` (or a third level inside it) is rejected before directory creation
is even considered.

The main note of a project is named after the project:
`projects/vigil/vigil.md`. Deliberately **not** `readme.md` — several projects
would then produce colliding wikilink slugs, since links resolve through the
file stem.

`journal/` is the only directory for chronological entries, and the only one
with a special rule in search: it is hidden unless `domain: "journal"` is
requested explicitly. Chronological entries would otherwise crowd out real
notes in every result set.

### `_domains.yml` is a description, not configuration

It lives at the vault root, is read at startup and on `reload`, and is appended
to the MCP `instructions` so the assistant does not have to guess where a note
belongs.

- File missing: warning in the log, instructions without domain descriptions,
  everything else keeps working.
- A key without a matching directory: warning, key ignored.
- A directory without a key: still a domain. The file is a description, not a
  whitelist. Warning in the log.
- **The running server never writes this file.** No MCP tool changes it. A new
  domain is a human decision, not the assistant's. The one sanctioned, one-time
  exception is `init.sh`'s vault-adoption phase (see
  [`docs/history.md`](history.md#vault-adoption-and---check-only)): onboarding
  a pre-existing vault appends entries for domains it finds missing from
  `_domains.yml`, before the server ever runs against it.

Optionally a domain carries naming rules — see [naming](#path-normalization-and-naming-rules).

### `VIGIL_EXCLUDE` is the hard boundary

A comma-separated list of directory names that are **not parsed**. Not
filtered — not read. No ETS entry, no chunk, no backlink, nothing a bug could
accidentally return.

The difference from a flag inside `_domains.yml` is essential: a process cannot
change its own environment variable, but it can change a file in the vault.
Anything that must genuinely stay hidden from the assistant belongs in
`VIGIL_EXCLUDE`, not in a marker inside a file the assistant can read.

### `skills/` — one repository, two systems

`skills/` holds instructions for the assistant. For vigil it is invisible: not
parsed, not chunked, not searchable, no backlinks. Access only through the
`skill_*` tools.

The reason is a category difference: a note is a statement about the world and
ages. A skill is an instruction to the assistant and does not. They share a Git
repository and nothing else.

### Frontmatter — exactly one required field

```yaml
---
type: reference | decision | event
---
```

- **`reference`** — does not age. Facts about the world.
- **`decision`** — always ages. Facts about the vault owner, choices they made.
  An implicit expiry date without one being stored; `lint` flags stale ones.
- **`event`** — passes through phases. Only `event` may additionally carry
  `starts` and `ends` (ISO 8601 **with offset**).

No `status`, no `valid_until`, no `provenance`, no `tags`. Each of those is
either derivable or was deliberately rejected.

**Parsing is defensive.** Missing frontmatter, unparsable YAML, a missing or
invalid `type` — all produce a warning with path and reason, and the note is
parsed anyway and treated as `reference`. The server always starts, nothing is
lost, nothing crashes.

### Derived metadata

| Metadatum | Source |
|---|---|
| title | first H1, else the filename |
| domain | directory |
| created | first Git commit touching the file |
| last modified | last Git commit touching the file |
| backlinks | inverted link index |
| event phase | function of `starts`/`ends` and `now` |
| author per change | Git commit author |

Git metadata is collected **once** during parsing in a single `git log` call
for the whole vault, and carried in the chunk record. `git log` is never called
during a search or a read.

---

## Chunking

A chunk starts at every heading of level `##` to `####` and ends before the
next heading of equal or higher rank. A `###` heading inside a `##` section is
its **own** chunk, not a nested inclusion. Every body line belongs to exactly
one chunk.

**The H1 creates no chunk** — it is the title of the file. Text between the H1
and the first `##` (or text in a file with no headings at all) becomes a chunk
whose id is the path with no fragment.

Chunk id: `path#heading-slug`, for example `bike/via-carolina.md#fueling`.
Collisions inside one file get a `-2`, `-3` suffix.

`heading_path` carries the chain of heading texts for display
(`File title › Fueling › Second Half`); the chunk id uses only the slug of the
heading itself.

This is what keeps retrieval cheap: the assistant fetches one section, not a
3000-word file.

---

## Search

- Literal matching over chunk bodies and headings via `:binary.match/2`
  (Boyer-Moore). No regex.
- **The query is a phrase**, exactly as entered. No token split, no AND/OR.
  `"terra speed"` matches only contiguous `terra speed`.
- Case-insensitive: every chunk carries a downcased copy alongside the
  original. Matching runs against the copy, previews come from the original.
- Filters apply *before* matching: `domain`, `type`.
- Ranking is a simple additive score, deliberately not BM25 and deliberately
  not machine-learned: title hit +10, heading hit +5, body occurrences +1 each
  capped at 5, `type == prefer` +5. Score 0 drops out. Ties break on the more
  recently updated chunk.
- Results carry only `id`, `title`, `type`, `score`, `preview` — and `hub` when
  the note has exactly one incoming link. Never bodies.

---

## Path normalization and naming rules

Three layers guard every write, in this order.

**1. Security.** No `..`, no absolute paths, no backslashes, no null bytes, and
no path segment starting with `.` or `_`. Checked before *and* after
normalization.

**2. Normalization.** `Vigil.Slug` produces one canonical form: NFC, trim,
lowercase, explicit transliteration (`ä`→`ae`, `ø`→`oe`, `ß`→`ss`, …), generic
diacritic stripping, non-alphanumeric runs to a single hyphen, collapse and
trim hyphens, truncate to 80 characters at a hyphen boundary.

Transliteration runs *before* generic diacritic stripping. Otherwise NFD
decomposition turns `ü` into `u` rather than `ue`, silently losing information.

The same function produces chunk ids, so file names and `[[…]]` references
cannot drift apart. That coupling is the reason `mix vigil.slug_diff` exists:
before changing the slug function, it shows exactly which chunk ids would move
and therefore which stored references would break.

**3. Convention.** An optional per-domain `naming` block in `_domains.yml`:

```yaml
journal:
  description: "Chronological, hidden from the default search"
  naming:
    pattern: '^\d{4}-\d{2}-\d{2}\.md$'
    scope: filename        # or: relpath
    suggestion: date       # or: slug — shapes the error message
    hint: "Journal notes are named YYYY-MM-DD.md"
```

A violation returns an error containing the rule *and* a concrete suggested
path. An invalid regex in the config is logged and ignored — a broken
configuration must never block writing.

Normalization means a messy path is *corrected*, not rejected. When the path
changed, the response carries `path_normalized_from` so the caller knows where
the note actually landed.

---

## The link index

Links are extracted per chunk during parsing, unresolved: `[[target]]`,
`[[target#fragment]]`, `[[target|alias]]`, `[text](path.md)`. Links inside
fenced code blocks and inline code are skipped — otherwise example code
registers as real references.

Resolution happens centrally, because it needs to know about every note in the
vault, which the parser (a pure file-to-chunks function) does not. A target
containing `/` is a vault-relative path. Otherwise the basename is resolved
through a cascade: same folder → same domain → vault-wide. More than one match
at a stage is `ambiguous` with all candidates; no match is `broken`.

**`broken` is not an error.** A link to a note that does not exist yet is a
legitimate placeholder — it marks something to be written later. `lint` reports
it; nothing blocks.

The index is **rebuilt in full** on every load and every single-file reparse
rather than maintained incrementally. That structurally rules out the "ghost
entry after delete or rename" class of bug, instead of requiring every write
path to get the bookkeeping right. The candidate index for basename resolution
is built once per rebuild, not once per link — without that the rebuild would
be O(links × files) and would dominate the write path.

Measured on a synthetic vault of 1000 notes and 2000 links: full load 0.34 s,
one write including a complete index rebuild ~115 ms.

---

## The write path

Order matters: write the file, commit, reparse into the index, then push. If
the push fails the local commit stays and the tool returns an error saying the
change is committed locally but not pushed. Nothing is rolled back.

Commit author is `vigil <vigil@local>`, set with `-c` on the call rather than
in the repository config, so manual commits keep the human's identity. That
makes `git log --author=vigil` the provenance query: every line in the vault is
attributable to either the assistant or the human.

`commit.gpgsign=false` is forced the same way. The service user has no signing
key; an inherited `commit.gpgsign=true` would otherwise fail every single
write.

**A failed write never takes the server down.** Filesystem errors are converted
to error tuples and never allowed to propagate into the GenServer. One failed
write must not cost read access to everything else.

---

## The time envelope

Every tool response carries exactly one of these fields:

| Field | When | Content |
|---|---|---|
| `_` | first response of the session | `"Thu 09.07. 11:20 \| via-carolina in 28h"` |
| `_t` | every later response, nothing changed | `"11:47"` |
| `_!` | an event changed phase during the session | `"via-carolina now active"` |

It sits at the top level of the JSON the assistant reads — not in `_meta`, not
as a separate content block. The target is under 10 tokens per response.

This is the reason the assistant never has to guess what time it is.

---

## Security model

Five layers, each doing one job:

1. **Cloudflare Access** — network layer, before Elixir. `init.sh` aborts
   unless the public endpoint answers 403.
2. **OAuth 2.1 + PKCE** — vigil is its own authorization server. See
   [oauth.md](oauth.md).
3. **Scope** — `vault` (full) or `vault:read` (read-only tools).
4. **SkillKey** — a rotating HMAC required by every write tool. Not access
   control (the token already did that): it is proof that the assistant has
   *read the writing conventions* in this session. It can only be obtained by
   calling `skill_read`.
5. **Rate limiting** — fixed window per access token.

The SkillKey creates a bootstrap problem: `skill_write` needs a key, but a
fresh vault has no conventions skill to read one from. Resolved by having
`skill_read` return the current key in its *error* response too — the key is a
pure HMAC over secret and time and does not depend on any skill existing.

---

## Deliberate non-goals

Not built, and not "prepared for" either:

- No graph layer — the link index is enough; a graph waits for a query that
  needs one
- No vector store, no embeddings, no semantic search
- No scheduler, no cron, no notifications
- No automatic summaries or journal entries — only explicit tool calls write
- No Phoenix, no Ecto, no database
- No LLM call inside the server
- No file watcher — vigil is the only writer; external changes are picked up on
  restart or `reload`
- No `create_domain` tool — the server creates no structure, because it would
  then be deciding its own filing system
- No write access to `_domains.yml`
- No audit log — writes are in the Git history, reads are uninteresting

---

## Known trade-offs

**All reads serialize through one GenServer.** The ETS tables are private to
`Vigil.Store`, so every read is a `GenServer.call`. For a single-user knowledge
base this is a feature — it makes writes atomic with respect to reads — but it
is a real ceiling if the workload ever becomes concurrent.

**The full index rebuild on every write is O(vault), not O(change).** Cheap at
the sizes this targets, measured above. It would need revisiting an order of
magnitude further out.

**Slug changes are breaking changes.** Because chunk ids derive from headings,
editing a heading changes its id and breaks stored references to it.
`mix vigil.slug_diff` makes the blast radius visible; nothing makes it zero.
