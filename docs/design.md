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

**2. One writer.** Only vigil writes to *its* working tree. Nothing else edits
files there. A human who edits — in Obsidian with Obsidian Git, or in any
other editor — does so in a clone of their own, commits under their own name
and pushes to the remote. vigil adopts those commits before its next write,
before a read at most once per interval, at boot and on `reload`. What vigil committed and has not pushed yet is its own
to move: its single-file commits are rebased onto whatever the remote holds,
merge commits included, and pushed again. vigil never merges a human's work
and never overwrites it. A rebase that conflicts is aborted, vigil's commit
stays local, and the conflict is reported for a human to resolve. There is no
locking protocol and no conflict resolution in vigil — only a real conflict
is refused.

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
is even considered. The directory is made as part of the write it is for, and
goes again with it: a `create` that fails — a commit git refuses, say — leaves
no empty `projects/<name>/` behind.

The main note of a project is named after the project:
`projects/vigil/vigil.md`. Deliberately **not** `readme.md` — several projects
would then produce colliding wikilink slugs, since links resolve through the
file stem.

**One module answers "is this path a note".** `Vigil.Vault.Layout` is built
once from the vault — its domain directories, the project directories inside
`projects/`, and the `VIGIL_EXCLUDE` boundary — and classifies a path as a
note in a domain, a skill, excluded, or nothing this vault holds. Two of those
answers name what is missing, because the write gate words them differently: a
domain that is not there gets the list of the ones that are, and a project
directory that is not there is the one thing `create` may create. The write
gate asks before a write and the load asks for every file it walks, so what
vigil will write to and what it takes back are the same set of paths. The
nesting rule above is stated there and nowhere else: it used to be written once
in the write gate and once in discovery, agreeing by coincidence, so a second
nesting domain would have been writable-but-undiscoverable or
discoverable-but-unwritable depending on which of the two was edited.

One path changed hands when the two statements became one. `projects/x.md` — a
note directly in the nesting domain, outside any project — used to be
writable, because the gate reached its "two segments, that is a note" branch
before it reached the branch that knows `projects/` nests. Nothing ever loaded
it: discovery has always looked exactly one level deeper there, so the note was
written, committed, pushed, and never indexed or read back. It is refused now.
That is the disagreement being closed rather than a rule being added — the
nesting rule above already said where a note in `projects/` lives.

Whether a path is *safe* is a different question and stays with
`Vigil.Slug.safe_path/1`: traversal, absolute paths, backslashes, NUL bytes
and dot- or underscore-prefixed segments are about a caller's manners, not
about the shape of a vault.

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
three is read when the vault is loaded — at startup, on `reload`, and when an
update adopts what another clone pushed:

| Fact | Source | Fresh as of |
|---|---|---|
| Domain names | live directory listing under the vault root | every call |
| The raw text of `_domains.yml` | `File.read` per `Vigil.Store.instructions_domains_text/0` | every MCP `initialize` |
| The parsed `naming` rules | `Vigil.Store` state | startup, `reload`, and every update that adopts remote commits |

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
bug could accidentally return. An excluded domain is not walked at all. An
excluded directory below a domain is walked once for its file names, which
`Vigil.Vault.Layout` drops before any file is opened.

**A name is excluded at any depth.** A path is excluded when any of its
segments is, so `VIGIL_EXCLUDE=secret` hides `projects/secret/` exactly as it
hides `secret/`. It used to compare a path's first segment only, which covered
the domains and missed the one level below them: a project directory carrying
an excluded name was parsed, indexed, searchable and writable, and nothing told
whoever had set the variable. The rule is stated once, in `Vigil.Vault.Layout`,
so the load and the write gate cannot disagree about it. It is answered before
the path's shape and before whether the directory exists, so every write path
refuses an excluded path as "Invalid path" — the words an excluded domain gets —
whether or not it is there, and `create_dirs` does not create one.

The difference from a flag inside `_domains.yml` is essential: a process cannot
change its own environment variable, but it can change a file in the vault.
Anything that must genuinely stay hidden from the assistant belongs in
`VIGIL_EXCLUDE`, not in a marker inside a file the assistant can read.

The boundary travels with the vault it applies to. `Vigil.Store` is handed
both at start; so are `Vigil.VaultCheck` and the walk behind
`mix vigil.slug_diff`, the two other callers that take a vault path as an
argument. The mix tasks read the setting once and pass it. That is what lets
the doctor — the one module whose whole job is reporting on the vault — be
asked in its own suite whether an excluded directory really produces no
finding of any kind, rather than having the boundary read out from under it.

### `skills/` — one repository, two systems

`skills/` holds instructions for the assistant. For vigil it is invisible: not
parsed, not chunked, not searchable, no backlinks. Access only through the
`skill_*` tools.

The reason is a category difference: a note is a statement about the world and
ages. A skill is an instruction to the assistant and does not. They share a Git
repository and nothing else.

**A skill write goes through the single writer; a skill read does not.**
Principle 2 is a rule about writes, and a skill write earns the mailbox: it
commits and pushes, in order with note writes. The two reads inherited that
routing without the argument and paid for it — the push runs inside the
writer's handler, so a skill read queued behind a network round trip, and a
skill read is the mandatory bootstrap in front of every write (Security model,
layer 4). They are answered in the caller's own process now, against the vault
path `Vigil.Store` publishes at startup rather than answers questions about.
`Vigil.Skills` takes that path as a plain argument and holds no state of its
own, which is what makes the two reads free to leave.

**Replacing a skill takes `confirm: true`; a protected skill is not written
through MCP at all.** A skill is an instruction every later session follows,
and `vigil-vault-conventions` is the one every session reads before it writes.
An instruction smuggled into something the assistant read could otherwise
change what every session after it is told — with one call, unasked. So
`skill_write` creates a skill that does not exist as before, but refuses to
replace one that does unless the call carries `confirm: true`, in the same
words `delete_note` and `move_note` refuse with. A short, fixed list in
`Vigil.Skills` — `vigil-vault-conventions` and nothing else so far — is
refused whatever the call carries, created or replaced, and the refusal points
to "Editing by hand" in the guide: those change as a commit through the
remote, where a human wrote them. `init.sh` installs the conventions skill that
way too, as a commit of its own pushed before the service starts, and keeps a
vault's own. The checks are `Vigil.Skills`'s rather than `Vigil.Vault.Policy`'s,
which owns the note rules and never sees a skill; both run inside the writer,
after the vault is brought up to date, so "exists" is the remote's answer. A
refusal is not remembered under a `request_id`, so the confirmed call it asks
for can carry the same one, and the retry of a confirmed replace is answered
from the first — it is not refused for replacing the skill it just wrote.

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
  `starts` and `ends` (ISO 8601 **with offset**), both or neither, and `ends`
  is not before `starts`.

No `status`, no `valid_until`, no `provenance`, no `tags`. Each of those is
either derivable or was deliberately rejected.

**`Vigil.Vault.Frontmatter` owns that rule.** It takes a type and the raw
`starts`/`ends` beside it and answers with the parsed values or with a typed
problem. Each caller renders that verdict in its own register rather than
restating the rule: `Vigil.Vault.Policy` as the refusal the write gate hands
back, `Vigil.Parser` as the downgrade to `reference` plus a warning,
`Vigil.VaultCheck` as a finding. No module states any part of the rule except
the owner.

The owner exists because the three statements had drifted. The write gate had
no ordering rule at all, so it accepted an event whose `ends` preceded its
`starts` — and the parser then downgraded that same note to `reference` when
it indexed it. The file on disk said `type: event`, the index said
`reference`, `current` never saw it, and the doctor reported the note vigil
itself had just written. Vigil is the vault's only writer (principle 2), which
is what makes a write path that can produce a note its own reader refuses
indefensible: there is no second writer to blame it on.

The doctor had drifted the other way. It checked that an event carried a
`starts` and never that it carried an `ends`, so a note the write gate refuses
passed the doctor; and its ordering check quietly returned nothing for a
timestamp it could not parse, which is the exact input the write gate refuses.
Both halves are gone with the rule they restated.

**Parsing is defensive.** Missing frontmatter, unparsable YAML, and every
verdict the owner refuses — a missing or invalid `type`, an event without both
timestamps or with unparsable ones or with its `ends` first, and `starts`/`ends`
on a note that is not an event — all produce a warning with path and reason,
and the note is parsed anyway and treated as `reference`. The server always
starts, nothing is lost, nothing crashes.

The last of those is wider than it was: a `decision` carrying a stray
timestamp used to index as a `decision` with the timestamps dropped, and now
downgrades like any other frontmatter the vault does not allow. That follows
from the rule having one owner — the reader applies the verdict it is given
rather than a subset of it — and it costs the note its place in `lint`'s stale
report until a human fixes the file. Vigil never writes such a note: the write
gate refuses it on the same verdict, so it can only arrive hand-written, and
the doctor names it.

**A note without frontmatter is given one when asked.** It is an expected
finding of adopting an existing vault, and `update_frontmatter` writes the
block such a note lacks in front of it, leaving every byte of what was there
as the body — the one exception being how the file ends, which
`Vigil.Markdown` decides for every write ("How a file is written"). That is
not the server repairing on its own initiative (principle 5): the line runs
between what vigil does unprompted, which is report, and what a tool call
explicitly asks for, which it does. `rewrite_note` still refuses such a note,
because it preserves the block it finds and has no type of its own to write,
and its refusal names `update_frontmatter`. A block that opens and never closes
is refused by both: where it ends, and so where the body starts, is not
something the file says, and neither write guesses.

**`update_frontmatter` changes only the keys vigil owns.** Those are `type`,
`starts` and `ends`; every other key in the block — `tags`, `aliases`, whatever
an adopted vault's author or another tool put there — is the human's, and
survives the call. The rule above is what vigil *writes*, not what it demands
of a block it did not write: "no `tags`" means vigil never adds one, not that
it removes one it finds. The edit works by line, in `Vigil.Vault.Edit`: an
owned key already in the block is replaced where it stands, a missing one goes
after the owned key before it (`type` at the top of the block), and `starts`
and `ends` are removed when the note stops being an event, since only an event
may carry them. Every other line stays byte for byte and in its order,
comments and blank lines included, and the file keeps its line endings and
byte order mark ("How a file is written").

YAML decides only whether the block may be edited that way. It must parse to
a mapping before the edit and after it, and the keys vigil does not own must
parse to the same values after it as before. A block that does not parse, or
where the line edit cannot tell what to replace — an owned key whose value
runs over several lines, one written twice, one quoted or inside a flow
mapping — is refused with a message naming the reason, and nothing is
written. Silently dropping a human's keys is the failure this rule replaced:
the tool used to write a fresh block holding only the owned keys, so the first
type fix in an adopted vault lost everything else the block said.

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
whose id is the path with no fragment: the note's **preamble**. The blank lines
between the title (or frontmatter) and its first content line are no part of
it, for the same reason the separators between sections are not.

**The preamble is read as the note's `body`.** `read` of a path returns the
preamble as `body` next to the table of contents, which lists the chunks that
have a heading; the two together cover every chunk of the note, so whatever
`search` finds, `read` of the hit's id hands back. A note with no preamble
answers `body: ""`, so a note read has one shape. A short memory — a title and a
paragraph, no `##` — is read in full this way. The alternative, an id of the
preamble's own that the table of contents lists, was rejected: it is a second
id scheme for a chunk that already has one, the path, and every chunk id and
slug stays what it was. The preamble carries no `hash`: no section edit can
name it — `replace_section` and `delete_section` take a `path#heading-slug`
only — so a hash for it would be a promise nothing takes back.

Chunk id: `path#heading-slug`, for example `bike/via-carolina.md#fueling`.

**A chunk id is unique within its note.** A heading takes its slug, unless a
heading above it in the same note already took that id; then it takes the
first of `slug-2`, `slug-3`, … that no heading above it took. Document order
decides, so the heading that arrives at an id first keeps it: `## Setup`,
`## Setup`, `## Setup 2` are `setup`, `setup-2` and `setup-2-2`. The index
holds chunks by id, and two chunks under one id are one chunk to every reader —
the other is on disk and in no search, no `read` and no link.

`heading_path` carries the chain of heading texts for display
(`File title › Fueling › Second Half`); the chunk id uses only the slug of the
heading itself.

**One chunk, one owner.** A chunk is a `Vigil.Parser.Chunk`, and there is no
second struct restating its fields: the parser produces it, `Vigil.Index`
holds it, `Vigil.Vault.Edit` splices a note's lines by it. A field added to a
chunk is added in one place, and what the line numbers it carries mean is
documented on that struct and nowhere else — this document included. What the index adds as it indexes a chunk is the note's `domain`
and title, denormalised onto it: search filters by domain and titles every hit
per chunk, and asking the note per chunk would put a lookup back onto the path
this whole section exists to keep cheap.

This is what keeps retrieval cheap: the assistant fetches one section, not a
3000-word file.

---

## Search

All of the following is decided in `Vigil.Index.search/2` — one module, one
result shape.

- Literal matching, no regex over the text: `String.contains?/2` over the note
  title and each heading, `:binary.matches/2` counting occurrences in the chunk
  body.
- **Query and text are folded alike.** The query is trimmed, then query and
  text go through `Vigil.Slug.fold/1`: NFC, downcased, and the transliteration
  paths are slugged with (`ä` to `ae`, `ß` to `ss`, remaining diacritics
  stripped). `heizoel` finds `Heizöl`, and a body a macOS editor wrote
  decomposed (NFD) is found by a composed query. The text is folded once, as
  a chunk is indexed — every chunk carries its folded title, headings and body
  beside the originals, in place of the downcased body it used to carry.
  Previews come from the original.
- **The phrase is the strongest signal, the words the fallback.** A chunk that
  holds the folded query as one contiguous phrase is a *phrase hit*. A chunk
  that does not, but holds every word of the query (a run of letters and
  digits) somewhere in its note title, headings or body, is a *words hit*:
  `raised bed tomatoes` finds a section on tomatoes in the raised beds. Every
  word must be there; there is no OR. The callers are assistants, whose
  queries are keyword lists, and a phrase-only search left memories that hold
  every word unfindable, so they were written a second time. This reverses
  the earlier rule that the query is only a phrase, with no token split.
  A word of one character is not one of them (`C#`, `Plan B`): it is in
  nearly every chunk, inside longer words too, so it would narrow nothing
  and cap a hit's score at a few stray letters. It stays in the phrase, and a
  one-letter query is matched as the phrase it is.
