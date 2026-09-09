# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`docs/design.md`**: read the sections that touch the area you're about to work in. It carries both the architectural decisions and the vocabulary they are stated in.
- **`docs/history.md`**: why some of those decisions look the way they do, when the reasoning outlived the change itself.
- **`docs/README.md`** to find anything else: it indexes every document in the repo.

## File structure

Decisions and vocabulary live in one file. There is no `CONTEXT.md` and no `docs/adr/` here, and their absence is a choice, not a gap:

```
/
├── docs/
│   ├── design.md   ← architectural decisions and domain vocabulary
│   ├── history.md  ← the reasoning behind decisions already made
│   ├── guide.md    ← the user guide
│   ├── agents/     ← how this repo runs its own process
│   └── …           ← see docs/README.md for the full index
└── lib/
```

Skills that offer to create a `CONTEXT.md` or an ADR directory — `/domain-modeling` among them — are describing their own default layout, not this repo's. Here that offer is declined; the decision goes into `docs/design.md` instead.

`docs/design.md` is where anyone looking for a decision already looks, and where every decision already is. Splitting it into one file per decision would move the search cost onto the reader for the sake of a directory listing. A new decision is a section in `design.md`, phrased as a claim about the system — the way the sections already there are.

## Use the design doc's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as `docs/design.md` uses it — *chunk*, *domain*, *note*, *vault*, *the write path*, and so on. Don't drift to synonyms it avoids.

If the concept you need isn't there yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it).

## Flag design conflicts

If your output contradicts a decision in `docs/design.md`, surface it explicitly rather than silently overriding:

> _Contradicts "One writer" in `docs/design.md`, but worth reopening because…_

A decision that turns out to be wrong is corrected in `design.md` in the same change that breaks it — the doc and the code are expected to agree, and where they disagree the code is right and the document is a bug.
