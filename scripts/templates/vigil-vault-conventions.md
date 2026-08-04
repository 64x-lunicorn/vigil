---
name: vault-conventions
description: Required reading before any vigil write operation. Supplies the SkillKey and defines naming, frontmatter, and consolidation rules.
---

# vigil vault conventions

## SkillKey

The key at the top of this content is required as the `skill_key` parameter by:

`create`, `append`, `replace_section`, `rewrite_note`, `delete_section`, `delete_note`, `move_note`, `update_frontmatter`, `skill_write`

It rotates hourly and stays valid for the current and previous slot. **Do not track elapsed time** — if a write fails with a SkillKey error, call `skill_read` on `vault-conventions` again and retry the write with the new key.

## Paths and names

The server normalizes every path: lowercase, diacritics transliterated (`ä`→`ae`, `ö`→`oe`, `ü`→`ue`, `ß`→`ss`, `ø`→`oe`), spaces and punctuation to hyphens.

`projects/Corridor Release Status.md` → `projects/corridor-release-status.md`

When a path was changed, the response contains `path_normalized_from`. **Use the returned `path`, not the one you sent** — that is where the note actually lives.

Some domains define a naming schema in their `_domains.yml`. Violating it returns an error containing the rule and a valid suggestion; follow the suggestion.

Segments starting with `_` are reserved.

## Frontmatter

Three fields only: `type`, `starts`, `ends`.

- `type`: `reference` | `decision` | `event`
- `starts` / `ends`: ISO timestamps, **only** on `type: event`

`create` is the only tool that sets frontmatter on a new note. To change it afterwards use `update_frontmatter` — `append` and `replace_section` cannot, and `rewrite_note` deliberately preserves the existing frontmatter.

Event times matter beyond the note itself: `current` reports events as active based on them. A wrong `starts` makes the assistant believe an event is under way when it is not.

## Before creating a note

Run `search` on the topic first. Create a new note only when no existing note is the right home for the content — otherwise use `append` or `replace_section`.

Several notes under one project (`projects/<name>/…`) are normal and are not treated as duplicates.

If `create` returns a duplicate error, it lists candidate chunk IDs. Read one and write there instead of repeating the call with `force: true`.

## Headings

Headings are navigation points, not sentences. Short, nominal, no trailing punctuation. Write them in the same language as the rest of the vault.

Good: `Fueling`, `Open Questions`, `Deployment`
Bad: `How I fuel myself during a race.`

Never put content into a heading. If a heading carries the information, it belongs in the body.

## Consolidate instead of appending forever

Roughly at **30 headings or 2000 words**, stop appending and restructure:

- `rewrite_note` to regroup the whole note
- `delete_section` to remove duplicated or outdated sections

Repeated appending is how a note grows to 150 headings with duplicate titles. Once that has happened it can only be patched, not reorganized.

## Split instead of growing

When a topic outgrows its note, create a separate, clearly scoped note in the same project folder. That is the intended pattern, not a duplicate.

## Project structure

A project folder has one hub note (`projects/<name>/<name>.md`) and any number of spokes.

Split by lifecycle, not by size: two sections belong in different files when they change at different times. Architecture that stays stable, a log that grows chronologically, and a spec that changes in jumps are three files, not three headings.

The hub carries content — purpose, current state, decisions, open points — plus one line per spoke saying **when to read it**. A hub that is only a list of links is a worse `search`.

Link with `[[basename]]`; use `[[basename#chunk-slug]]` for a specific section. A link to a note that does not exist yet is a valid placeholder — it resolves as `broken`, not an error.

Use `links` to see what points at a note before restructuring or moving it.

## Destructive operations

- `delete_note` and `move_note` require `confirm: true`
- `rewrite_note` requires `confirm: true` **only** when the shrink threshold triggers (more than half the sections, or more than 20 headings, removed) — the error states this explicitly

Always `read` the target first so the operation hits what you expect. `move_note` returns a backlink report; check it for references that now point nowhere.

## Write results

A successful write returns `pushed: true`. If it returns a push error, the note is committed locally but has not left the server — report this to the user instead of retrying.