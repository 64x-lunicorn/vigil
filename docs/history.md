# Implementation history

A record of what was built in each round and — more usefully — why, and what
went wrong. Kept because the reasoning is not recoverable from the diff.

This replaces a set of German work-order documents that were addressed to the
implementing agent. Those described work that is now finished; the code is the
authority for *what* the system does, and this file preserves the *why*.

---

## v1 — the original server

An Elixir server reading a Markdown vault, serving it over MCP, with a static
bearer token. Established the pieces that have not changed since: the ETS
index rebuilt from Git at every start, chunking at headings, phrase search with
an additive score, the time envelope, and one commit per write.

The design principles from this round are still the ones in force — see
[design.md](design.md).

---

## OAuth 2.1

The static bearer token was **replaced**, not supplemented: Anthropic's
connector documentation did not support user-pasted bearer tokens, only
`oauth_dcr`, `oauth_cimd` and `oauth_anthropic_creds`.

vigil became its own authorization server. Details in [oauth.md](oauth.md).

The decision worth recording: **opaque tokens rather than JWTs.** Issuer and
verifier are the same process, so a JWT would have bought a signature
dependency and a class of audience-claim bugs that cannot exist with a lookup.

---

## v2 — write-path safety and the missing tools

Driven by real failures in daily use.

**Writes could commit locally and never push.** `git branch -vv` showed two
commits ahead of the remote with no error ever surfaced to the client — a
silent data loss window. Fixed by making push part of the write path and
reporting failure to the caller, plus a cron safety net for the case where a
push failed at write time.

**A failed write took the whole server down.** A `create` into a directory the
service could not write to crashed `Vigil.Store`, after which every tool —
including `read` and `search` — answered with a GenServer timeout. Fixed by
converting filesystem errors into error tuples that never propagate.

**Tools were missing.** There was no way to delete a note, move one, change
frontmatter, rewrite a note wholesale, or remove a single section. Notes could
only ever grow. Added `rewrite_note`, `delete_section`, `update_frontmatter`,
`delete_note` and `move_note`.

**The one-writer principle needed enforcing.** Obsidian on iOS creates an
`.obsidian/` directory inside the vault on first open, which makes it a second
writer. Path validation now rejects any segment starting with `.` or `_`, and
the adoption phase adds the `.gitignore` entry.

**The SkillKey.** Write tools now require a rotating HMAC token that can only
be obtained by calling `skill_read` on the conventions skill. The point is not
access control — the OAuth token already did that — but proof that the writing
conventions were read *in this session*.

---

## Operations scripts

Three scripts plus a shared library, replacing manual deployment: `setup.sh`
(clean Debian → installed but not started), `init.sh` (vault, secrets, build,
start, acceptance check) and `update.sh` (switch revision, with automatic
rollback).

Tested end to end in a real Debian 13 container with systemd as PID 1, not
just reviewed. That found several genuine bugs:

**No UTF-8 locale on a fresh Debian 13.** `locale -a` listed only `POSIX`.
Without a UTF-8 locale the BEAM treats filenames as raw bytes, so a vault note
with non-ASCII characters in its name is listed by `File.ls` but then fails
`File.read` with "no such file or directory" on the very path that was just
returned. Fixed with `LANG=C.UTF-8` in the systemd unit and a preflight check.

**Token seeding against a running service silently produced dead tokens.** A
second `mix` process opened the same `:dets` files the running service already
had open; `:dets` is not built for that. The freshly seeded token landed in a
copy the service never saw, and every call with it returned 401. Fixed by
seeding through `bin/vigil rpc` in the running node.

**A bash parameter-expansion trap.** `"${4:-{}}"` does not do what it looks
like: bash closes the expansion at the first `}` after `:-`, leaving a stray
`}` in the string. Every call with a real fourth argument appended a surplus
`}` to the JSON. The obvious fix (`local args="$4"`) introduced a worse one:
under `set -u` an unset `$4` kills the entire shell with no error message.
`"${4:-}"` avoids both.

---

## Canonical paths and naming rules

