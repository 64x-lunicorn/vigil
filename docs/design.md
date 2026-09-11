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
flag, the `Store` operation it calls, and its parameters' names, types and
required-ness — in a single table. Three things are generated from it: the
JSON schema published on `tools/list`, the argument validation `dispatch/4`
runs on `tools/call`, and the `Vigil.Store.call/3` that follows. They cannot
drift out of agreement the way hand-written twins do, and adding a tool is
adding a row.

**The call is the table's third product.** A row's `call:` names the
operation; its parameters travel under the names the table gives them.
`Vigil.Store` answers all but two of them — the two skill reads are answered
against `Vigil.Skills` in the caller's process, for the reason under
"`skills/` — one repository, two systems". The one
exception is `skill_key`, which is a parameter of no operation — it carries the
SkillKey of the Security model's layer 4, the gate reads it, and it does not
travel.

**`skill_key` is also the one parameter no row declares.** A tool takes one
because it writes, and the row already says `write: true` — the same flag the
gate reads the requirement off. So the parameter is derived from it too,
stated once rather than written out identically in nine rows, each free to
drift in its description or its required-ness while the gate went on requiring
the same thing. `confirm` is not derivable the same way and stays declared per
row: only three of the nine writes take one, and `write: true` does not say
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
integer, a missing or empty required parameter — is a tool error naming what
was expected, not a substituted default. A caller who claims `type: "bogus"`
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

The five reads share a single `handle_call` clause and so do the eight writes,
because in both groups the operation is the only difference: it names the
`Vigil.Index` function that answers a read, and `Vigil.Vault.Policy` and
`Vigil.Vault.Plan` already take a write as an argument. What stays per
operation is the contract — the head that matches what a call cannot do
without.

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
It is stated once, where a plan is executed — one clause for all three actions,
with what differs between them answered per action, one small function per
question: which effect to ask `Vigil.Commit` for, what the index does with what
comes back, what the success report says, and what object a push failure names. A report that can only be
*observed across* the effect — the references a move broke, a diff of incoming
links before against the rebuilt index after — is asked before the effect and
answered against the index it left behind, so that no action has to be a
special case of the sequence. If the push fails the local commit stays and the
tool returns an error naming what is committed locally but not pushed — the
change, the deletion, or the move. Nothing is rolled back.

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

**One writer per vault, under a name its caller supplies.** `Vigil.Store`
registers under its own module name by default, and a caller that hands in a
name gets a writer of its own, publishing through a table of that same name —
which is what lets the vault-backed test files run in parallel, one writer per
file, instead of the whole suite queueing behind a single registration.
Principle 2 is about a vault having one writer, not about a node having one.

**The tool layer takes the writer too.** `Vigil.MCP.Tools.dispatch/4` is
handed the store it calls, and the two skill reads resolve the vault path from
that same store rather than from the default one — a skill read answered
against another writer's vault is a read of the wrong vault. It defaults to
`Vigil.Store.default_name/0`, so production hands in no name and reaches its
own registration, and the atom is stated once, where the writer registers it,
rather than once per caller. What still names no store is `Vigil.MCP.Envelope`
and `Vigil.MCP.Server`.

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

**The value is the whole of `Vigil.Git`, not the write half.** Six questions:
`add_commit`, `remove_commit`, `move_commit`, `push` — and `pull` and
`log_metadata`, which no write ever asks. Those two belong to the load, and
`Vigil.Store` asks them directly. A seam drawn around the write effect alone
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

The speed is a consequence and not the argument. The argument is that
`Vigil.Store`'s order — perform, commit, reparse, push — was the one part of
the write path with no test that could fail on it, because exercising it meant
building a repository. An adapter that records its calls can be asked what
order they came in.

---

## OAuth persistence is reached through a value

The same shape, for what the authorization server remembers. Six modules —
`Vigil.OAuth.Client`, `Code`, `Token`, `Cimd`, `Flow` and `Janitor` — used to
reach storage by naming one globally registered module with hard-coded table
atoms. Nothing varied across it, so there was nowhere to substitute, and the
244 lines that own expiry, revocation, spent-token marking and the consent
lockout had no test of their own: they were exercised incidentally, through
endpoint tests.

**The value is the whole of what those six ask.** Fourteen questions,
declared in `Vigil.OAuth.Persistence`: a client written and read, a code
written and taken, a token written, read, deleted and revoked by family, the
consent attempts counted per address, the CIMD cache read and written — and
the sweep. The sweep is part of this surface rather than a concern beside it:
every expiry it drops belongs to one of the tables above, and the janitor asks
for it through the value it was handed like any other caller.

**It is a struct of functions with no defaults**, built by `struct!/2`, the
same rule as `Vigil.Git` and `Vigil.Vault.Facts`. Here the rule earns its keep
twice over: every one of these questions guards something, and every plausible
answer to a question nobody wired sits on the permissive side of the gate it
feeds. A `get_token` answering `:error` makes every token unknown; a
`rate_limited?` answering `false` turns the consent lockout off.

The production adapter is `Vigil.OAuth.Store.over_tables/0`, a function beside
the `:dets`/`:ets` implementation it wires. That module keeps the files'
lifecycle — opened under the state dir, `chmod 0600`, closed on terminate —
and stops being something the other five name.

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

**The lockout's window and the cache's hour belong to the contract**, not to
either adapter. They were `Vigil.OAuth.Store`'s private constants, which was
fine while there was one adapter and wrong the moment there were two: "the
lockout expires with its window" is a claim the suite runs against both, and a
window each adapter picked for itself would make that claim mean two different
things. `Vigil.OAuth.Persistence` states them once and both read them.

**One suite runs against both adapters, and it is the only thing that opens a
`:dets` file.** Everything persistence actually owns is asserted there, at the
seam rather than through an endpoint: that an authorization code is
single-use, that rotation marks a refresh token spent rather than deleting it
— the distinction the RFC 9700 §4.14.2 replay defence rests on — that revoking
a grant takes down the family minted from it and nothing else, that the
consent lockout counts per address and expires with its window, that the CIMD
cache honours its hour, and that a sweep drops exactly what has expired. What
only the production adapter can be asked is asked there too: that a token
outlives the process that stored it, and that the files it opens are readable
by their owner alone.

Eight test files used to `mkdir` a temp directory and open three `:dets` files
apiece to ask a question about a token, and every one of them was serial for
it. Six of the eight run in parallel now. Two are still serial, for reasons
that have nothing to do with persistence: `Vigil.OAuth.EndpointTest` sets the
rate-limit budgets and the trusted-proxy configuration in global application
env, and `Vigil.OAuth.JanitorTest` drives `Vigil.OAuth.Janitor` and
`Vigil.RateLimit`, both registered under their module names.

The speed is a consequence and not the argument, and here it is a small one.
The argument is that 244 lines owning expiry, revocation, spent-token marking
and the consent lockout had no test of their own — they were exercised
incidentally, through endpoint tests, which is why "a sweep removes exactly
what has expired and nothing else" was nobody's claim until it was the seam's.

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
   belongs to OAuth persistence. Every one of them is swept by
   `Vigil.OAuth.Janitor`, whose list of what to ask is its own: it asks
   persistence for the expiries persistence owns, and names `Vigil.RateLimit`
   for the one it does not. A budget bounds how fast rows arrive and a sweep
   bounds how many there are, and neither substitutes for the other.

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
