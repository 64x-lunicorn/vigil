# Design

Why vigil is built the way it is. The [user guide](guide.md) covers what it
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

It lives at the vault root and is appended to the MCP `instructions` so the
assistant does not have to guess where a note belongs.

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

**The file's text is passed through, not reassembled.** `instructions` carries
the raw contents of `_domains.yml`, so whatever a human writes there reaches the
assistant verbatim — prose, comments, extra keys, any structure at all.
`naming` is the **only** key the server interprets; everything else in the file
is documentation for whoever opens it. That is why there is no schema to
satisfy and no key to get wrong: a description is a description because it is
in the file, not because the server parsed it into a field.

**Three domain-shaped facts, three freshness policies.** Only the last of the
three is read at startup and on `reload`:

| Fact | Source | Fresh as of |
|---|---|---|
| Domain names | live directory listing under the vault root | every call |
| The raw text of `_domains.yml` | `File.read` per `Vigil.Store.instructions_domains_text/0` | every MCP `initialize` |
| The parsed `naming` rules | `Vigil.Store` state | startup and `reload` |

Process state is therefore not the single source of truth for domains. Domain
*identity* is a directory listing, taken fresh every time it is needed — the
facts handed to the write policy carry one read per write — and state holds
only the rules that policy enforces.

The split between the last two rows is deliberate. An edited `_domains.yml`
reaches the next session's instructions without a `reload`, while the rules
that gate writes never shift underneath a write in flight. The price is a
window in which the assistant has been told one thing and the policy enforces
another, and that price is worth paying because the two failure modes are
asymmetric:

- **A `naming.pattern` is edited and not yet reloaded.** The assistant proposes
  a path under the new rule and the write is rejected — with the domain whose
  schema it violated, that domain's `hint`, and a concrete suggested path — so
  it corrects itself in one turn. Loud, rare, recoverable.
- **A description is edited and the text comes from state.** That is the far
  more common edit, and it would not reach the assistant until someone
  remembered to call `reload`, with nothing anywhere signalling that the file
  had changed. Silent, common, and wrong until a human notices.

Cheap freshness for the common edit, a self-announcing error for the rare one.
The filesystem read per `initialize` is noise, and was never the argument.