- **Every word must be in the one chunk**, not merely somewhere in its note.
  The ticket that brought the words in (#211) asked for them "anywhere in the
  chunk or note"; that was narrowed, deliberately. A result is a chunk, and
  its title, headings and body are what the words are looked for in (the
  note's title is part of every chunk of it, so a word in the title counts
  everywhere in the note). A note-wide match would return a chunk that holds
  one word for a query whose other words sit in a sibling section — a hit
  the caller then reads and finds nothing in — and would rank every chunk of
  a long note alike. A query whose words are spread over a note's sections
  finds each section by its own words, and `read` of the note gives the
  whole.
- Filters apply *before* matching: `domain`, `type`. `journal/` is hidden
  unless it is the `domain` asked for.
- Ranking is a simple additive score, deliberately not BM25 and deliberately
  not machine-learned: title hit +10, heading hit +5, body occurrences +1 each
  capped at 5, `type == prefer` +5. A phrase hit scores its phrase. A words
  hit scores each word on the same scale as if it were the query, and takes
  the weakest word's score — a hit is only as strong as the least of the
  words it has to hold — plus the `prefer` bonus. Score 0 drops out.
- **Every phrase hit ranks above every words hit**, whatever their scores;
  the score orders hits within each group. Ties break on the more recently
  updated chunk, then on the id, so the same query over the same vault answers
  in the same order.
- Results carry only `id`, `title`, `type`, `score`, `preview` — and `hub` when
  the note has exactly one incoming link. Never bodies. They come a page at a
  time, as `{results, next_cursor}` (see "Reads that enumerate are paged").
- Still literal: no stemming, no fuzzy matching, no synonyms, no embeddings
  (see "Deliberate non-goals"). A word matches wherever its folded letters
  appear, inside a longer word too, as the phrase always did.

---

## Reads that enumerate are paged

`search` needs a query and drops what scores 0, and `read` resolves one note
at a time, so nothing answered "what is in `training`?" or "what changed this
week?". **`list` enumerates notes**: a card per note — `id` (its path),
`title`, `type`, `updated_at` — never a body, filtered by `domain` and `type`,
sorted by `updated` (most recent first, a note git knows no date for last) or
by `title` (folded as search folds, so `Äpfel` sorts with `apfel`), ties
broken on the path. `journal/` is left out unless it is the `domain` asked
for — the same rule, the same function, as `search`'s. Its `limit` is
`1..100`, default 25: a card is a line, a search hit is a preview.

**`search` and `list` answer page by page**, as `{results | notes,
next_cursor}`; `next_cursor` is `null` on the last page and is always there,
so the shape does not depend on the answer. The cursor is an offset into the
whole ordered answer together with a fingerprint of that answer — the call
(the operation and every parameter except `limit` and `cursor`) and the sort
key of every item, in order — base64url-encoded and opaque to the caller.
While nothing is written the same call orders the same items the same way,
the fingerprint matches, and the pages together hold every item once, in the
order a single long page would have. `limit` may change between pages.

**A cursor made stale by a write is refused, not continued.** A write that
changes what the call answers, or the order, changes the fingerprint, and the
call is a tool error saying to start again without a cursor. Continuing at the
old offset would skip an item or show one twice without a word, and a caller
paging through "everything in `training`" would take the gap for the answer.
Keying the cursor on the last item's sort key instead would continue past a
write, but it is as long as the item's id — a path near its 1,024-character
bound does not fit in a parameter of the same bound — and a note that moved in
the order would still be skipped silently. A write the call does not see (a
note in another domain, for a `list` of one) leaves the cursor valid. The
fingerprint is a 32-bit hash, so a stale cursor accepted by collision is
possible and vanishingly rare; the cost of one is one misplaced page.

**The other unbounded answers are capped and say so.** `lint` lists at most
50 findings per category, each category in a fixed order (by path or id) so
the same 50 come back on every call; `totals` counts every finding per
category and `truncated` is `true` when any was cut. `links` at depth 2
describes at most 25 neighbouring notes, the first by path, with `truncated`
beside them. A cap that says nothing is the silent clamp "MCP tool schemas
are authoritative" refuses for `limit`.

---

## Path normalization and naming rules

Three layers guard every write, in this order.

**1. Security.** No `..`, no absolute paths, no backslashes, no null bytes, and
no path segment starting with `.` or `_`. Checked before *and* after
normalization — which is not a fact each caller has to hold.
`Vigil.Slug.canonical/1` is the two steps in that one order with both checks,
and every caller that turns a path a caller typed into the path the vault
stores asks it or the `canonical_path/1` beside it. The two differ on one
answer and nothing else: a path no filename can be derived from comes back
unchanged from `canonical_path/1`, because a reader answers for it the way it
answers a miss, and as `{:error, :empty}` from `canonical/1`, because
`Vigil.Vault.Policy`'s `:create` and `:move_note` have a sentence of their own
to say about it — and because `:create` also reports what normalization
changed. `safe_path/1` stays public for the write gate's other question —
whether a path names a writable note at all — which is asked of a path that is
not being normalized there: the one an operation on an existing note was
given, or the canonical form an earlier step already produced.

The order is load-bearing: normalization slugifies every segment, so it turns
`_domains.yml` into `domains.yml` and `/abs/x.md` into `abs/x.md`. A path
checked only afterwards is a path whose check the normalization has laundered.

The rule lives in `Vigil.Slug`, beside the normalization it is applied under.
It is not a permission check — `skills/tdd.md` passes it — which is why `read`
and `links` can apply it without inheriting the write rules, and why a reader
may still reach a note in a domain that is no longer writable.

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

`Vigil.MCP.Tools` declares each tool once — name, title, description, the
`write` flag, the `Store` operation it calls, its four MCP hints, and its
parameters' names, types and required-ness — in a single table. Three things
are generated from it: the JSON schema and annotations published on
`tools/list`, the argument validation `dispatch/5` runs on `tools/call`, and
the `Vigil.Store.call/3` that follows. They cannot drift out of agreement the
way hand-written twins do, and adding a tool is adding a row.

**Every row states all four hints.** `readOnlyHint`, `destructiveHint`,
`idempotentHint` and `openWorldHint` are published as the tool's
`annotations`, beside a human-readable `title`. The spec's default for a hint
left out is the cautious one — destructive and open-world — so a server that
declares nothing tells a client that `search` is as dangerous as
`delete_note`, and its user learns to approve everything. A row that omits a
hint, or the title, is a compile error rather than a tool quietly described by
those defaults. The read tools are read-only. `delete_note`, `move_note`,
`rewrite_note`, `delete_section`, `replace_section`, `update_frontmatter` and
`skill_write` are destructive — each can take away what the vault already
says — while `create` and `append` only add. The hints are not derived from
`write:`, because the two say different things: `write:` is what a token needs
the `vault` scope for, the hints are what the tool does. `reload` keeps them
apart. It stays callable with `vault:read` (see "Security model"), yet it is
not read-only and it is the one open-world tool: it moves the vault to
whatever the remote holds. The same `write:` flag decides what `tools/list`
shows — a token that may not write is listed only the tools it may call.

**The call is the table's third product.** A row's `call:` names the
operation; its parameters travel under the names the table gives them.
`Vigil.Store` answers all but three of them — the two skill reads are
answered against `Vigil.Skills` in the caller's process, for the reason under
"`skills/` — one repository, two systems", and `status` by
`Vigil.Store.status/2`, which asks the writer with a timeout of its own so a
writer that does not answer cannot take the report down with it. The one
exception is `skill_key`, which is a parameter of no operation — it carries the
SkillKey of the Security model's layer 4, the gate reads it, and it does not
travel.

**`skill_key` is also one of two parameters no row declares.** A tool takes
one because it writes, and the row already says `write: true` — the same flag
the gate reads the requirement off. So the parameter is derived from it too,
stated once rather than written out identically in nine rows, each free to
drift in its description or its required-ness while the gate went on requiring
the same thing. The other is `request_id`, optional on every write for the
same reason, and a parameter of the operation: it travels to the writer, which
is what remembers it (see "A retried write is applied once"). `confirm` is not derivable the same way and stays declared per
row: only four of the nine writes take one, and `write: true` does not say
which. An enum's internal form is the atom of the same name, derived once from
the values the table already declares rather than restated in each tool's
dispatch; that restatement is what let `search` convert its `type` while
`create` passed the same enum through as a string. Whether an answer is lifted
into `{:ok, value}` is read off the shape the Store returns — an operation that
cannot fail answers with its value, one that can answers with a result tuple —
rather than from a flag in the table that would be free to disagree with it.

What the table cannot supply is the `Vigil.Store.call/2` head, which is a
contract rather than a restatement (see "The write path"), or an entry in the
dispatch coverage the suite drives every declared tool through. A row whose
`call:` names no operation compiles and publishes; that coverage is what fails
it, so the last step of adding a tool is exercising it there.

Every declared parameter is validated against the schema the server itself
publishes. A violation — a wrong type, an off-enum value, an out-of-range
integer, a string over its maximum length (see "Input sizes are bounded"), a
missing or empty required parameter, `arguments` that are not an
object at all — is a tool error naming what was expected, not a substituted
default. A caller who claims `type: "bogus"`
gets told so, rather than receiving unfiltered results it believes were
filtered. Undeclared
parameters are ignored: the schemas do not set `additionalProperties: false`,
and rejecting extras a client legitimately sent would fail callers over
something the server never declared.

**One shape for every tool-facing call, all the way down.**
`Vigil.Store.call/2` takes an operation and a params map — not a positional
pair for `read`, a positional triple for `links` and a map for `search` — and
so does the `Vigil.Index` function that answers it. The difference between two
tools is the map, so a parameter added to a read tool changes the table and
the index function that reads it, and nothing in between: not a client
function, not a message shape, not a `handle_call` clause, and not an argument
list that unpacks the map back into the positional triple it replaced.

The seven reads share a single `handle_call` clause and so do the eight writes,
because in both groups the operation is the only difference: it names the
function that answers a read — `Vigil.Index`'s, or for `history` and `read`
at a revision `Vigil.History`'s — and `Vigil.Vault.Policy` and
`Vigil.Vault.Plan` already take a write as an argument. What stays per
operation is the contract — the head that matches what a call cannot do
without.

A bound is part of that declaration, not a correction applied afterwards.
Integer parameters carry a range in the table (`search`'s `limit` is
`1..25`, `list`'s `1..100`, `depth` is `1..2`), the range is published as `minimum`/`maximum`, and a value outside it
is refused there. Nothing downstream clamps: `limit: 100` is an error, not a
quiet 25, because a caller told it received the 25 best hits of 100 asked for
cannot tell that from having asked for 25.

---

## Input sizes are bounded

A note is parsed several times per write, and every parse runs inside the
single writer (see "The write path"). How long one call can keep every other
read and write waiting is therefore a question of how much text it can hand
the writer, and of how the parser spends its time on that text. Both are
bounded.

**Every string parameter declares a `max_length`.** It is part of the row,
like an integer's range: published as `maxLength` on `tools/list`, enforced by
the same validation that checks the type, and refused before the writer's
mailbox is reached with a tool error naming the parameter
(`Invalid parameter content: expected at most 1000000 characters`). A row that
declares a string without one does not compile. Two sizes cover every
parameter, counted in characters (Unicode code points, as JSON Schema counts
them):

| Parameter | `maxLength` |
|---|---|
| `content` (`create`, `append`, `replace_section`, `rewrite_note`, `skill_write`) | 1,000,000 |
| every other string — `path`, `id`, `from`, `to`, `query`, `domain`, `heading`, `name`, `starts`, `ends`, `if_match`, `at`, `cursor`, `request_id`, `skill_key` | 1,024 |

A million characters is a book rather than a note, and nothing a real vault
holds comes near it; it exists to put a ceiling on the parse, not to shape how
notes are written. A thousand characters is a path or a heading nobody writes.
More sizes — one for paths, one for timestamps, one for keys — would each be a
number to justify and document, and would bound nothing the writer cares about
that 1,024 does not already.

**The `/mcp` body is read up to 8,000,000 bytes**, stated in
`Vigil.MCP.Server` rather than left to Plug's default. It stays above the
longest argument the table admits — a million characters of up to four bytes
each in UTF-8 — plus the rest of the message, so a note that is too long is
refused by the validation that names its parameter, not by the transport.
It is deliberately not raised to cover the same argument sent escaped: JSON
lets a client spend six bytes on a character (`\uXXXX`) and twelve on one
outside the Basic Multilingual Plane (a surrogate pair), and a limit of twelve
times the longest `content` would let every request hold half again as much
memory, for a client that escapes a book's worth of emoji. Such a body is
refused all the same, only in the transport's words. A body over the limit is not read to its end and is answered `413` with a
JSON-RPC error (`-32600`, `id: null`): there is no complete message to take an
id from, and a client should learn why in the protocol's words, not from an
empty `400`.

**Heading recognition is linear in the line's length.** The pattern captures
a heading's text greedily and trims it afterwards. The lazy form it replaced,
`(.+?)\s*$`, retried the trailing whitespace once for every position the text
could end at: time quadratic in the line, until PCRE's match limit gave up and
a long heading silently was no heading at all. A heading line of 100,000
spaces is now recognized in well under a millisecond.

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

**The seam names both of its answer sets.** `Facts.over_vault/3` builds the
production one — a pure function of the index, the vault's plain facts and the
write's instant, returning the adapters that will read the filesystem and the
index — and `Vigil.Vault.AbsentFacts`, which lives with the tests because only
they have a use for it, builds the one that answers "nothing there". The
production set used to be a private closure inside `Vigil.Store`'s `GenServer`,
which meant the claims it makes could only be reached by starting the writer
against a real git vault and performing a write. Three of them are load-bearing
and now have tests of their own: that the similarity search carries no
preferred type, which is what makes the duplicate gate's threshold mean what
`Vigil.Index.strength/1` says it means; that the write's date is the instant
handed in rather than a clock read of its own; and that the depth the policy
asks with is the search's limit.

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
one in half. Content appended into an existing section must also not leave a
fenced block open, and neither may a `replace_section` replacement, with the
same message: both splice into the middle of a note, and an unclosed fence
would turn every line below it into code, taking the chunk ids and links of
every section there with it. The heading argument itself is one non-empty
line: a line break in it would write the rest as lines of their own — another
heading or a fence — and a blank one writes a `## ` line that is not a
heading.

**A section id is resolved once, through one function.** `replace_section` and
`delete_section` take an id, and the policy resolves it through
`Vigil.Index.find_chunk/2`, which goes through the same `resolve/2` that
`read/2` and `links/2` do — so an id that reads is an id that writes by
construction rather than by two walks agreeing. It was the second: `read`
checked that the id's path part was safe to resolve and `find_chunk` did not,
so `/bike/via-carolina.md#gear` — which normalizes onto a real chunk id —
resolved for the write path and was refused for the read path.

**Safety and the canonical form come back together**, from
`Vigil.Slug.canonical/1` and the `canonical_path/1` over it. Normalization
slugifies every segment, which turns `_domains.yml` into `domains.yml` and
`/abs/x.md` into `abs/x.md`, so a path checked only after it is normalized is
a path whose check the normalization has laundered. That order used to be a
fact each caller had to know — checked before normalization in
`Vigil.Vault.Policy`, again after, under a comment explaining why. It is one
function's now, and a caller that does not hold the order cannot get it
wrong.

The write then goes to the resolved record's canonical path, never to one
re-derived by splitting the id on its fragment. That is what makes the leniency
safe: a normalized id writes where the lookup landed, not where the id pointed.
What may be written is still judged before what is there is looked up, so an id
naming `skills/` or an excluded domain answers "Invalid path" rather than
"Not found" — a refusal must not confirm that a path it will not touch exists.
`Vigil.Vault.SectionIdParityTest` is where the whole of this is asserted rather
than documented: one table of id shapes, and `read`, `links`, `replace_section`
and `delete_section` answering each of them.

**The duplicate gate keys on the note's name.** Before `create` writes, the
policy asks the vault for notes in the same domain that look like the one being
created and refuses with the candidates named, unless the call passes
`force: true`. What it searches for, how deep, and how strong a hit has to be
are stated together in `Vigil.Vault.Policy`, because they are one decision:
the terms are the note's whole name plus each `-`-separated segment of at least
four characters, each term is asked for the best 25 hits in the domain, and a
hit counts when it reaches `Vigil.Index.strength(:title)` — the score at which
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
at least as high. That holds for a words hit too (see "Search"): the name's
`-`-separated segments are its words, and a words hit scores its weakest word,
so the name as words never outscores a segment of it. What it costs there is one
more query per create, and the one note it can still surface on its own: the
one a broad segment's best 25 had no room for.

**The write path returns a plan; the process executes it.** A resolved
decision plus the note's current content becomes a `Vigil.Vault.Plan`: the
action to perform and the commit message to perform it under. Three actions,
because there are three shapes of write — `{:write, path, content}` for the
six content-shaped operations, `{:delete, path}` and `{:move, from, to,
rewrites}` for the two git-level ones. Building a plan performs no effect and reads no file,
so every write operation can be exercised without a vault, a git repository or
a running GenServer. `Vigil.Store` is left with the sequence — ask the policy,
read the note, build the plan, execute it — and the effect.

Order matters: perform the action, commit, reparse into the index, then push.
It is stated once, where a plan is executed — one clause for all three actions,
with what differs between them answered per action, one small function per
question: which effect to ask `Vigil.Commit` for, what the index does with what
comes back, what the success report says, and what object a push failure names. A report that can only be
*observed across* the effect — the references a move broke, a diff of incoming
links before against the rebuilt index after — is asked before the effect and
answered against the index it left behind, so that no action has to be a
special case of the sequence. If the push fails the local commit stays and the
tool still answers success, with `pushed: false` and a `push_error` naming what
is committed locally but not pushed — the change, the deletion, or the move —
so a client does not retry a write that happened. Nothing is rolled back. A failed *commit* is
the opposite case: everything is (see "A failed commit leaves the vault as it
was").

**A move can take its links along, in its own commit.** `move_note` with
`update_links: true` rewrites every link that resolved to the note so it
resolves to the new path, and the rewrites travel in the move's action as
`{path, content}` pairs that `Vigil.Commit` writes after the `git mv` and
commits with it — one change, rolled back as a whole (see "A failed commit
leaves the vault as it was"). What each link becomes is the index's answer
(`Vigil.Index.relinks/3`): only links that resolve to the note now and would
not after the move are touched; a basename stays a basename where
`Vigil.LinkIndex`'s cascade, asked about the vault as it will be, still finds
the note, and becomes the vault-relative path where it would find another
note or none — a path cannot be ambiguous. The rewrite itself is the link
parser's other half (`Vigil.Parser.rewrite_links/2`): the same two patterns,
the same reading of fenced and inline code, and only the target changes —
link text, alias and `#fragment` stay as written. It skips the frontmatter
block, the title and heading lines too: none of them is a chunk body, so neither holds a link
the index knows, and a rewritten heading would change a chunk id. Without the
flag a move changes nothing but the note and reports `broken_backlinks` as
before; a note's links to itself are looked for under their new ids in that
report, so a self-link that still resolves is not reported as broken.

**A rewrite says which section links it broke.** `rewrite_note` can drop or
rename a section another note links into. Which links that broke is a diff
across the effect, so it is observed the way a move's is: the links into the
note's sections from other notes are asked before the write, and each one that
no longer resolves afterwards is reported as `broken_chunk_links`. The plan
asks for the observation (`observe: :broken_chunk_links`), because the action
is the same `{:write, path, content}` every content-shaped operation has; the
other section edits keep the result they had.

**Confirm is the last gate, not the first.** `delete_note` and `move_note`
resolve their paths before asking for confirmation, so a path naming `skills/`,
an excluded domain or a traversal answers "Invalid path" rather than quoting
itself back in a destructive-operation prompt for a write that would be refused
on the next turn.

Commit author is `vigil <vigil@local>`, set with `-c` on the call rather than
in the repository config, so manual commits keep the human's identity. That
makes `git log --author=vigil` the provenance query: every line in the vault is
attributable to either the assistant or the human.

**A human edit arrives as a commit, never as a file.** Nothing but vigil
touches its working tree, so a human change — made in Obsidian with Obsidian
Git, or by hand — is made in a clone, committed under the human's own
identity and pushed to the remote. The next load (a restart or a `reload`),
the next write and, once an interval has passed, the next read fetch it and
rebuild the index from the result (see "The server stays in step with the
remote" and "Reads see what another clone pushed"). With no unpushed commits of its own
vigil fast-forwards. With some — typically one whose push was refused
because the human pushed first — it rebases them onto the remote: vigil's
commits are its own single-file changes, and replaying them on top of the
human's keeps both histories, a linear log and the provenance query honest.
Nothing is ever merged. A rebase that conflicts, both sides having changed
the same note, is aborted at once: vigil's commit stays local, the remote
keeps what the human pushed, and the write's `push_error` or `reload`'s
`pull_failed` names the path. Resolving a real conflict is a human decision,
made in a clone, not one vigil makes on anyone's behalf.

`commit.gpgsign=false` is forced the same way. The service user has no signing
key; an inherited `commit.gpgsign=true` would otherwise fail every single
write.

**One writer per vault, under a name its caller supplies.** `Vigil.Store`
registers under its own module name by default, and a caller that hands in a
name gets a writer of its own, publishing through a table of that same name —
which is what lets the vault-backed test files run in parallel, one writer per
file, instead of the whole suite queueing behind a single registration.
Principle 2 is about a vault having one writer, not about a node having one.

**The tool layer takes the writer too.** `Vigil.MCP.Tools.dispatch/5` is
handed the store it calls, and the two skill reads resolve the vault path from
that same store rather than from the default one — a skill read answered
against another writer's vault is a read of the wrong vault. It defaults to
`Vigil.Store.default_name/0`, so production hands in no name and reaches its
own registration, and the atom is stated once, where the writer registers it,
rather than once per caller. `Vigil.MCP.Envelope.for_tool/5` is handed the
same store the call is, and `Vigil.MCP.Server` resolves it once, at `init/1`,
for both (see "The router names the writer, and the envelope with it").

**A failed write never takes the server down.** Filesystem errors are converted
to error tuples and never allowed to propagate into the GenServer. One failed
write must not cost read access to everything else. A caller that breaks a
declared contract outright — a `search` without a `limit`, a `links` without a
depth, a `read` without an id — is matched in `Vigil.Store.call/2`'s heads, so
it fails in its own process rather than in the writer's. A head states what
its operation cannot do without and never a *bound*: `depth` is `1..2` in the
tool table, which refuses `3` before the Store is reached, and a second
statement of the range here would be free to disagree with the schema the
server publishes.

The write effect itself belongs to `Vigil.Commit`: writing a file, deleting
one, moving one, pushing, and the wording for a POSIX error — everything it
takes to make a change to the vault, in one place, for notes and skills alike.
It sits at the top level rather than under `Vigil.Vault.*` for the same reason
`Vigil.Markdown` does: skills are never notes and must not depend on a
note-shaped module. What stays with each caller is what differs — the order
above, which `Vigil.Store` states where it executes a plan; the reparse
between commit and push, which would index a skill as a note; and each write
action's push-failure message, which names its own object: a change, a
deletion, a move, a skill.

---

## Git is reached through a value

`Vigil.Commit` is the write effect, and it does two things at once: it touches
the filesystem and it commits. The filesystem half stays where it is. The git
half is a value its callers hold rather than a module they name.

**The value is the whole of `Vigil.Git`, not the write half.** Sixteen
questions: `add`, `remove`, `move`, `commit`, `snapshot_index`,
`restore_index`, `push` — `log_metadata`, which no write ever asks,
`history` and `show`, which only the reads of the history ask (see "No audit
log — the history is read, not kept"), `tracking`, which only the boot check asks (see "The vault's remote and branch
are checked against the clone"), and `divergence`, `fetch`, `fast_forward`,
`rebase` and `abort_rebase`, which bring the vault up to date at boot, on
`reload`, before a write, before a read once per interval and after a refused
push (see "The server stays in step with the remote"). Staging and committing are separate questions, which is
what lets a test make a commit fail *after* its `git rm` has happened (see "A
failed commit leaves the vault as it was"). `log_metadata` belongs to the load, and
`Vigil.Store` asks it directly. A seam drawn around the write effect alone
would leave every load reaching for a repository, and `log_metadata` answering
`%{}` for a directory that is not one — which is a `created_at` of `nil` on
every note, arriving as an ordinary answer. The seam is drawn where git is,
not where the writes are.

**It is a struct of functions with no defaults**, built by `struct!/2`, the
same shape and the same rule as `Vigil.Vault.Facts`: a question added and left
unwired fails at construction rather than answering. The production adapter is
a function on `Vigil.Git` beside the contract it implements, not a set of
closures assembled by a caller — there are two callers, `Vigil.Store` and
`Vigil.Skills`, and an adapter assembled at the call site would exist twice.
`Store` builds it when it is not handed one; `Skills` has no default, because
it holds no configuration it could build one from. One default, in one place.

**The second adapter is a commit log, and it keeps the metadata.** It records
what it was asked to commit, under the instant it was handed, authored as
`vigil` — and answers `log_metadata` from that record. It does not read a
clock of its own. The alternative, an adapter answering "no metadata", was
rejected: it would put a `created_at` of `nil` under every test in the suite,
which is a shape production never has.

This is not a second metadata database, and principle 3 is untouched by it.
"Creation date = first commit" is a claim about where a fact lives and what
therefore must not be written into frontmatter. What the seam states is
narrower: a commit reports the instant and the author it was made under. Git
satisfies that claim by being a metadata database. The second adapter
satisfies it by remembering. Neither invents a fact the other derives — and
the one thing that could go wrong here, the two drifting apart, is the reason
the contract is tested rather than assumed.

**One suite runs against both adapters, and it is the only thing that touches
a repository.** Everything git actually owns is asserted there: that a commit
is authored `vigil <vigil@local>` whatever the ambient configuration says,
that a failed push leaves the local commit standing, that `move` and `delete`
are `git mv` and `git rm` rather than filesystem calls, that a first commit is
what `log_metadata` reports as a creation date. Every other test asserts
something about vigil and merely used to travel through git to do it — that a
write path leaves one trailing newline, that the index carries a `created_at`
across an append, that a push failure is reported in the words the operation
deserves. Those are claims about `Vigil.Markdown`, `Vigil.Index` and
`Vigil.Store`, and each of them now fails for one reason instead of two.

**No hook in the clone runs, and nothing is signed.** Every call that
commits, moves a ref or talks to the remote — `commit`, `push`, `fetch`,
`fast_forward`, `rebase` and `abort_rebase` — carries `-c
core.hooksPath=/dev/null`. The vault is a human's clone too, and a
`pre-commit`, `commit-msg`, `pre-push` or `reference-transaction` hook
installed there for their own work is not vigil's to satisfy: one that fails
would fail every write, the fetch before it and the push after it, and one
that succeeds may still rewrite what vigil committed. Signing is forced off
the same way — `commit.gpgsign=false` on every commit and rebase,
`push.gpgSign=false` on every push — because the service user has no key and
an inherited setting would otherwise refuse every write. `add`, `remove`,
`move` and the index snapshots move no ref and run no hook, so they carry
neither. The repository half of the contract suite installs a failing hook of
every kind that could fire and asks each of those calls to succeed.

The speed is a consequence and not the argument. The argument is that
`Vigil.Store`'s order — perform, commit, reparse, push — was the one part of
the write path with no test that could fail on it, because exercising it meant
building a repository. An adapter that records its calls can be asked what
order they came in.

---

## A failed commit leaves the vault as it was

A commit can fail — `HEAD` is detached, a lock is held, the disk is full — after
the working tree and git's staging area have already been changed: the file
written and added, `git rm` or `git mv` already run. A change that did not
commit must not stay behind. The index still describes the vault before it, and
the next write's commit would sweep the stray change in under its own message.
`write` used to put the file back and leave the staged blob; `delete_note` and
`move_note` put nothing back at all, so the note was gone or moved on disk
while vigil's index still held the old path.

**One change is all of it or none of it, for every path it touches.**
`Vigil.Commit` takes, before anything happens, what the working tree holds for
each path the change touches — its content, or that it was not there, and
every directory above it that did not exist yet — and asks the git value what
the staging area holds for them (`snapshot_index`). Then it changes the
working tree, stages, and commits. If any step after the snapshot fails, the
files are put back, the directories the change created are removed again, and
the staging area is restored path by path (`restore_index`), and the tool
returns the error. The mechanism takes a list of paths, not one: a move
already touches two, and a change that touches several files in one commit
rolls back the same way. A restore that itself fails is logged as an error
rather than reported: the change has already failed, and the caller cannot act
on a second failure, but the operator has to know about it.

The index is restored to what it held, not reset to `HEAD`. Nothing but vigil
touches the working tree, so the two are the same in practice; restoring the
snapshot is what makes "as it was" true without that assumption.

**Paths are paths, never patterns.** Every `git` call runs with
`GIT_LITERAL_PATHSPECS=1`. A note a human named `*.md` is otherwise a
pathspec, and `git rm -- bike/*.md` removes every note in the directory.

**A note is written beside itself and renamed into place.** The content goes
to a temporary dotfile in the same directory, which is then renamed over the
note. A rename within one directory is atomic, so a crash mid-write leaves the
old note and a stray dotfile — never a truncated note. Dotfiles are not notes
(`Vigil.Vault.Layout` does not list them), so a leftover one is never indexed,
and vigil stages only the paths it names, so it is never committed either. The
next load removes it: every file in a domain or in `skills/` named exactly as
`Vigil.Commit` names a temporary file (`.<note>.md.<n>.tmp`), and nothing
else — an excluded directory is not looked into.

Atomic is not durable, so the temporary file is synced before the rename and
the directory after it (best effort: not every filesystem answers a
directory's sync); a power cut between the two otherwise leaves an empty note
under the name. And the temporary file takes the replaced note's mode before
it is renamed, so a note kept private (`0600`) does not come back with the
mode the umask gives a new file.

---

## A retried write is applied once

A write can outlive the client's call timeout and still complete in the
writer. The client sees an error and retries. Two writes are not safe to
repeat: `append` adds its content a second time, and `delete_section` deletes
whichever section has since been renumbered into the deleted one's id — two
`## Setup` sections are `#setup` and `#setup-2`, and once the first is gone
the second is `#setup`. Three guards, one for each way a retry can go wrong.

**A write can name itself.** Every write tool takes an optional `request_id`,
derived from `write: true` like `skill_key` but, unlike it, handed to the
writer. `Vigil.Store` remembers, per id, a fingerprint of the write — the
operation and its parameters, without the instant the response was decided at,
which a retry has a new one of — and the result it answered. A repeat of the
same write answers that result again with `already_applied: true` and writes
nothing: one commit, however often it is sent. The same id with a different
write is refused rather than answered with a result that is not its own. Only
a success is remembered, since a refused or failed write changed nothing and
its corrected retry has to be free to run. Checking and performing happen in
one call inside the single writer, so a retry that arrives while the first is
still running queues behind it and finds its id.

**What is remembered is bounded twice** (`Vigil.RequestLog`): at most 1000 ids,
the oldest going first, and none for longer than an hour. A retry comes within
minutes of the call it repeats; a client sending a fresh id with every write
must not grow the writer without limit. The ids live in the writer's memory
only, so a restart forgets them. The alternative, a file of ids beside the
vault, was rejected: it is a second store to keep consistent with the
repository for a window measured in minutes.

**A section edit can name the content it read.** `read` hands out a `hash` for
every chunk a section edit can name — SHA-256 over its heading and body, never over its id or a line
number, which are positions — on a chunk read and on every entry of a note's
table of contents. `replace_section` and `delete_section` take it back as an
optional `if_match`, and `Vigil.Vault.Policy` refuses the edit when the chunk
the id resolves to no longer has that content. The retried `delete_section`
above is refused instead of taking the section that moved into the id. Without
`if_match` the id alone decides, as before.

**The index is checked against the file before anything is spliced.** A section
edit splices by the index's line numbers into the file as it is on disk, so
`Vigil.Vault.Edit` first checks that the line the chunk's `heading_line` names
still holds the chunk's heading. When the two have drifted apart the edit is
refused and asks for a `reload`, instead of landing in whichever section sits
at that line now. Only the heading's text is compared, since the chunk does not
record its rank.

---

## The server stays in step with the remote

The remote used to be pulled at boot and on `reload` only, and only as a
fast-forward. A human who pushed from a clone and did not call `reload` made
vigil's next write commit on top of a history the remote had already moved
past: the push was refused, the two histories diverged, every later pull was
refused and every later write stayed unpushed, and putting them back together
needed a shell on the host.

**Before every write, the vault is brought up to date.** All eight note writes
and `skill_write` go through one function in `Vigil.Store`,
`bring_up_to_date/1`, before the policy is asked. It fetches and asks git how
far the branch and its remote-tracking branch are apart. If the remote moved,
the vault adopts it and the index is rebuilt from the result — so the write is
decided against the vault as it now stands, lands on top of the human's
commit, and its push goes through. With no unpushed commits of its own the
vault fast-forwards. With some, they are rebased onto the remote (principle
2): git runs the rebase non-interactively, with the clone's hooks disabled
(see "Git is reached through a value"),
and commits the replayed commits as vigil, unsigned, like every other. A
rebase that conflicts is aborted, and the vault stays as it was.

The edit is resolved only after that, against the note as it now is. A section
id that resolved before the update and no longer does is refused with "no
longer resolves: the note changed on the remote since it was read. Read it
again before editing it" rather than "Not found"; an `if_match` or a heading
line that no longer matches is refused the same way it always was.

**A push the remote refuses because it moved is rebased and tried again.** A
human can push between vigil's update and vigil's push. After a failed push the
vault fetches again: if the remote holds something new, vigil's commits are
rebased onto it, the index rebuilt, and the push tried again — three times at
most, after which the write's `push_error` says the remote moved every time.
If the remote holds nothing new, the push failed for another reason, an
unreachable remote or a refusal, which no rebase helps, and the write reports
git's reason as before. A conflict stops the retries and is added to the
`push_error`, with the path; the write itself stays a success with `pushed:
false`, its commit local.

**The load is brought up to date the same way.** Boot and `reload` go through
the same update instead of a `git pull --ff-only`, so vigil's unpushed
commits survive a push from elsewhere: both histories end up in the vault,
vigil's on top, and the next push takes them out. What stops the update — an
unreachable remote, a conflict — is what `reload` reports as `pull_failed`,
and the vault is read as it stands regardless.

**Only vigil's own commits are replayed, and a force-push is followed.** The
fetch is forced, so the remote-tracking branch says what the remote holds even
after a human rewrote it — took commits away with `git push --force`, with or
without new ones on top. A plain `git rebase <remote>/<branch>` would then
replay every commit the branch holds and the remote does not, the removed ones
among them, and the next push would put back what the human took away; with
nothing new on top the remote is even an ancestor of the branch, the vault
looks merely ahead, and that push is a fast-forward nobody refuses. So what
counts as vigil's own is decided by the remote-tracking branch's reflog:
`git merge-base --fork-point` names the newest commit of the branch the
remote-tracking branch ever pointed at — every fetch and every push moves it
and records where it was — and only what comes after it, never pushed, is
replayed (`git rebase --onto <remote>/<branch> <fork point>`, what `git pull
--rebase` does). What lies before it and is no longer on the remote is counted
as `rewritten` beside `ahead` and `behind`, and an update that finds any
adopts the rewrite through that rebase, logging a warning that the remote was
force-pushed and how many commits it dropped. When vigil's own commits cannot
be replayed without what was taken away, the rebase conflicts and is aborted
like any other; the vault then still holds the removed commits, and `push`
refuses to run at all while `rewritten` is not zero — git would take it as a
fast-forward — so the write's `push_error` says the remote's history was
rewritten and names the conflict, and `status` shows `rewritten`. Where the
reflog does not reach back that far (it is expired, or disabled), the
remote-tracking branch is taken as the fork point, which is the plain rebase
again; nothing in a clone vigil runs in expires it sooner than git's defaults.

The decision is in that one function on purpose, so that what it adopts and
when is a change to it rather than a second path beside it — which is how
reads came to use it too (see "Reads see what another clone pushed").

**A rebase left in progress is aborted first.** A rebase stops with `HEAD`
detached, and a writer that stops in the middle of one — killed, the host
rebooted — leaves the clone that way. Everything committed after it would be
on no branch: the push names the branch, finds it up to date, and the write
is reported pushed while it never leaves the host. So before the load, the
writer asks `tracking` whether a rebase is in progress and, if so, aborts it
through the Git value and logs a warning; the branch is back where it stood,
vigil's commits on it, and the update that follows starts the rebase again if
it is still due — or, offline, leaves it for the next one. And `commit`
refuses a detached `HEAD` outright, so a clone that got there some other way
fails the write, with the staging undone like any failed commit, instead of
losing it; `status` reports `on_branch: false` and `/healthz` answers 503
until someone checks the branch out again.

**Nothing about it can fail a write.** A fetch, a fast-forward or a rebase
that fails is logged, and the write goes ahead on the vault as it was; its
push then says what is in the way. The fetch is bounded the way `push` is
(`Vigil.Git`'s network environment), so a remote that stalls costs a write its
connect and stall timeouts, not the writer. The questions it asks —
`divergence`, `fetch`, `fast_forward`, `rebase`, `abort_rebase` — are on the
Git value like every other (see "Git is reached through a value"); only
`fetch` leaves the machine.

**`status` and `/healthz` say whether it is.** Both report the same facts: is
the index loaded, does the writer answer, how many commits is the vault
`ahead` of the remote and `behind` it, how many of those ahead a force-push
took off the remote (`rewritten`), the last push's result and time, and
`stale` — `null` while the last attempt to bring the vault up to date
succeeded, otherwise when it failed and why. `ahead` and `behind` are read
locally — `behind` is as fresh as the last fetch, which happens before every
write and, at most once per interval, before a read. A conflict shows here as a vault both
ahead and behind, with the path in the last push's error. `Vigil.Store.status/2` answers in the
caller's process: whether the index is loaded is read from the writer's table,
and the writer is asked the rest with a timeout of five seconds, so a writer
that does not answer is reported instead of waited on.

*Healthy* means the index is loaded, the writer answers and `HEAD` is the
branch it pushes (`on_branch`) — `/healthz` is 200 then and 503 otherwise. A failed push or a vault that is ahead is reported in
the body, not in the status code: the service is serving, the commits are
safe locally, and the push safety net pushes them without the writer ever
noticing, so a status code tied to the last push would stay red after the
problem was gone. Deciding otherwise would also make `update.sh` roll back a
release because of the network.

**`/healthz` answers on the host only, and without a token**, because
`update.sh` waits on it after every start, before a token exists. The peer
alone does not establish "on the host": the proxy in front — cloudflared, in
the deployment the guide describes — runs on the same host, so everything it
forwards arrives from loopback too. A request is answered only when its peer is
loopback, the host it names is `localhost`, `127.0.0.1` or `::1`, and it
carries none of the headers a proxy adds (`Forwarded`, `X-Forwarded-For`,
`X-Real-IP`, `CF-Connecting-IP`, or the one `VIGIL_TRUSTED_PROXY_HEADER`
names). Every other request gets a 404, as if the route were not there. The
host check also refuses a page that rebinds its own name onto 127.0.0.1. The
error text of the last push and of `stale` is left out of `/healthz` — git's
words can name the remote — and shown by `status`, behind a token.

**A failed push is also a telemetry event**, `[:vigil, :push, :failed]`,
emitted by `Vigil.Commit.push/4` — the one place every push, a note's and a
skill's, goes through — with the vault path, remote, branch and git's reason.
It is what leaves the vault and its remote apart, and watching for it should
not mean reading logs.

---

## Reads see what another clone pushed

With the vault brought up to date only before a write, at boot and on
`reload`, a human who pushed from Obsidian and wrote nothing through vigil
afterwards saw `search` and `read` answer from the old state until somebody
remembered `reload`.

**Before a read, the vault is brought up to date — at most once per
interval.** The read tools — every operation the index answers: `search`,
`list`, `read`, `links`, `lint`, `current`, and any read added to that set — go
through `bring_up_to_date/1` first, the function a write goes through, when
the vault last asked the remote at least `VIGIL_READ_FETCH_INTERVAL` seconds
ago (60 by default). Any update counts, a write's and `reload`'s and the
load's at boot as well as a read's, so a read right after a write does not
fetch again. The index is rebuilt only when the update moved the branch; a
remote that holds nothing new costs a fetch and nothing else. `0` turns the
behaviour off: reads then answer exactly as they did before, and a human's
commits arrive with the next write, `reload` or restart. The interval is one
entry in `Vigil.Settings.Check` and has to be a non-negative integer.
`status`, `reload`, `skill_list` and `skill_read` are not reads of the index
and do not fetch.

**Inside the single writer, with a timeout of its own.** Reads already wait
behind the writer (see "Known trade-offs"), and the fetch is made there too, so
it cannot race a write. That is why it is bounded more tightly than a write's:
five seconds, after which the writer stops waiting and answers. The fetch runs
in a process of its own that is killed when the time is up; a `git fetch` it
started goes on within `Vigil.Git`'s own network bounds, and what it brings is
adopted by the next update. A slow remote delays one read by at most the
timeout, once per interval.

**A failed fetch never fails the read.** A fetch that fails or does not
answer in time, and a rebase that conflicts, leave the index as it stands; the
read is answered from it, and the response carries `"stale": true` beside
`result` (or `error`) — one field, the same on every read tool whatever the
result's own shape, and absent when the vault is in step. `status` carries
the detail as `stale: {at, error}`, and `/healthz` the same without the error
text. The flag stays until an update succeeds, whichever call makes it. With
the interval at `0` reads are not flagged; `status` still reports a failed
update.

It keeps the non-goals "No file watcher" and "No scheduler": nothing runs
unless a tool is called.

---

## OAuth persistence is reached through a value

The same shape, for what the authorization server remembers. Six modules —
`Vigil.OAuth.Client`, `Code`, `Token`, `Cimd`, `Flow` and `Janitor` — used to
reach storage by naming one globally registered module with hard-coded table
atoms. Nothing varied across it, so there was nowhere to substitute, and the
244 lines that own expiry, revocation, spent-token marking and the consent
lockout had no test of their own: they were exercised incidentally, through
endpoint tests.

**The value is the whole of what those six ask.** Nineteen questions,
declared in `Vigil.OAuth.Persistence`: a client written, read, counted, listed
and deleted, a code written and taken, a token written, read, listed, deleted
and revoked by family or all at once, the consent attempts counted, given
back and forgotten, the CIMD cache read and written — and the sweep. The four that list
and delete are the operator's (`Vigil.OAuth.Grants`), asked only from the
host. The sweep is part of this surface rather than a concern beside it:
every expiry it drops belongs to one of the tables above, and the janitor asks
for it through the value it was handed like any other caller.

**It is a struct of functions with no defaults**, built by `struct!/2`, the
same rule as `Vigil.Git` and `Vigil.Vault.Facts`. Here the rule earns its keep
twice over: every one of these questions guards something, and every plausible
answer to a question nobody wired sits on the permissive side of the gate it
feeds. A `get_token` answering `:error` makes every token unknown; a
`take_attempt` answering `1` turns the consent lockout off.

The production adapter is `Vigil.OAuth.Store.over_tables/0`, a function beside
the `:dets`/`:ets` implementation it wires. That module keeps the files'
lifecycle — opened under the state dir, `chmod 0600`, closed on terminate —
and stops being something the other five name.

**What it stores is digests, not credentials.** A code and a token are asked
about by their value and kept under `Vigil.OAuth.Token.digest/1` of it —
`{:sha256, <<32 bytes>>}` — so a row is `{{:sha256, digest}, attrs}`, and the
attrs are the record its owner writes (`Vigil.OAuth.Code`, `Vigil.OAuth.Token`)
with no value in them. A client is kept under its `client_id`, which is
public. Hashing is each adapter's, before every write, lookup and delete; no
caller ever holds a digest, so nothing above the seam changed. The value is
256 random bits, which is why there is no salt and no slow KDF: there is no
dictionary to precompute. The tag is what tells a digest from the raw binary
key an earlier version wrote, and what a later format would be told apart
by. The `/mcp` limiter counts a token under the same digest, so its table
holds none either.

**State from before that is migrated, not invalidated.** `Vigil.OAuth.Store`
rekeys every binary key to its digest when it opens the tables and rewrites
the file from its live rows, since `:dets` does not zero what it deletes; the
journal gets a count, never a key. Invalidating would have cost every connected
client a consent round for a fold of a few lines, and the frozen pre-seam
fixture already recorded exactly the state to migrate —
`test/vigil/oauth/store_compatibility_test.exs` holds the migration to it.

**A write answers whether it persisted.** `put_client`, `put_code` and
`put_token` answer `:ok` or the `{:error, reason}` `:dets` gives on a full
disk or at the size limit, and `Vigil.OAuth.Persistence.stored!/1` turns an error into
`Vigil.OAuth.Persistence.Unavailable` at every place a value is about to leave
the server. The flow renders it as `temporarily_unavailable` — 503 at the
token endpoint and at registration, a redirect at consent — and never hands
out a value nobody can look up again. Rotation stores the new pair before it
marks the old refresh token spent, so a failure part-way leaves the client a
retry rather than a replay that revokes its grant.

**The client table is bounded in size, count and lifetime.** Registration is
free to anyone the per-address limit lets through, and a budget bounds only
how fast rows arrive. So the body is read up to 16 KB, `client_name` and
`redirect_uris` are capped — by `Vigil.OAuth.Client.check_metadata/2`, which a
CIMD document passes through as well, since its name and URIs are cached and
shown the same way — at most 1000 clients are stored — past that,
registration answers 503 `temporarily_unavailable` and warns in the journal —
and the janitor drops a client that received no code within 24 hours of
registering. The caps are constants, not settings: nothing real comes near
them. Which clients are unused is `Vigil.OAuth.Client`'s, read off one field
of its record: `first_code_at`, `nil` until consent first hands the client a
code, which is written before the code leaves. A record from before the field
is kept rather than guessed at. Counting is a question of its own on the
contract, `count_clients`, so the cap is checked above the seam and both
adapters are held to the count. Check and write are not one step, so
concurrent registrations can overshoot the cap by as many as are in flight at
once, which the per-address budget keeps small.

**The routers resolve it once.** `Vigil.OAuth.Endpoint.init/1` builds the
production adapter when it is not handed one, exactly as it resolves its proxy
configuration and its budgets, and `Vigil.MCP.Server.init/1` passes its own
down to that router — so the token `/mcp` verifies and the token the
authorization server minted are kept in the same place by construction.
Nothing per request, and nothing reaching for application config on the hot
path.

**The second adapter is five maps behind an `Agent`.**
`Vigil.OAuth.Persistence.Memory` touches no filesystem, needs no state dir and
registers no name, so a test builds one per test and is isolated by
construction. It is not a reimplementation with different storage: what a
record *is* it asks the same owners the `:dets` adapter asks —
`Vigil.OAuth.Code` for a code's expiry, `Vigil.OAuth.Token` for a token's
expiry and its grant.

**The cache's hour belongs to the contract**, not to either adapter. It was
`Vigil.OAuth.Store`'s private constant, which was fine while there was one
adapter and wrong the moment there were two: "the cache honours its hour" is a
claim the suite runs against both, and an hour each adapter picked for itself
would make that claim mean two different things. `Vigil.OAuth.Persistence`
states it once and both read it. The consent lockout's numbers were there too,
until there were two budgets with two windows (see "Consent guesses are
bounded per address and in total"): now the caller hands each attempt the
window it is counted in, and the numbers are `Vigil.OAuth.Flow`'s, the one
module that decides on them.

The *rules* applied under those numbers stay unshared, and that is the line:
values both adapters must agree on move to the contract, logic both adapters
implement stays in each. Sharing the counting too would make the two identical
by construction, and a contract suite over two identical implementations
proves nothing.

**One suite runs against both adapters, and it is the only one that opens a
`:dets` file to ask what persistence answers.** The two others that open one
are about the files themselves: the schema version the state dir carries, and
the migration of what an earlier release wrote
(`test/vigil/oauth/store_schema_version_test.exs`,
`test/vigil/oauth/store_compatibility_test.exs`). Everything persistence actually owns is asserted there, at the
seam rather than through an endpoint: that an authorization code is
single-use, that rotation marks a refresh token spent rather than deleting it
— the distinction the RFC 9700 §4.14.2 replay defence rests on — that revoking
a grant takes down the family minted from it and nothing else, that the
consent attempts are counted per key, atomically, and expire with their window, that the CIMD
cache honours its hour, and that a sweep drops exactly what has expired. What
only the production adapter can be asked is asked there too: that a token
outlives the process that stored it, and that the files it opens are readable
by their owner alone.

Eight test files used to `mkdir` a temp directory and open three `:dets` files
apiece to ask a question about a token, and every one of them was serial for
it. All eight run in parallel now. The last two stopped being serial for
reasons that had nothing to do with persistence either:
`Vigil.OAuth.EndpointTest` wrote the rate-limit budgets and the trusted-proxy
configuration into global application env and now states both as router
options, and `Vigil.OAuth.JanitorTest` drove the janitor registered under its
module name and now starts unregistered ones it reaches by pid.

**`Vigil.MCP.ServerTest` supplies its own writer now**, the way
`Vigil.StoreTest` does: the router takes one at `init/1` and threads it to
both halves of a response, so the file starts no `Vigil.Store` under the
production registration. The session table is its own too, under a name it
supplies, and so is the limiter — counting in a process rather than in the
node's one table. Nothing it drives is found by a default any more.

**One file starts `Vigil.RateLimit`**: `Vigil.RateLimitTest`, where the
production adapter's table is the thing under test. It is async *because* it
is the only one — the table is the node's, so a second file starting it would
clash over the registered name and over what is in the table, and the two
tests that need the table gone could not say so. That stays true by force
rather than by convention: `start_supervised!` raises on
`{:error, {:already_started, _}}`, so a second file starting it breaks loudly
and immediately.

The speed is a consequence and not the argument, and here it is a small one.
The argument is that 244 lines owning expiry, revocation, spent-token marking
and the consent lockout had no test of their own — they were exercised
incidentally, through endpoint tests, which is why "a sweep removes exactly
what has expired and nothing else" was nobody's claim until it was the seam's.

---

## The rate limiter is reached through a value

The same shape a third time, for the fixed window three surfaces count in.
`Vigil.RateLimit` was a module with one named ETS table, named by
`Vigil.MCP.Server`, `Vigil.OAuth.Endpoint` and `Vigil.OAuth.Janitor` alike —
so there was nowhere to substitute, and every test that wanted to observe a
limit started the node's one limiter under its own registration and counted in
the table everything else counts in.

**The value is both questions, not the limit check alone.** `limited?` counts
one request against a budget; `sweep_expired` reclaims the windows that have
elapsed. The sweep is part of this surface rather than a concern beside it:
what counts as an elapsed window is the same fact `limited?` decides on, and a
sweep that decided it separately could hand a caller a budget it has not
waited out. It is a struct of two functions with no defaults, built by
`struct!/2`, the same rule as `Vigil.Git` and `Vigil.OAuth.Persistence` — and
here it earns its keep on one answer in particular: a `limited?` nobody wired
answers `false`, which is not a limiter with a missing part but every caller
served unlimited.

**The production adapter is `Vigil.RateLimit.over_table/0`**, a function beside
the ETS implementation it wires, over the one named table the process owns.
Everything below it is private, both answers included, so the value is the
only way to reach them. **The second adapter is `Vigil.RateLimit.Counter`**:
one map behind an `Agent`, no registered name and no table anything else can
reach, so a test builds one per test and is isolated by construction.

**The window's length belongs to the contract**, for the same reason the
CIMD cache's hour does: "the window is fixed rather than sliding" is a claim
the suite runs against both adapters, and a minute each adapter picked for
itself would make that claim mean two different things. How a window is
counted and how one is reclaimed stays each adapter's own — a match-spec
delete against ETS, a map split against the agent — which is what leaves the
contract suite something to catch. `configured_budget/2` belongs to neither
adapter: it reads what the deployment configured, once, where a router is
initialized, and is handed to `limited?` as an argument from there on. What was
read is judged by `budget/3`, which takes it as an argument — so what counts as
a budget can be stated against a budget rather than against global application
state, and the limiter's own suite states the budgets it is about instead of
writing them into an application env every other async file shares.

**The read and the judgement have names of their own.** They are two
responsibilities, and one name over both left a call site unable to tell which
of them it was looking at without counting arguments. `budget/3` takes the
setting's name as well, because the warning is the judgement's own: the
function that decides to ignore what a deployment configured is the one that
has to say which of the four it ignored.

**The missing-table guard is the production adapter's alone.** That table is
owned by the limiter's process and is gone while that process restarts, so a
sweep can arrive to no table and must answer "nothing reclaimed" rather than
take the janitor down with it. An adapter with no table to lose has nothing to
say about that, so it is not a claim the contract makes. `limited?` gets no
such guard in either adapter: on the request path a missing table means the
limiter is not running, and crashing the request is the honest answer where
answering "not limited" would quietly serve every caller unlimited.

**The routers take it at `init/1`**, beside the persistence they already take,
defaulting to the production adapter so a deployment hands in nothing — and
`Vigil.MCP.Server` passes its own down to `Vigil.OAuth.Endpoint` exactly as it
passes persistence. `Vigil.OAuth.Janitor` keeps its own list of what to sweep,
which is the point of that list belonging to the janitor; what changed is that
the limiter stopped being the one entry on it that was a hard-coded module
reference. Nothing per request, and nothing reaching for a registered name on
the hot path.

---

## The deployment is resolved once

`Vigil.Settings` is what the deployment says about itself: the vault's
timezone, the authorization server's identity — issuer, resource, consent
password, how many wrong guesses at it every address together may spend in an
hour, and the secret and window an AP-4 SkillKey is derived from — and the two
strings that shape the writing instructions handed to the MCP client.
`Vigil.Application` builds it once, where the supervision tree is built, with
`Vigil.Settings.from_checked/1` out of what the settings check returned (see
below), and everything below takes the result as an option.
`Vigil.Settings.from_env/0` reads the same nine keys from the application
environment for a caller outside the tree that hands in none.

**The shape is `Vigil.SkillKey`'s**, which bundled the HMAC secret and the
rotation window into one value because neither derives a token alone, and made
every function there take the bundle. What is new is the reason: these nine
do not derive anything together. They are one value because of *where they are
read*. An environment read belongs in the composition root, and eight modules
that each asked for one key with a default of its own had no way to be handed
another deployment.

**Every default is `config/runtime.exs`'s**, stated once as the fallback of
the environment variable it comes from. The settings check refuses a key that
is somehow unset, and `from_env/0` fetches rather than defaults, so it fails at
boot where an operator can see it, and not at the first write. The module-side copies — `Vigil.Clock`'s
`"Europe/Berlin"`, `Vigil.MCP.Server`'s `"the vault owner"` and `"English"` —
are gone with the reads that used them.

**Where each one lands.** `Vigil.Store` publishes the timezone in its table
beside the vault path, so a caller resolving its own instant reads the
deployment the writer was built with — and reads it back out of that table
itself, for a write that arrived without an instant of its own. It is not in
the state as well: one copy of the fact, and nothing that could hold a second
one that has drifted. `Vigil.MCP.Envelope.for_tool/5` takes it as its fifth
argument, for the same reason the four before it are arguments.
`Vigil.MCP.Server` resolves the value at `init/1` and hands it down to
`Vigil.OAuth.Endpoint` exactly as it hands down persistence and the limiter —
and reads it back out of those options, so both halves agree on what this
server is called and what it protects by construction rather than by two
resolutions happening to match. `Vigil.OAuth.Flow` takes it on the two
decisions that need it: the audience an `/authorize` request may ask for, and
the password a consent is checked against — as one value with the persistence
those two decisions are made against, which is the section below.

**The audience a code is minted for travels in `ctx`.** `authorize_request`
already checks the request's target against the deployment's resource, so it
puts that resource in the context it returns and `Vigil.OAuth.Code` mints
against it. A code cannot be minted for a resource its request was never
checked against, and `Code` has no second opinion to hold.

**What the composition root reads is out of scope and stays there.** The vault
path, the exclusions, the git remote and branch, the state dir, the listen
address and port, the rate-limit budgets and the trusted proxies are handed by
`Vigil.Application` to the children that need them, every one as
`Vigil.Settings.Check` returned it — the branch is only known once the clone
has been read, and the proxies arrive parsed. Nothing in the tree is read from
the application environment a second time, so what was checked is what runs.

**The SkillKey is derived from what was resolved, not read again.** The AP-4
HMAC secret (`VIGIL_SKILLKEY_SECRET`) and the rotation window are settings like
the rest, so `Vigil.SkillKey` takes both from the settings rather than from the
environment — one resolution, and `VIGIL_SKILLKEY_TTL`'s default stated once
in `config/runtime.exs` like every other. `Vigil.SkillKey.key/1`
is where the deployment's settings become the bundle that module's functions
take, and `Vigil.MCP.Server` hands that bundle to `Vigil.MCP.Tools.dispatch/5`
the way it hands the timezone to the envelope. The gate and the `skill_read`
that hands a key out are then two callers of one value, and neither can be
pointed at a deployment the other is not.

**Two more test files run in parallel.** `Vigil.ClockTest` set `:tz` in global
application env and put it back afterwards; it passes a timezone now.
`Vigil.ContractsTest` said so in its own comment — "the OAuth metadata reads
issuer/resource from application env" — and now hands both metadata functions
the settings value the fixture already had.

### Every setting is checked in the same place, once

Resolving once is half of it; the other half is judging what was resolved
before anything uses it. `Vigil.Settings.Check` holds one table with one entry
per setting — the application key, the variable an operator set, and the
check — and `Vigil.Application` runs `check!/0` before any child starts. Every
entry is checked and every failure is reported in one message, each naming its
variable and saying what it expected, so an operator fixing `/etc/vigil/env`
does not restart once per typo. A new setting is one more entry.

**`config/runtime.exs` parses nothing it could fail on.** A variable that reads
as an integer is handed on as one, anything else as written. A
`String.to_integer/1` there stopped boot with a bare `ArgumentError` that named
no variable, and a raise in that file cannot be tested apart from the process
environment; the check takes the configuration as an argument and can.

**A positive integer is positive.** The port, the four rate-limit budgets and
the SkillKey TTL refuse boot when they are not positive integers. A TTL of `0`
used to boot and then fail every `skill_read` and every write, and a budget
that fell back to its default with a warning was a limit quietly not the one
configured. `Vigil.RateLimit.budget/3` keeps its fallback for a router built
outside the supervision tree, but a deployment never reaches it. The one
integer where `0` is a setting rather than a typo is
`VIGIL_READ_FETCH_INTERVAL`: it turns fetching before reads off, so it must be
a non-negative integer.

**An unknown `VIGIL_TZ` refuses boot; it does not fall back.** Of refusing
and falling back to UTC with a logged warning, refusing is the simpler and the
safer: every response and every write is stamped in this zone, and a stamp
silently in UTC is wrong in a way no operator reads a warning for.
`Vigil.Clock.now/1` keeps its own fallback to UTC, because the write path must
stay crash-safe by construction, but the deployment's zone can no longer reach
it invalid.

**An unset `VIGIL_TZ` is UTC.** Of defaulting to UTC and requiring the
setting, the default is the simpler: `init.sh` asks for the zone and writes
it, so every scripted host names one, and a local run needs no line for it.
The default used to be `Europe/Berlin`, the zone of the one deployment that
existed — a place nobody else chose. UTC is the zone that is wrong for
everyone equally and says so in every offset.

**In prod the authorization server's identity is https, on one origin.**
`VIGIL_ISSUER` and `VIGIL_RESOURCE` must be `https` URLs, and the resource must
sit on the issuer's origin — same scheme, host and port — because a client
finds the one through the other's metadata. Which environment is "prod" is
`config/runtime.exs`'s to say (`https_required`), as it already says which
settings have no fallback there; dev keeps its `http://localhost` defaults.

**The vault's remote and branch are checked against the clone.**
`VIGIL_GIT_REMOTE` and `VIGIL_GIT_BRANCH` are what every pull and every push
names; the branch used to be `main` in both calls, so a vault on `master`
failed every write with a git error. The check asks the clone once, through
the git value's `tracking` question, so it stays off the repository in the
suite like everything else: the remote must be one of the clone's, and the
branch one of its branches, tracking the branch of the same name on that
remote — an upstream anywhere else would be a branch pulled from one place and
pushed to another — and the one checked out. Every commit, fast-forward and
rebase acts on `HEAD` while every push names the branch, so a clone with
another branch checked out, or a detached `HEAD`, would take every write and
push none of them while answering `pushed: true`; the message names the
branch that is checked out and the `git switch` that fixes it. A rebase in
progress counts as the branch it is rebasing, because the writer aborts it
before it loads (see "The server stays in step with the remote"). A vault
path that is no git clone is refused on its own entry, and the two say
nothing more.

**The remote defaults to `github`; the branch to the clone's.** The remote's
default was `origin` in `config/runtime.exs` while `scripts/init.sh`, the push
safety net, `verify()` and the troubleshooting guide all said `github`; the
layout init.sh creates won, so the default and the docs agree. The branch has
no fixed default: unset, it is the clone's checked-out branch when that tracks
a branch on the remote, and `main` otherwise — what a clone of a `master`
vault already says about itself. The scripts read both from `/etc/vigil/env`
(`vault_git_remote` and `vault_git_branch` in `scripts/lib.sh`, which apply
the same rule and name the two defaults once), init.sh writes both there, and
the push safety net's `scripts/push_pending.sh` gets them from systemd, which
reads the file for its unit (see "The push safety net runs in the service's
sandbox").

**The trusted proxies are a list of blocks, or nothing.** Every entry in
`VIGIL_TRUSTED_PROXIES` must parse as an address or a CIDR block, and the
header and the list are set together or not at all. A malformed entry used to
be dropped with a warning when the router was built, and a list that lost its
only entry keyed every request on the tunnel's loopback address — one consent
lockout for everyone, which the first wrong password from anywhere spent for
the owner too. The check hands the blocks on parsed, through `Vigil.Cidr`, the
one reader of addresses and blocks `Vigil.OAuth.ClientAddr` and
`Vigil.OAuth.Cimd` share.

**An excluded name is a name.** `VIGIL_EXCLUDE` is matched against every
segment of a path, so an entry holding a `/`, or `.` or `..`, matches no
segment and hides nothing while reading as if it did; it is refused, naming
the entry.

**The secret is named, never echoed.** A check that wants the offending value
in its message puts it there itself, so `VIGIL_AUTH_PASSWORD`'s says what it
expected and nothing about what it got — and so does `VIGIL_SKILLKEY_SECRET`'s.

**The SkillKey secret is random bytes, not a long string.** It must decode, as
hex or as base64, to at least 32 bytes, and must not equal the consent
password. Length alone would let a chosen phrase through, and a chosen secret
is exactly what an exposed HMAC output lets someone guess at offline. What is
measured is what the value decodes to, not its randomness, so it is a filter
for mistakes rather than a proof: a phrase with a space or a comma in it
decodes to nothing, and one of letters alone — valid base64, and 43 letters
decode to 32 bytes — is refused as well, since `openssl rand` prints a value
without a digit or a sign in it fewer than once in half a million tries. A
chosen value that mixes in digits still passes. Hex is tried first, because
every hex string is also valid base64 and would count half again the
randomness it holds. The message for an unset one says how to generate one
(`openssl rand -base64 48`, what `init.sh` runs), because the operator most
likely to meet it is one whose host predates the setting.

---

## The flow decides for one authorization server

`Vigil.OAuth.Server` is the pair every `/authorize` and every consent is
decided with: the `Vigil.OAuth.Persistence` its records live in, and the
`Vigil.Settings` that says what this server is called and what it protects.

**The pair is the type the two arguments already were.** `authorize_request`
took a persistence and a settings; `consent` took the same two again;
`Vigil.OAuth.Endpoint` resolved both and passed both to each. A pair the
flow's callers never resolve apart, never pass apart and never substitute
apart is one value, and stating it as one takes the question of whether the
two agree off the table: there is no decision that can be made with this
deployment's records and another deployment's identity.

**It appeared when the settings did.** Before the deployment was resolved once,
the flow reached the environment itself for the audience and the password, so
there was one argument and no clump. The pair is worth naming now rather than
then because the shape has settled — and if it stops travelling together it
should be taken apart again rather than kept for its own sake.

**The router builds it, at `init/1`, out of what it has just resolved.** Not a
sixth option a caller could hand in: `Vigil.MCP.Server` passes persistence,
the limiter and the settings down to that router and reads all three back out
of its options, so a separately supplied pair could disagree with the halves
both routers agree on. It is derived from them instead, and the two accessors
on the router that still need one half alone — registration and the token
endpoint ask the settings nothing, the discovery documents ask persistence
nothing — read it off the pair rather than hold a second copy.

**`register` and `grant` keep taking the persistence alone.** Neither asks the
settings anything: a registration is checked against the redirect URIs it
offers, and a grant against the audience its own record carries. Giving them
the pair for uniformity would hand both a value they must not read.

**What `/mcp` verifies a token with is not this pair, and that is not an
oversight.** `Vigil.MCP.Server` holds the persistence and the settings as two
options and asks `Vigil.OAuth.Token.validate_access/3` with the first and one
string off the second. It holds them apart because it needs them apart: the
timezone stamps an envelope and the owner and the language shape the writing
instructions, and neither is an OAuth decision at all. The pair is what the
*flow* decides with, which is the only place both halves are asked the same
question.

---

## How a file is written

Vigil is the only writer (principle 2), so the shape of a file on disk is
vigil's to define. Four rules, and they hold on every write path.

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

**A note is written back in the style it was read in.** A note saved on
Windows ends its lines with CRLF, and some editors put a UTF-8 byte order mark
in front of it. Neither is part of what the note says, and both used to hide
its frontmatter: the first line was `---\r` or `\uFEFF---`, not `---`, so the
note was read as having no block and `update_frontmatter` put a second one in
front of the first. `Vigil.Markdown.decode/1` is the one reading of those
bytes: every reader — the parser, `Vigil.Vault.Plan`, the doctor — works on
text with `\n` endings and no mark, so chunk bodies, hashes and responses
never carry a `\r`. What `decode/1` also returns is the note's style, and
`Vigil.Vault.Plan` writes every edit of an existing note back in it through
`Vigil.Markdown.encode/2`: a CRLF note stays CRLF, a note with a mark keeps it,
and a `move_note` that rewrites links does the same for each note it touches.
Normalising to LF on the first edit was the alternative, and was rejected: it
turns a one-line edit into a whole-file diff in the author's history, on a
file they chose to write that way. A note is CRLF when its first line break is; a file that
mixes the two is written back in that one. A note vigil creates is LF with no
mark, because there is no author's style to keep.

These rules say nothing about repairing notes written before them. Files that
already lost a separator stay as they are; principle 5 says the server reports
and does not fix on its own initiative.

---

## A note that is not UTF-8 is skipped

A note saved as Windows-1252 or Latin-1 is not UTF-8, and nothing in it can be
read honestly: a heading or a link with such a byte in it has no slug, so the
load raised — at boot a restart loop, and the server stayed down for one file
— and a chunk holding one could not be encoded into a JSON response.
Guessing the encoding was the alternative, and was rejected: a guess is right
often enough to be trusted and wrong often enough to mangle a note, silently.

So `Vigil.Parser.parse/3` answers `{:error, :invalid_utf8}` for such content,
and the load skips the file with a warning that names it. The vault loads
without it; one note costs one note (principle 5: report, do not fix). The
skipped paths stay in the index as paths only, and `lint` lists them under
`invalid_utf8`; `mix vigil.vault_check` reports them under `b0_encoding` and
checks them for nothing else, because every other finding is about a note the
server reads. The fix is the author's: re-save the file as UTF-8, then
`reload`.

Until then vigil does not write to it. An edit of the note is refused in
`Vigil.Vault.Plan` and a move in `Vigil.Vault.Policy`, both naming the file,
because either would hand the index a note it cannot parse. Deleting it is
allowed — that is one way of fixing it — and takes it out of `lint`.

**A file name that is not UTF-8 costs the same one note.** Linux keeps a file
name as the bytes it was given, so a note saved as `bike/caf\xE9.md` is on disk
with a name that can be neither a chunk id, nor a slug, nor a JSON string;
building the index raised on it exactly as on a heading. `Vigil.Vault.Layout`
leaves such a file out of `note_paths/1` — the one walk the load, `mix
vigil.vault_check`, `mix vigil.slug_diff` and the release's chunk-id listing
share — and hands it out separately (`non_utf8_paths/1`). The load skips it
with the same kind of warning, and `lint` (`invalid_utf8`) and `vault_check`
(`b0_encoding`) name it with every stray byte spelled out as `\xHH`
(`bike/caf\xE9.md`), so the report is valid JSON and still says which file to
rename. APFS refuses such a name outright, so on macOS the case cannot arise;
the tests that need one on disk run where the filesystem holds it.

---

## A Markdown file that is not a note is reported

Obsidian creates a note wherever its user happens to be: at the vault root,
one level too deep, or in a directory that is not a domain. `Vigil.Vault.Layout`
does not call such a file a note, so the load skips it without a word and its
content never reaches search.

`mix vigil.vault_check` names every one under `b7_ignored_files`, with the
reason (`root`, `wrong_depth`, `unknown_directory`) and a severity. The reason
is the layout's own answer (`Layout.ignored_reason/2`), not a second statement
of the rules. Files in `_`- and dot-prefixed directories at any depth are not
listed, because those lie deliberately outside the vault model (`_templates/`,
`.obsidian/`, `.trash/`); neither are skills or anything behind
`VIGIL_EXCLUDE`, which is the boundary rather than an oversight.

A file at the root is `info`: a Dataview dashboard there is often deliberate,
and a legitimate root page must not make `init.sh --check-only` fail forever.
`init.sh` prints it under "Information" and does not count it. Every other
ignored file is a `warning`, counted as a finding like the rest. Nothing moves
the file for the author (principle 5: report, do not fix).

---

## Vault hygiene has one set of rules

`lint` (through `Vigil.Index`) and `mix vigil.vault_check` (through
`Vigil.VaultCheck`) both report on the shape of the vault, and they report to
different readers: `lint` answers an assistant over MCP and is token-frugal,
the doctor writes a JSON report for `jq`. The output shapes stay separate. The
facts underneath do not — they were restated in both and drifted, and they live
in `Vigil.Vault.Rules` now.

**A duplicate heading is a duplicate *slug*.** Two headings collide when the
slug of their heading text collides *within one note*, because that is where
`Vigil.Parser` starts a heading's chunk id: `## A / ### B` and `## C / ### B`
really do produce `b` and `b-2`. Grouping by the heading chain instead
under-reports exactly the notes whose chunk ids are unstable, which is the
breaking change this project fears most (see "Known trade-offs"). A heading
whose own slug collides with nothing can still be pushed onto a suffix —
`## Setup 2` below two `## Setup`s — and its note is reported for the pair
that pushed it. Both readers see that pair because a chunk id is unique within
its note (see "Chunking"): every heading a parse finds is a chunk the index
holds.

**An overlong note is 30 headings or 2000 words.** Two axes rather than a chunk
count, because the pair says *why* the note is too long — many sections, or
much prose — which is what the reader acts on. The `lint` finding carries both
counts and which threshold was crossed.

**A sentence-shaped heading** is longer than 60 characters or ends in `.`, `!`
or `?`. A signal, not proof.

**The doctor reads `_domains.yml` through `Vigil.Vault.Domains`**, the same
parser the server loads its naming rules with, and renders the typed warnings
it gets back in its own wording — the drift messages `scripts/init.sh` matches
on. A file it could not read or parse produces one finding saying so and no
drift at all: drift measured against keys nobody read is one false "unknown to
the runtime" per domain, which is a report on a file the doctor could not
read, in the voice of one it had. A file that is merely *absent* is not that
case — it costs the descriptions and nothing else, and every domain directory
is reported as having no entry yet, which is what vault adoption appends from.

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

**The router names the writer, and the envelope with it.** Both halves of a
response — the tool call and the envelope that wraps it — are decided against
one vault, and `Vigil.MCP.Server` is the only thing that knows they are the
same one. So it resolves both at `init/1` — the writer, defaulting to
`Vigil.Store.default_name/0`, and the session table, defaulting to
`Vigil.MCP.Envelope.default_name/0` — and hands the writer to
`Vigil.MCP.Tools.dispatch` and to `Vigil.MCP.Envelope.for_tool` alike.
Defaulting inside each half instead is how one of them came to be handed a
writer and the other left to find one by name, so neither takes a default of
its own: `for_tool/5` is asked which session table and which writer, every
time — and, since the deployment is resolved once too, which timezone to stamp
the response with. Session state is per router rather than one table for the
node.

**A session is issued, bound, expires and can be ended.** `initialize` issues
the one `Mcp-Session-Id` a session has and binds it to the token that sent it,
kept as the token's digest (`Vigil.OAuth.Token.digest/1`), never as the token.
Every other message is sent in a session: no id is a 400, and an id that is not
a live session of the token presenting it — never issued, another token's,
expired, ended, or issued before a restart — is a 404, which the transport
tells a client to answer by initializing again. **A session lives one hour
without a request**, and every request in it starts that hour over. One hour
because that is how long an access token lives: a session bound to its token
cannot be used past it anyway, and a client that refreshes initializes a new
one. `DELETE /mcp` with the id ends it, 204, and the id is a 404 from then on.
`Vigil.MCP.Session` decides all of this over rows of the session table
`Vigil.MCP.Envelope` owns, and the envelope's state is one field of a session.

Only `initialize` adds a row. Before this, any non-empty id was accepted and
each distinct one was a row never removed; now an id nobody issued is refused
without writing anything, so the table holds only sessions a valid token asked
for, at the rate its budget allows. `Vigil.OAuth.Janitor` drops the ones whose
hour has run out, and a request that finds its session expired before the
sweep does is refused the same way and drops it on the spot.

This is the reason the assistant never has to guess what time it is.

The envelope's state is which events were active, and nothing about when.
It used to carry the last response's instant too, so that a session silent
for more than 24 hours would get the long first line again; a session now
lives at most as long as the access token it is bound to, one hour, so that
rule could no longer fire and is gone.

---

## Protocol versions

vigil speaks three MCP protocol versions: **2025-11-25, 2025-06-18 and
2025-03-26**. `initialize` answers with the version the client asked for when
it is one of these, and with 2025-11-25 otherwise — the client then accepts it
or disconnects, as the lifecycle says. The negotiated version belongs to the
session (`Vigil.MCP.Session`): every later request in it that carries
`MCP-Protocol-Version` must name that version, and anything else — another
supported version, one vigil does not speak, the header twice — is a 400.
That includes the `DELETE` that ends the session, which ends nothing then. A
request with no header at all is accepted as the session's version: 2025-03-26
defined no such header, so its clients send none, and the transport's fallback
for a missing header only applies to a server with no other way to know.

For a server that offers tools and nothing else the three are the same on the
wire. What the later two added to that surface is either a field an older
client ignores — a tool's and the server's `title`, `websiteUrl`, tool
annotations are 2025-03-26's own — or one vigil does not send: no
`outputSchema`, no `structuredContent`, no icons. Nothing in a response depends
on the version, so none is shaped by it.

**One gap is deliberate.** 2025-03-26 says an implementation MUST support
receiving JSON-RPC batches; 2025-06-18 removed batching. vigil answers a batch
with `-32600` under every version. No client this server is written for sends
one, and supporting it for one version would mean a second response path —
several envelopes decided in one request — for a feature the protocol has
since dropped.

The rest of the transport's small print, as `/mcp` answers it:

- A message with `result` or `error` and no `method` is a response the client
  sent back; it is accepted with 202, since vigil sends no requests to match it
  to. An object with neither a `method` nor a result is `-32600`, as is one
  whose `method` is not a string.
- A `tools/call` naming no declared tool, or with a `name` that is not a
  string, is `-32602` — a protocol error, not a tool result, so it carries no
  envelope and does not advance the session's state. A tool's own refusal —
  bad arguments, a missing SkillKey, a read-only token — stays a tool result
  with `isError`, which is what lets the model correct itself.
- GET, and any method other than POST and DELETE, is a 405 with
  `Allow: POST, DELETE`: vigil opens no server-sent stream.
- A 429 carries `Retry-After`, the rate limit's window, as the authorization
  server's 429s do.

---

## Security model

Five layers, each doing one job:

1. **Cloudflare Access** — network layer, before Elixir. `init.sh` aborts
   unless the public endpoint answers 403.
2. **OAuth 2.1 + PKCE** — vigil is its own authorization server. See
   [oauth.md](oauth.md).
3. **Scope** — `vault` (full) or `vault:read` (read-only tools). The check is
   an allow-list: a write needs exactly `vault`, and any other scope — the
   empty string, one this server never issued — is refused as `vault:read`
   is, rather than only `vault:read` being refused and everything else let
   through. `tools/list` shows such a token only the tools it may call. An
   empty `scope` at the authorization endpoint means "no scope asked for",
   and the token endpoint issues `vault` for it, never `""`; it decides this
   for a refresh token too, so a family redeemed before the rule carries
   `vault` from its next rotation on. A `vault:read` token cannot change what
   a note says. It can make the server catch up with the remote: `reload`
   takes no content from the caller and adopts commits already pushed there —
   fast-forwarding, or rebasing vigil's own unpushed commits on top of them,
   and aborting at a conflict — so an update can move the vault under a
   reader, whoever calls it, but it adds nothing that was not already on the
   remote or committed by vigil.
4. **SkillKey** — a rotating HMAC required by every write tool. Not access
   control (the token already did that): it is proof that the assistant has
   *read the writing conventions* in this session. It can only be obtained by
   calling `skill_read`.
5. **Rate limiting** — fixed window, in three places that are easy to
   confuse. `/mcp` is limited per access token, so it is unreachable without
   one; past the budget it answers 429 with a `Retry-After` naming the
   window. `reload` is counted a second time there, per access token under a key
   of its own and against a much smaller budget (`VIGIL_RELOAD_RATE_LIMIT_RPM`,
   default 6), because each call pulls and reparses the whole vault inside the
   single writer. Past it, `reload` answers a tool error saying so rather than
   a 429: the request was within the budget every request spends, the session
   goes on, and the caller is told which call to stop repeating. The authorization server's own endpoints — `register`, `authorize`,
   `token` — are limited per **client address**, because they are reachable
   with no token at all and each one costs something: an outbound CIMD fetch
   to an address the caller chose, a `:dets` row and an fsync, or the work of
   answering a guess. The consent form counts wrong passwords only, per
   address over a much longer window, and every address together against an
   hourly budget. One limiter, `Vigil.RateLimit`, serves
   the first two; the third is a lockout rather than a request limit and
   belongs to OAuth persistence. Every one of them is swept by
   `Vigil.OAuth.Janitor`, whose list of what to ask is its own: it asks
   persistence for the expiries persistence owns, and the limiter for the
   windows it does not — each through a value it was handed, neither by name
   — and drops expired MCP sessions from the session table it was named.
   A budget bounds how fast rows arrive and a sweep bounds how many there are,
   and neither substitutes for the other.

**Client address** is a decision, not a lookup. `conn.remote_ip` is the peer of
the TCP connection, which behind layer 1 is the proxy — so a per-address limit
keyed on it is one global bucket. A forwarded header is written by whoever sent
the request unless something overwrites it, so vigil believes one only when
told its name *and* told which peers may set it, and takes the rightmost hop it
did not add itself. Both settings are empty by default: unconfigured, the limit
stays global, which is stricter than intended rather than weaker. Getting them
wrong is the only way to make this worse than not having it. The deployment
`docs/guide.md` describes is configured, not left global: cloudflared runs on
the same host, so the peer is always loopback, and `scripts/init.sh` writes
`VIGIL_TRUSTED_PROXIES=127.0.0.1/32,::1/128` with `CF-Connecting-IP`. The
guide used to show Cloudflare's edge ranges, which never match a loopback peer.
An IPv6 address is keyed by its /64, not itself: a /64 is one line or one host,
and a key per address would hand its holder 2^64 budgets. An IPv4 address in
its IPv6-mapped form is keyed as the IPv4 address — `::ffff:0:0/96` lies inside
`::/64`, and every IPv4 client would otherwise share one key.

**Consent guesses are bounded per address and in total.** Five wrong
passwords per address in fifteen minutes stop one guesser; they do nothing
against one spread over many addresses. So every address together also has a
budget, `VIGIL_CONSENT_FAILURES_PER_HOUR` (default 50), a setting in
`Vigil.Settings` checked at boot like the other budgets. Past it the consent
form answers 429 to every address until the hour is up, and a warning is
logged once per hour it happens. The choice is deliberate: spending the
budget denies the owner consent for up to an hour, and that is the price of
guesses being bounded in total — a denial that ends, against a password that
could otherwise be guessed at any rate enough addresses allow. The Cloudflare
Access policy the guide recommends in front of `/oauth/authorize` is what keeps
a stranger from spending it. The budgets are counted against, not checked
against: an attempt is counted *before* the password is compared, every
counter changes in one atomic operation (`:ets.update_counter/4` behind a
`select_replace` that opens a fresh window, and a single `get_and_update` in
the in-memory adapter), and each attempt is answered its own count, so
requests in parallel cannot spend more than a budget between them. A right
password gives its attempt back and forgets the address's; an address already
locked out spends nothing of the shared budget. `Vigil.RateLimit` counts the
same way. The password is compared as the SHA-256 digests of guess and
password, because `Plug.Crypto.secure_compare/2` answers early on a length
mismatch and so told a guesser the password's length.

**A browser on another site is refused before anything else.** The Streamable
HTTP transport says a server MUST validate `Origin` and answer 403 when it is
present and invalid; that is the defence against DNS rebinding, and a server
bound to loopback — the local quickstart — is exactly what rebinding reaches.
`Vigil.Origin` lets three kinds of request through: one with no `Origin` (a
program, not a browser), one from the issuer's origin (the consent form posting
back), and one from an origin listed in `VIGIL_ALLOWED_ORIGINS`, empty by
default. Everything else, `null` included, is refused. Origins are compared
serialized — lowercase scheme and host, the default port dropped — and a listed
entry that is not an origin, such as a bare host or one with a path, refuses
boot rather than silently matching nobody. The check is a plug ahead of the
route in both routers, so it runs before the token is looked at, before the
body is read and before the rate limit counts the request: a refused request
costs nothing and spends no one's budget. `/mcp` is checked on every method;
the authorization server only on its POSTs, because its GETs are discovery
documents and the consent page, which a browser navigates to and which change
nothing. Two routers, one set of origins: it is built once, from the issuer
and the checked list, and `Vigil.MCP.Server` hands it to `Vigil.OAuth.Endpoint`
and reads it back the way it does persistence and the limiter. No wildcard,
and no port range: a list an operator can read is a list an operator can check.

**A grant** is one authorization, and it is the unit of revocation. A `grant_id`
is minted with the authorization code and carried onto every token redeemed or
refreshed from it, so a replayed refresh token can take down the whole family.
Not `client_id`: a client legitimately holds more than one grant over time. A
rotated refresh token is marked **spent** rather than deleted, because deleting
it makes a replay indistinguishable from a token that never existed — and the
replay is the signal that one of two holders is an attacker. See
[oauth.md](oauth.md) for the full walk.

**The operator revokes by grant too.** `scripts/grants.sh` lists the live
grants — id, client, scope, when the grant began and when it expires, never a
token value — and revokes one, all, or a client with every grant it holds,
through `bin/vigil rpc` in the running node (`docs/guide.md`, "Revoking
access"). The id the operator types reaches the node base64-encoded rather
than spliced into the Elixir it evaluates, so no id is code. Revoke-all takes
the unredeemed codes too, and a deleted client its codes, since redemption
checks the code rather than the client. When a grant was last *used* is not
recorded: it would be a disk write on the `/mcp` hot path for a column. Of an
RFC 7009 endpoint and nothing, nothing: the operator is on the host, and a
client has never needed to give a token back. Seeded tokens live 90 days,
not ten years, and `init.sh --keep-token` mints none for the owner — its
acceptance check gets two that live 15 minutes.

The SkillKey creates a bootstrap problem: `skill_write` needs a key, but a
fresh vault has no conventions skill to read one from. Resolved by having
`skill_read` return the current key in its *error* response too — the key is a
pure HMAC over secret and time and does not depend on any skill existing.
That is a bootstrap affordance, not the way back in after a rotation: the
conventions skill names itself `vigil-vault-conventions`, the name `init.sh`
installs it under, so the retry it instructs reads a skill that exists.
`init.sh` itself no longer needs the affordance — it commits that skill
directly, since `skill_write` refuses it — but in a vault without the skill,
the not-found response is still where a key comes from. Both
responses say how long the key lives from the key bundle they were handed —
the deployment's window, and that the previous window's key is still accepted
— rather than a fixed hour, which is true only of the default.

**The consent password keys nothing whose output leaves the server.** The
SkillKey is an HMAC under `VIGIL_SKILLKEY_SECRET`, a random secret of its own
that `init.sh` generates beside the password (layer 2's) and never from it.
They used to be one setting in two roles, reviewed and kept for rotation
convenience — but that review missed what a SkillKey is: an HMAC output handed
to every client, kept in chat transcripts. Keyed with a password a human may
have chosen, every one of them was a test for password guesses that needs no
server and meets no rate limit. Keyed with 32 random bytes, it is a test for
nothing. So the two rotate apart: changing the password because someone saw
the consent page leaves every outstanding SkillKey valid, and rotating the
SkillKey secret — which invalidates them, so an assistant mid-conversation
calls `skill_read` again — leaves the password and every OAuth token alone.

**A host set up before the secret existed refuses to boot.** Its env file has
no `VIGIL_SKILLKEY_SECRET`, and the settings check stops the start naming the
variable and the command that makes one. `update.sh` looks for the line in its
preflight and stops there with the same command, before anything is built or
switched: a release that never comes up fails the health wait after the
switchover, which does not roll back. Of refusing and generating a secret on
first boot (into the state dir), refusing is the simpler and the safer: a
generated secret would be a second place secrets live, outside the env file an
operator backs up and rotates, and a fallback to the password would keep
exactly the exposure this closes. The operator adds one line, once
(`docs/guide.md`, "Operations").

**Nothing the node opens listens beyond loopback.** The HTTP listener is bound
by `VIGIL_BIND`; Erlang distribution is bound by the release itself. Of
binding distribution to loopback and switching it off (stopping through
SIGTERM alone), binding is the one kept: `bin/vigil stop`, `bin/vigil rpc` and
the operator scripts that seed a token into the running node all reach it over
distribution, and without it each of them would need a second way in. So the
node is `vigil@127.0.0.1`, its listener is on 127.0.0.1 only, and it runs
without epmd — the port is fixed (4370), and the short-lived node behind `rpc`
dials it directly and listens on nothing (`rel/`). No epmd means no second
daemon to bind, and none started under a different environment by whoever
called first. The cookie is distribution's only credential, so the release
writes it `0400`. A full name rather than a short one because a short name
goes through the host name, which Debian maps to 127.0.1.1.

**The unit is sandboxed to a recorded exposure.** `deploy/vigil.service`
carries kernel and cgroup protections, three address families, a system-call
filter, empty capability sets, `UMask=0077`, no crash dump and no core file
(a dump is the node's memory, secrets included), a read-only `.ssh` and start
limits. The target is `systemd-analyze security vigil` at 3.0 or lower, and it
is enforced where a unit is installed: `setup.sh` and
`update.sh --update-unit` score the file offline and refuse one above it.
`MemoryDenyWriteExecute` stays off because the BEAM's JIT writes the code it
runs; it goes on only after a boot and a write under it in the target
container.

**The push safety net runs in the service's sandbox.** It was a cron line run
as root: it named the vault path, took its lock in world-writable `/tmp`, ran
git outside the sandbox and so ran the vault's hooks, had no timeout, and a
failure went to syslog and nowhere else. It is now `deploy/vigil-push.service`,
started by `vigil-push.timer`, running `scripts/push_pending.sh` as `vigil`
with `vigil.service`'s sandbox block copied unchanged and scored against the
same target. It is not given root to read `/etc/vigil/env`: systemd reads the
file for it (`EnvironmentFile=`) and hands it the values, and `lib.sh`'s
`env_file_value` asks the environment when the file cannot be read, so the
script and the root scripts read one file. The lock is in the unit's
`RuntimeDirectory=` (`/run/vigil-push`, 0700, the service user's), and the
script refuses a lock directory anyone else could write to — `/run/lock`, the
first replacement for `/tmp`, is writable by everyone too. Hooks are off
(`core.hooksPath=/dev/null`); the push has the server's ssh options and
`VIGIL_PUSH_TIMEOUT` seconds, the unit five minutes.

**Every failed run fails the unit, and the unit says so.** A failed or stopped
push exits non-zero, which puts the reason in the unit's journal and starts
`OnFailure=vigil-notify@%N.service`. There is no grace period for a failure
that might be transient: a push that is retried every 15 minutes and fails
every time says so every time, which is noisier than necessary and never
silent. Separately, commits that have waited longer than
`VIGIL_PUSH_ALERT_AFTER` minutes (60 by default; the oldest pending commit's
committer date is when the wait began) fail the run on their own, so a run
that could not push for a reason it did not see — the lock taken — still
reports what matters. The notification is a template whose shipped command
logs one line at priority `crit`; what an operator is actually told by is
theirs to set in a drop-in (`docs/guide.md`, "The push safety net"), because
vigil has no mail, pager or webhook of its own to assume. `init.sh` installs
the three units; `update.sh` reinstalls them on every update rather than
behind `--update-unit`, since the timer runs a script from the checkout the
update has just moved, and removes the cron file on a host that still has it.

**The operator scripts never expose a secret.** A secret reaches no argument
vector, no trace and no journal line. `verify()` hands curl the bearer, the
session id and the body (which carries the SkillKey) as a config on its stdin
(`curl -K -`, `lib.sh`'s `mcp_post`), because every local user can read
another process's arguments. `--verbose` is
`set -x`, and a trace prints every word after expansion, so the stretches that
hold a secret — generating one, writing the env file, `update.sh` sourcing it,
seeding and using tokens, `verify()` — run between `hide_trace` and
`show_trace`, which nest. An operator's answer is an argument, never spliced
into a `bash -c` string, and the service account is reached with `runuser`,
which takes the command as words rather than a string `su -c` hands a shell
to parse again. In the env file an answer is written by `env_line`: bare when
it is only characters nothing treats specially, otherwise double-quoted with
`\`, `"`, `$` and `` ` `` escaped. Of that and `printf %q`, which the ticket
named, the double quotes: the file has three readers — systemd's
`EnvironmentFile=`, `source` as root, and `env_file_value` — and those four
escapes inside double quotes are the ones all three read back the same, where
`%q`'s `\ ` and `$'…'` forms are bash's alone. A value with a line break is
refused. `setup.sh` removes the Cloudflare account certificate
(`/root/.cloudflared/cert.pem`, which controls every tunnel in the account)
once the tunnel is created and its DNS route made; the tunnel runs on its own
credentials file. When the route has to be made by hand, the certificate stays
and the next steps say to remove it.

**A secret is rotated on its own, and rotating it revokes nothing.**
`scripts/rotate_secret.sh password` or `skillkey` replaces that one line in
`/etc/vigil/env` — atomically, keeping the file's mode, owner and every other
line — and restarts the service, since a running node keeps the secret it
started with. It prints neither value. It revokes no token: a grant was given
by someone who knew the old password, and whether that still stands is a
separate decision, made with `scripts/grants.sh revoke-all`, which the script
names. `init.sh --force` keeps the same rule for the file: the settings it
decides — the paths, its answers (defaulting to the file's own values) and
both secrets, which `--force` is for — replace their lines, its defaults are
added only where the file has none, and every other setting is kept rather
than the file being rewritten from its list. It restarts the service instead
of starting it, so the new secrets are live.

---

## What vigil keeps stable

From 1.0 the version number is a promise, and
[compatibility.md](compatibility.md) is its text: which parts are kept stable
(the tools, `initialize`, the OAuth metadata and scopes, the settings, the
OAuth state, the vault conventions, the operator scripts), what a major, minor
or patch change to each is, and how something is deprecated.
`CHANGELOG.md` names every change to one of them. What is decided here is how
the code is held to it.

**What a client is handed is recorded, and recording it needs a changelog
entry.** The tool list, the `initialize` result and the two OAuth metadata
documents are recorded as they are served. Tool results are recorded as
*shapes* — every string `"string"`, a list as the merged shape of its items —
driven through `/mcp` against the fixture vault: the values belong to the
fixture, the keys and types are what a client parses. `serverInfo.version` is
recorded as a placeholder, since it changes with every release by design. CI's
"Contract changes" job diffs a pull request (or a merge group) against its base
with three dots and fails when a file under `test/fixtures/contracts/` changed
and `CHANGELOG.md` did not. It is a script, `scripts/check_changelog.sh`, so
it runs the same locally; a push to main has no base to compare with and
passed it as a pull request.

**The OAuth state says which version it is, in a file of its own.**
`oauth_meta.dets` holds `{:schema_version, 2}`; version 1 — and a state dir
with no version at all, which is what 0.2.0 and everything before wrote — keys
codes and tokens by their raw value, version 2 by their digest. A reserved key
inside one of the three tables was the alternative and was rejected: every walk
over a table (the janitor's sweep, `grants.sh`'s listings, `revoke_all`) would
have to know to step around it. The version is read before any table is
opened, and read-only: a newer one than the release knows refuses the start
with both numbers and the state dir in the journal, and leaves every file as
it was, so the newer release still finds its state when it runs again. An older
one, or none, is migrated and then marked; the marker is written last, so a
boot interrupted in between migrates again. The digest rekeying still runs on
every open, whatever the marker says: `init.sh --keep-token` carries an old
instance's `oauth_tokens.dets` into a state dir, and raw keys can arrive under
a version-2 marker that way.

**A switch that moves a chunk id is asked about.** Which ids a release derives
is a property of the release, so the comparison asks the two releases, on the
vault as it is now: the running one through `bin/vigil eval
'Vigil.Release.chunk_ids()'` (a VM of its own that loads the code, starts
nothing and prints only the ids), the target through `mix vigil.slug_diff
--against` in the checkout. It runs after the build, before anything is
switched, because the target has to be compiled — for the release, so the
comparison costs no compile of its own. The vault and `VIGIL_EXCLUDE` are
handed to both in the environment, so both walk the same notes whether or not
`eval` read `config/runtime.exs`. A change is shown id by id and asked about;
under `--non-interactive` it is refused (exit 2) unless `--accept-id-changes`
is given, and declining is exit 4, the running service untouched either way.
A running release built before `Vigil.Release` existed cannot answer; the
switch is then not compared, and `update.sh` says so rather than refusing
every first update to 1.0. `mix vigil.slug_diff` now evaluates
`config/runtime.exs` (`app.config`) as well: without it the task never saw
`VIGIL_EXCLUDE` on a real run and walked excluded directories.

**The notices are held to the lock by the suite.** `THIRD_PARTY_NOTICES.md` is
written by hand and `mix.lock` by Mix and Dependabot, so the notices lagged a
`tz` bump. `test/vigil/third_party_notices_test.exs` compares every row's
package and version with the lock, both ways; it runs in CI's test job with
the rest of the suite rather than as a script of its own, since reading the
lock is a `Code.eval_file/1`.

---

## No audit log — the history is read, not kept

Every write is a commit, authored `vigil <vigil@local>`, and a human's edits
arrive as commits of their own. What a note went through is therefore already
recorded, in the one place principle 3 puts metadata; a log vigil kept beside
it would be a second statement of the same facts, free to disagree. So there
is none, and the history is read instead.

**`history(path, limit)` lists the commits that touched a note**, newest
first, following renames (`git log --follow`): each with its `commit`, its
`date` (the author date), its `author`, its `message` (the subject line — a
human's body is not vigil's to reproduce), `by` and the `path` the note had
in that commit. `by` is `vigil` or `human`, and it is decided by the author's
address, not the name: every commit vigil makes is authored from
`vigil@local`, while a human may call themselves anything, `vigil` included.
`limit` is 1–100, default 20. A path with no history at all is "Not found".

**`read(id, at: <rev>)` reads a note or chunk as it was at a revision.** The
file at that commit is read through the Git value (`show`), parsed with the
normal parser and rendered as `read` renders the current one, plus `at`, the
full commit id. The id's path is the one the note had then — `history` names
it per commit — and the old text is read against today's vault, so its
`links` counters and backlinks are today's. The revision is verified before
anything is read: it is handed to `git rev-parse --verify --end-of-options`
peeled to a commit, so it can be neither an option nor a tree or a blob, and
a revision starting with `-` is not tried at all. A revision that names no
commit is a tool error, "Unknown revision". An empty `at` names no revision
and is read as `read` without one.

**Both read only what the index could hold.** The history holds every file
ever committed — an excluded directory's, `skills/`, a README at the vault
root, a template, a file that is not Markdown — and neither read may become
the way around the boundary `VIGIL_EXCLUDE` draws or the layout the index is
built from. So the requested path, and every name `git log --follow` traced
the note back to, is put to the current `Vigil.Vault.Layout` first. A path
that fails the safety check is "Invalid path", as for `read`. One that is
excluded, a skill, or no note is answered as a path with no history: "Not
found", from `history`, and "Not found … at <rev>" from `read` at a
revision — the same words a note that is simply not there gets, so neither
says whether the file exists. A commit that knew the note under such a name
(a note moved out of an excluded directory) is left out of `history`, and
`read` at that commit under the old name is "Not found". A path shaped like a
note in a domain or project directory that is no longer there is still a
note: its history is what is left of it.

Both are reads like the others: answered inside the writer's read clause, and
so fetched first once per interval (see "Reads see what another clone
pushed"). `Vigil.Git.CommitLog` answers both out of what it recorded, and the
contract suite holds it and the repository to the same answers.

## Deliberate non-goals

Not built, and not "prepared for" either:

- No graph layer — the link index is enough; a graph waits for a query that
  needs one
- No vector store, no embeddings, no semantic search
- No scheduler, no cron, no notifications
- No automatic summaries or journal entries — only explicit tool calls write
- No Phoenix, no Ecto, no database
- No LLM call inside the server
- No file watcher — vigil is the only writer of its working tree; a human's
  commits arrive through the remote and are adopted on read (at most once per
  `VIGIL_READ_FETCH_INTERVAL`), write, restart or `reload`
- No `create_domain` tool — the server creates no structure, because it would
  then be deciding its own filing system
- No write access to `_domains.yml`
- No audit log — writes are in the Git history, reads are uninteresting;
  the history is exposed by a read tool rather than kept a second time (see
  "No audit log — the history is read, not kept")

---

## Known trade-offs

**All reads serialize through one GenServer.** The index (`Vigil.Index`) is a
plain value held in `Vigil.Store`'s process state, so every read is a
`GenServer.call`. For a single-user knowledge base this is a feature — it
makes writes atomic with respect to reads — but it is a real ceiling if the
workload ever becomes concurrent. A read that is due to fetch (see "Reads see
what another clone pushed") holds every call behind it for up to the fetch's
five-second timeout, once per interval.

**The full index rebuild on every write is O(vault), not O(change).** Cheap at
the sizes this targets, measured above. It would need revisiting an order of
magnitude further out.

**Slug changes are breaking changes.** Because chunk ids derive from headings,
editing a heading changes its id and breaks stored references to it.
`mix vigil.slug_diff` makes the blast radius visible; nothing makes it zero.
A release that changes how ids are derived is a major version
(docs/compatibility.md), and `update.sh` compares the running release's ids
with the target's on the real vault before it switches (see "What vigil keeps
stable").