Filenames were previously either accepted verbatim or rejected. Now they are
**normalized**: one canonical slug form for paths, directories and chunk ids,
so file names and `[[…]]` references cannot drift apart.

Because the same function produces chunk ids, changing it is a breaking change
for stored references. `mix vigil.slug_diff` was written for exactly that: run
it against a real vault before deploying a slug change and it lists every chunk
id that would move.

Domains gained optional naming rules in `_domains.yml` — a violation returns
the rule *and* a valid suggested path, rather than a bare rejection.

Also in this round: `delete`/`move` renamed to `delete_note`/`move_note`,
`pushed: true` on every successful write, and `rewrite_note` requiring
`confirm` only past a shrink threshold rather than always.

`skill_write` was brought under the SkillKey requirement like every other write
tool, which created a bootstrap deadlock — a fresh vault has no conventions
skill to read a key from. Resolved by having `skill_read` return the current key
in its error response too.

---

## Vault adoption and `--check-only`

A vault that predates vigil does not satisfy its assumptions. Rather than
discovering that one confusing error at a time during operation, `init.sh`
gained an adoption phase that separates two classes of finding:

- **Automatic fixes** — additive and deterministic, applied and committed:
  `.gitignore`, git identity, upstream remote, missing `_domains.yml` entries,
  directory permissions.
- **Report only** — anything touching content or addressing: frontmatter
  problems, non-canonical filenames, the chunk-id migration risk, unpushed
  commits, consolidation candidates. Never repaired automatically, because a
  batch repair would break every link to the affected notes at once.

The same check runs standalone as `--check-only`, read-only, safe against a
running service, with exit codes that make it usable from cron.

Two bugs found while testing it, both only visible when actually running it:

- The automatic fixes were staged but never committed, so they looked
  half-applied on the next look at the repo.
- `git commit -m … -- .obsidian` silently drops an already-staged directory
  deletion, even though `git diff --cached -- .obsidian` shows it. Fixed by
  committing without a pathspec at that point.

---

## The link index

`[[…]]` references were plain text: no backlinks, no way to see what pointed at
a note before moving it. That also made the backlink report promised by
`move_note` impossible to implement.

Links are now extracted per chunk and resolved centrally, with a
`same folder → same domain → vault-wide` cascade and explicit
`ok`/`ambiguous`/`broken` status. A new `links` tool exposes them; `read`
carries counters; `search` attaches the `hub` when a note has exactly one
incoming link; `move_note` and `delete_note` report what will break.

**The index is rebuilt in full on every write** rather than maintained
incrementally — that structurally rules out ghost entries after a delete or
rename instead of requiring every write path to get it right.

A performance bug was introduced and caught here: the first implementation
re-slugified every filename for every link, making the rebuild O(links × files).
Measured at 14 ms per link against 1000 files, a 2000-link vault would have
spent ~28 s per write, far past the 5 s GenServer timeout — and it would only
have surfaced once the vault grew. Building the candidate index once per
rebuild brought a full write to ~115 ms.

Alongside the code, a vault convention: split by **lifecycle, not by size**.
Two sections belong in different files when they change at different times.
Architecture that stays stable, a log that grows chronologically, and a spec
that changes in jumps are three files, not three headings — with a hub note
that carries content and one line per spoke saying when to read it.

---

## Translation to English

The project was originally written in German throughout — comments, error
messages, script output, documentation. All of it is now English, so the
repository is usable by people who do not read German.

Two things were deliberately **not** translated:

**Transliteration test data.** `{"ä", "ae"}` in the table, `"Küche" => "kueche"`
in the slug tests, and a fixture file with diacritics in its name. These are the
inputs that exercise the feature; replacing them would remove the coverage.

**The vault's own language.** The writing instructions handed to the MCP client
said "write in German" — a statement about the *notes*, not about the server.
Translating it literally would have made the assistant start writing English
notes into a German vault. It is now configurable via `VIGIL_VAULT_OWNER` and
`VIGIL_VAULT_LANGUAGE`, defaulting to English, which also removed the last
hardcoded personal detail from the codebase.