Optionally a domain carries naming rules — see [naming](#path-normalization-and-naming-rules).

### `VIGIL_EXCLUDE` is the hard boundary

A comma-separated list of directory names that are **not parsed**. Not
filtered — not read. No note in the index, no chunk, no backlink, nothing a
bug could accidentally return.

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

A chunk starts at every heading of level `##` to `####` and ends at the last
non-blank line before the next heading of equal or higher rank. A `###` heading
inside a `##` section is its **own** chunk, not a nested inclusion. Every
*content* line belongs to exactly one chunk; the blank lines separating two
sections belong to **neither**. They are punctuation between chunks, not the
tail of the body above them — see "How a file is written" for why the boundary
sits there.

**A heading inside a fenced code block is not a heading.** A note may hold a
Markdown sample, and the `##` lines in it belong to the sample, not to the
note: they open no chunk and cut no section in half. One reading of the note
(`Vigil.Markdown.read/1`) decides that once, for the chunker, the link
extraction and the write gate alike.

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

The rule lives in `Vigil.Slug`, beside the normalization it is applied under,
and both sides ask it: `Vigil.Vault.Policy` before a write, `Vigil.Index`
before a read. It is not a permission check — `skills/tdd.md` passes it — which
is why `read` and `links` can apply it without inheriting the write rules, and
why a reader may still reach a note in a domain that is no longer writable.

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
    max_depth: 1           # optional — path segments allowed inside the domain
```

`pattern` is the only required key: a `naming` block without one constrains
nothing and is not a rule.

A violation returns an error containing the rule *and* a concrete suggested
path. An invalid regex in the config is logged and ignored — a broken
configuration must never block writing. The same holds for every other way the
file can be wrong: `Vigil.Vault.Domains.parse/1` is total, and the worst a
malformed `_domains.yml` costs is the naming rules it was trying to declare.

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

## MCP tool schemas are authoritative

`Vigil.MCP.Tools` declares each tool once — name, description, the `write`
flag, and its parameters' names, types and required-ness — in a single table.
The JSON schema published on `tools/list` and the argument validation
`dispatch/2` runs on `tools/call` are both generated from that table, so they
cannot drift out of agreement the way hand-written twins do.

Every declared parameter is validated against the schema the server itself
publishes. A violation — a wrong type, an off-enum value, an out-of-range
integer, a missing or empty required parameter — is a tool error naming what
was expected, not a substituted default. A caller who claims `type: "bogus"`
gets told so, rather than receiving unfiltered results it believes were
filtered. Undeclared
parameters are ignored: the schemas do not set `additionalProperties: false`,
and rejecting extras a client legitimately sent would fail callers over
something the server never declared.

A bound is part of that declaration, not a correction applied afterwards.
Integer parameters carry a range in the table (`limit` is `1..25`, `depth` is
`1..2`), the range is published as `minimum`/`maximum`, and a value outside it
is refused there. Nothing downstream clamps: `limit: 100` is an error, not a
quiet 25, because a caller told it received the 25 best hits of 100 asked for
cannot tell that from having asked for 25.

---

## The write path

Every write — `create`, `append`, `replace_section`, `rewrite_note`,
`delete_section`, `update_frontmatter`, `delete_note`, `move_note` — asks
`Vigil.Vault.Policy` first. One function, `check/3`, holds every rule about a
write: path safety, path normalization, which domains are writable, the naming
conventions from `_domains.yml`, frontmatter and type rules, duplicate
detection, and the confirm gates. Policy performs no effect and changes
nothing. It asks the vault questions through `Vigil.Vault.Facts` — whether a
path exists, what a note contains, which chunk an id resolves to — and where a
decision authorises an effect it says so in its result rather than performing
it. Asking never changes the vault.

`Facts` is a purity seam, and it answers or it raises. Every one of its
questions guards a gate, and every "nothing there" answer sits on the
permissive side of the gate it feeds: headings that count as zero switch the
shrink gate off, a path that does not exist lets `create` past its existence
refusal, no similar notes switches duplicate detection off. So no field has a
default. A question added and left unwired stops the write at construction
rather than opening the gate it was meant to guard; a test that wants an absent
fact names it.

**The answer has a name too.** `check/3` returns one `Vigil.Vault.Decision`
struct per write shape — a create decision, an append decision carrying its
resolved target, a section decision carrying its resolved chunk, a delete
decision carrying its backlinks, a move decision, a rewrite, a frontmatter
update — each enforcing every field its operation needs, and
`Vigil.Vault.Plan` matches the shape per clause rather than reaching into the
keys it hopes are there. A decision that cannot answer for its operation
fails where the mistake is, not as a `KeyError` inside the single writer.

The point of one gate is that there is no second way in. The rules used to be
private helpers in `Vigil.Store` that only `create` and `move_note` called, so
`append`, `rewrite_note`, `update_frontmatter` and `delete_note` checked
traversal and nothing else — each of them could write into `skills/` and into
an excluded domain, and the write was then indexed as a note.

**`append` resolves its target through the gate too.** Whether an append
becomes a new section, an addition to an existing one, or text at the end of
the file decides what the file becomes, so the policy decides it and returns
the target alongside the path. Content is judged against that target: a heading
in content appended *into* an existing section is rejected, because the next
parse would split that section into two chunks one of which nobody asked for.
Appending at the end of a file, or opening a new section via the heading
argument, is unaffected — there a heading opens a section rather than cutting
one in half.

**A section id is resolved once.** `replace_section` and `delete_section` take
an id, and the policy resolves it through the same lenient lookup `read` uses —
one retry through path normalization — so an id that reads is an id that
writes. The write then goes to the resolved record's canonical path, never to
one re-derived by splitting the id on its fragment. That is what makes the
leniency safe: a normalized id writes where the lookup landed, not where the id
pointed. The path check on the id's own path part still runs first, so an id
naming `skills/` or an excluded domain answers "Invalid path" rather than
"Not found".

**The duplicate gate keys on the note's name.** Before `create` writes, the
policy asks the vault for notes in the same domain that look like the one being
created and refuses with the candidates named, unless the call passes
`force: true`. What it searches for, how deep, and how strong a hit has to be
are stated together in `Vigil.Vault.Policy`, because they are one decision:
the terms are the note's whole name plus each `-`-separated segment of at least
four characters, each term is asked for the best 25 hits in the domain, and a
hit counts when it reaches `Vigil.Search.strength(:title)` — the score at which
the query names a note rather than merely appearing in it. Notes inside the same
project folder are never duplicates of each other.

The whole name is always a term, and that is what keeps the gate closed. Terms
derived from segments longer than three characters alone left `home/weg.md`,
`gear/rad.md` and `training/ftp.md` — live shapes in a German vault — with no
terms at all: `find_similar` was never asked, and the empty result read as
"nothing similar". That is a permissive answer manufactured inside the policy,
before any fact was asked, arriving through a door the `Facts` seam does not
cover. Every unforced create now asks the vault at least one question. Where segments
already qualify the name is the weakest of the terms — a segment is a substring
of it, so wherever the name matches, each of its segments matches too and scores
at least as high. What it costs there is one more query per create, and the one
note it can still surface on its own: the one a broad segment's best 25 had no
room for.

**The write path returns a plan; the process executes it.** A resolved
decision plus the note's current content becomes a `Vigil.Vault.Plan`: the
action to perform and the commit message to perform it under. Three actions,
because there are three shapes of write — `{:write, path, content}` for the
six content-shaped operations, `{:delete, path}` and `{:move, from, to}` for
the two git-level ones. Building a plan performs no effect and reads no file,
so every write operation can be exercised without a vault, a git repository or
a running GenServer. `Vigil.Store` is left with the sequence — ask the policy,
read the note, build the plan, execute it — and the effect.

Order matters: perform the action, commit, reparse into the index, then push.
It is stated once, where a plan is executed. If the push fails the local commit
stays and the tool returns an error naming what is committed locally but not
pushed — the change, the deletion, or the move. Nothing is rolled back.

**Confirm is the last gate, not the first.** `delete_note` and `move_note`
resolve their paths before asking for confirmation, so a path naming `skills/`,
an excluded domain or a traversal answers "Invalid path" rather than quoting
itself back in a destructive-operation prompt for a write that would be refused
on the next turn.

Commit author is `vigil <vigil@local>`, set with `-c` on the call rather than
in the repository config, so manual commits keep the human's identity. That
makes `git log --author=vigil` the provenance query: every line in the vault is
attributable to either the assistant or the human.

`commit.gpgsign=false` is forced the same way. The service user has no signing
key; an inherited `commit.gpgsign=true` would otherwise fail every single
write.

**A failed write never takes the server down.** Filesystem errors are converted
to error tuples and never allowed to propagate into the GenServer. One failed
write must not cost read access to everything else. A caller that breaks a
declared contract outright — a `search` without a `limit`, a `links` with a
depth the tool table does not allow — is matched in `Vigil.Store`'s client
functions, so it fails in its own process rather than in the writer's.

The write effect itself — create the directory, write the file, commit it, and
the wording for a POSIX error — belongs to `Vigil.Commit`, and notes and skills
both go through it. It sits at the top level rather than under
`Vigil.Vault.*` for the same reason `Vigil.Markdown` does: skills are never
notes and must not depend on a note-shaped module. What stays with each caller
is what differs — `Vigil.Store` reparses the written file into the index
between commit and push, which would index a skill as a note, and each write
action's push-failure message names its own object: a change, a deletion, a
move, a skill.

---

## How a file is written

Vigil is the only writer (principle 2), so the shape of a file on disk is
vigil's to define. Three rules, and they hold on every write path.

**A file ends with exactly one newline.** `Vigil.Markdown` owns this rule and is
the only place that states it. The whole-file writes (`create`, `rewrite_note`,
`update_frontmatter`) and the chunk-shaped writes in `Vigil.Vault.Edit` both go
through it, and so does `Vigil.Skills` — skills are never notes, which is
precisely why the rule cannot live in a chunk-editing module. A rule needed by a
path that must not depend on the owning module does not belong to that module.
One consequence, and it is intended: editing the last section of an imported
note that ended in blank lines drops them. There is no second writer whose
intent those lines could encode.

**The separator between two sections belongs to no chunk.** A write that
replaces a section's body cannot delete the blank line before the next heading,
because that line was never inside the range it was handed. This is why the
chunk boundary stops at the last non-blank line rather than at the line before
the next heading: under the earlier boundary every `replace_section` on a
mid-file section silently ate one blank line, and with a single writer nothing
would ever have put it back. The alternative — have `Vigil.Vault.Edit`
normalise the file afterwards — was rejected. It would make `Edit` rewrite
lines its caller never named, to repair damage the chunk model itself caused.
Moving the boundary removes the cause instead, and it stops shipping a stray
blank line to the assistant on every mid-file `read` (principle 4).

The same rule binds the body a write *puts in*: content the caller ended with
a blank line loses it, because a body is content lines only. This is not the
rejected normalisation — nothing already in the file is rewritten. It is
`Vigil.Vault.Edit` writing a body the next parse will give back unchanged
instead of one with a second separator in front of the following heading.

**Deleting a section takes its separator with it.** `delete_section` removes the
heading, the body, and exactly one following blank line — the slot the section
occupied. Not every following blank line: a wider gap someone set deliberately
survives, one line narrower.

These rules say nothing about repairing notes written before them. Files that
already lost a separator stay as they are; principle 5 says the server reports
and does not fix on its own initiative.

---

## Vault hygiene has one set of rules

`lint` (through `Vigil.Index`) and `mix vigil.vault_check` (through
`Vigil.VaultCheck`) both report on the shape of the vault, and they report to
different readers: `lint` answers an assistant over MCP and is token-frugal,
the doctor writes a JSON report for `jq`. The output shapes stay separate. The
facts underneath do not — they were restated in both and drifted, and they live
in `Vigil.Vault.Rules` now.

**A duplicate heading is a duplicate *slug*.** Two headings collide when the
slug of their heading text collides *within one note*, because that is what
`Vigil.Parser`'s uniquifier keys its collision counter on: `## A / ### B` and
`## C / ### B` really do produce `b` and `b-2`. Grouping by the heading chain
instead under-reports exactly the notes whose chunk ids are unstable, which is
the breaking change this project fears most (see "Known trade-offs").

**An overlong note is 30 headings or 2000 words.** Two axes rather than a chunk
count, because the pair says *why* the note is too long — many sections, or
much prose — which is what the reader acts on. The `lint` finding carries both
counts and which threshold was crossed.

**A sentence-shaped heading** is longer than 60 characters or ends in `.`, `!`
or `?`. A signal, not proof.

**A slug diff covers filenames and headings.** Both halves of "what would this
slug change break" are answered in one place — one walk over the vault in
`Vigil.Vault.Rules`, one set of facts — so `mix vigil.slug_diff` and the
doctor cannot disagree about the blast radius. The two render it differently
on purpose (a JSON report for `jq`, a line per difference for a human); the
facts underneath are the same ones.

---

## The time envelope

Every tool response carries exactly one of these fields:

| Field | When | Content |
|---|---|---|
| `_` | first response of the session, a near event is active | `"Wed 09.09. 07:12 \| Via Carolina 28h left"` |
| `_` | first response of the session, a near event is upcoming | `"Wed 09.09. 07:12 \| Via Carolina in 28h"` |
| `_t` | every later response, nothing changed | `"07:12"` |
| `_!` | an event changed phase during the session | `"Via Carolina now active"` |

It sits at the top level of the JSON the assistant reads — not in `_meta`, not
as a separate content block. The target is under 10 tokens per response.

**Every** response, including an error. An error response carries its message
as JSON next to the envelope field and keeps its error marker, and it advances
the session's state like any other response: a session whose first call failed
has still made a first call. The field is attached around both outcomes of a
tool call rather than inside the success branch, so the rule is structurally
true rather than true in one of two branches.

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
5. **Rate limiting** — fixed window, in three places that are easy to
   confuse. `/mcp` is limited per access token, so it is unreachable without
   one. The authorization server's own endpoints — `register`, `authorize`,
   `token` — are limited per **client address**, because they are reachable
   with no token at all and each one costs something: an outbound CIMD fetch
   to an address the caller chose, a `:dets` row and an fsync, or the work of
   answering a guess. The consent form counts wrong passwords only, per
   address, over a much longer window. One limiter, `Vigil.RateLimit`, serves
   the first two; the third is a lockout rather than a request limit and
   belongs to `Vigil.OAuth.Store`.

**Client address** is a decision, not a lookup. `conn.remote_ip` is the peer of
the TCP connection, which behind layer 1 is the proxy — so a per-address limit
keyed on it is one global bucket. A forwarded header is written by whoever sent
the request unless something overwrites it, so vigil believes one only when
told its name *and* told which peers may set it, and takes the rightmost hop it
did not add itself. Both settings are empty by default: unconfigured, the limit
stays global, which is stricter than intended rather than weaker. Getting them
wrong is the only way to make this worse than not having it.

**A grant** is one authorization, and it is the unit of revocation. A `grant_id`
is minted with the authorization code and carried onto every token redeemed or
refreshed from it, so a replayed refresh token can take down the whole family.
Not `client_id`: a client legitimately holds more than one grant over time. A
rotated refresh token is marked **spent** rather than deleted, because deleting
it makes a replay indistinguishable from a token that never existed — and the
replay is the signal that one of two holders is an attacker. See
[oauth.md](oauth.md) for the full walk.

The SkillKey creates a bootstrap problem: `skill_write` needs a key, but a
fresh vault has no conventions skill to read one from. Resolved by having
`skill_read` return the current key in its *error* response too — the key is a
pure HMAC over secret and time and does not depend on any skill existing.

`VIGIL_AUTH_PASSWORD` doubles as both the password the resource owner types on
the OAuth consent page (layer 2) and the HMAC secret behind the SkillKey
(layer 4) — one setting, two unrelated roles. Deliberate, reviewed, and left
as-is: for a single-user server the blast radius is acceptable. But it means
rotating the password because someone saw the consent page also invalidates
every outstanding SkillKey, and an assistant mid-conversation loses write
access until it calls `skill_read` again.

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

**All reads serialize through one GenServer.** The index (`Vigil.Index`) is a
plain value held in `Vigil.Store`'s process state, so every read is a
`GenServer.call`. For a single-user knowledge base this is a feature — it
makes writes atomic with respect to reads — but it is a real ceiling if the
workload ever becomes concurrent.

**The full index rebuild on every write is O(vault), not O(change).** Cheap at
the sizes this targets, measured above. It would need revisiting an order of
magnitude further out.

**Slug changes are breaking changes.** Because chunk ids derive from headings,
editing a heading changes its id and breaks stored references to it.
`mix vigil.slug_diff` makes the blast radius visible; nothing makes it zero.
