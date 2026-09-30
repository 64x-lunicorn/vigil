# Dashboard

Dataview queries over the vault. vigil does not read this page: a file at the
vault root is not a note, and `_templates/` is not a domain.

## Upcoming events

```dataview
TABLE starts, ends
FROM -"_templates"
WHERE type = "event" AND date(ends) >= date(today)
SORT starts ASC
```

## Decisions, longest untouched first

A decision ages. The ones at the top are the first to check whether they
still hold.

```dataview
TABLE file.mtime AS "Last changed"
FROM -"_templates"
WHERE type = "decision"
SORT file.mtime ASC
LIMIT 20
```

## Recently changed

```dataview
TABLE type, file.mtime AS "Changed"
FROM -"_templates"
SORT file.mtime DESC
LIMIT 15
```

## Notes without a type

vigil reads a note without a valid `type` as `reference` and warns about it.
Files at the vault root are left out: they are not notes.

```dataview
LIST
FROM -"_templates" AND -"skills"
WHERE !type AND file.folder != ""
```
