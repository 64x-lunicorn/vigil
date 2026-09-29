# Compatibility

From 1.0 on, vigil's version number says what an upgrade can break. This page
is the promise: which parts of vigil are kept stable, what counts as a major,
minor or patch change to each, how something is retired, and what holds the
code to it. [`CHANGELOG.md`](../CHANGELOG.md) is where every change to one of
these parts is named, release by release, with what an operator has to do.

Before 1.0 (0.1.0 to 0.2.0 and what followed them) none of this applied, and
the changelog's "Upgrading" notes are the record of what moved.

---

## Semantic versioning

vigil follows [Semantic Versioning 2.0.0](https://semver.org/). A version is
`MAJOR.MINOR.PATCH`, and for the parts listed below:

- **Major**: something written against the previous release stops working
  unchanged — a client's calls, an assistant's stored references, an
  operator's env file, state dir or automation.
- **Minor**: something is added, and everything that worked keeps working —
  a new tool, an optional parameter, a new result field, a new setting whose
  default keeps today's behaviour, a new script flag.
- **Patch**: a fix that changes none of the parts below, or brings the code
  back to what they already say.

"Keeps working" is judged against what this page and the documents it points
to state, not against every observable detail. What is deliberately not
covered is listed [at the end](#not-covered).

| Part | Recorded in | Major | Minor | Patch |
|---|---|---|---|---|
| [MCP tools](#the-mcp-tools) | `test/fixtures/contracts/mcp_tools_list.json`, `mcp_tool_results.json` | a tool, parameter or result field removed or renamed; a parameter newly required or narrowed; a value's type or meaning changed; an annotation loosened | a tool, an optional parameter or a result field added; a bound widened | a description reworded without changing what it says |
| [`initialize`](#the-initialize-result) | `mcp_initialize.json` | a protocol version dropped; `serverInfo.name` changed; a writing rule removed or reversed | a protocol version or a capability added; a rule added | wording that keeps each rule's meaning |
| [OAuth](#oauth-metadata-and-scopes) | `oauth_authorization_server.json`, `oauth_protected_resource.json` | an endpoint path, grant type, response type, PKCE method or scope removed or changed | a metadata field or a grant type added | — |
| [Settings](#settings) | the guide's [configuration table](guide.md#configuration), `deploy/vigil.env.example` | a variable removed or renamed; a default changed; a value that booted refused | a variable added whose default keeps today's behaviour | — |
| [OAuth state](#the-oauth-state) | `Vigil.OAuth.Store.schema_version/0` | a state dir this release's predecessor wrote is not read | a new schema version that migrates the older ones on first boot | — |
| [Vault conventions](#the-vault-conventions) | `test/fixtures/slug_examples.json`, `docs/design.md` | a chunk id, slug or path of an existing note moves; a note that was read is no longer read the same way | a convention added that no existing vault breaks | — |
| [Operator scripts](#the-operator-scripts) | each script's `--help`, `scripts/lib.sh`'s exit codes | a flag removed or renamed; an exit code's meaning changed; a default changed | a flag or a subcommand added | — |

A change that fixes a security vulnerability may break one of these parts in a
minor or patch release when waiting for a major would leave installations
exposed. The changelog then says so under "Security" and gives the operator's
steps under "Upgrading".

---

## The MCP tools

Covered: every tool's **name**; its **parameters** — name, JSON type,
whether it is required, enum values, and the bounds it declares (`minimum`,
`maximum`, `maxLength`); its **annotations** (`title`, `readOnlyHint`,
`destructiveHint`, `idempotentHint`, `openWorldHint`) and which scope may
call it; and the **result** each call answers.

A `tools/call` result is one text content item holding a JSON object, and
that object is the **envelope** plus exactly one of:

- `result` — the tool's answer, whose keys and types per tool are recorded in
  `test/fixtures/contracts/mcp_tool_results.json`;
- `error` — a string, with `isError: true` on the content's result.

Beside it, the time envelope carries exactly one of `_` (a session's first
response), `_t` (the time) or `_!` (an event started or ended), and a read
answered from a vault that could not be brought up to date carries
`stale: true` (docs/design.md, "The time envelope", "Reads see what another
clone pushed"). Paged reads answer `{…, next_cursor}`; a cursor is opaque,
belongs to the parameters of the call that handed it out, and is refused once
a write changes that call's answer (docs/design.md, "Reads that enumerate are
paged").

Major: removing or renaming a tool, a parameter or a result key; making an
optional parameter required; narrowing an enum or a bound; changing a key's
type (a string that becomes a list, a value that becomes nullable); changing
what an existing parameter or key means; marking a tool less restricted than
it was (an annotation that stops saying destructive, a write callable with
`vault:read`). Minor: a new tool; a new optional parameter; a new key in a
result or an item of one; a wider bound; a stricter annotation. The text of an
`error` is for people and is not covered — branch on `isError`, not on its
words.

The protocol around the tools is covered too: the JSON-RPC methods vigil
answers (`initialize`, `notifications/initialized`, `ping`, `tools/list`,
`tools/call`), sessions (`Mcp-Session-Id`, issued by `initialize`, required
after it, ended by `DELETE /mcp`), and the status codes of `/mcp` as the
[guide](guide.md#security-model) and [oauth.md](oauth.md) state them.

---

## The `initialize` result

Covered: the protocol versions vigil negotiates (today `2025-11-25`,
`2025-06-18` and `2025-03-26`; docs/design.md, "Protocol versions"),
`serverInfo.name` (`vigil`), `title` and `websiteUrl`, `capabilities`, and
the **instructions** — the writing rules handed to the assistant, shaped by
`VIGIL_VAULT_OWNER` and `VIGIL_VAULT_LANGUAGE`, followed by the vault's
`_domains.yml`. `serverInfo.version` is the release's version and changes with
every release.

The instructions steer what an assistant writes into a vault the owner keeps
for years, so a rule that is removed or turned around is a major change even
though no parser notices it. A rule added is minor; rewording that keeps every
rule's meaning is a patch. The recorded document is
`test/fixtures/contracts/mcp_initialize.json`.

---

## OAuth metadata and scopes

Covered: the RFC 8414 authorization-server metadata and the RFC 9728
protected-resource metadata as recorded in
`test/fixtures/contracts/oauth_authorization_server.json` and
`oauth_protected_resource.json` — endpoint paths, `scopes_supported`,
grant and response types, `S256` as the only PKCE method, public clients
(`token_endpoint_auth_methods_supported: none`), the `iss` response parameter
and Client ID Metadata Documents — and the two scopes: `vault` (every tool)
and `vault:read` (the read tools and `reload`). How a scope maps onto the tools
is part of [the tools](#the-mcp-tools) above. [oauth.md](oauth.md) describes
the rest of the surface; token lifetimes and rate-limit budgets are settings
or documented values, and a change to one is named in the changelog.

---

## Settings

Covered: every `VIGIL_*` variable in the guide's
[configuration table](guide.md#configuration), with its default and what the
boot check accepts. An env file that boots one release boots every later
release of the same major version and means the same there.

Major: a variable removed or renamed; a default changed; a value that booted
before refused now; a variable newly required. Minor: a new variable whose
default keeps today's behaviour. When a minor release needs the operator to add
a line anyway — a required secret, say — that is a major change unless it
fixes a vulnerability (see above), and "Upgrading" says what to add.
`update.sh` checks for the one line of that kind so far, `VIGIL_SKILLKEY_SECRET`,
before it changes anything, and stops (exit 2) when it is missing. Any other
setting a release refuses stops that release at boot instead: the switch's
health wait fails, and `update.sh` rolls back to the release that ran before.

---

## The OAuth state

What the authorization server keeps lives in `:dets` files under
`VIGIL_STATE_DIR`: `oauth_clients.dets`, `oauth_codes.dets`,
`oauth_tokens.dets`, and `oauth_meta.dets`, which holds the **schema version**
of the other three.

| Version | Written by | Codes and tokens are kept under |
|---|---|---|
| none | 0.2.0 and before | their raw value |
| 1 | no release; the number of the format above, should it be marked | their raw value |
| 2 | 1.0 and later | `{:sha256, digest}` of their value |

- **Backward:** a release reads the state dir of every earlier release. A
  state dir without a version, or with an older one, is migrated when the
  store opens it, and marked with the release's version afterwards; a boot
  interrupted part-way migrates again. Nothing is asked of the operator and no
  client has to authorize again.
- **Forward:** a release refuses to start on a state dir marked with a newer
  version than it knows, names both versions in the journal, and changes
  nothing. This is what a rollback past a schema change meets: run the newer
  release again, or restore the state dir from the backup taken before the
  update. `update.sh`'s own rollbacks put back the copy of the state it took
  at the switch, when it was taken for the release they return to (see the
  guide's [Operations](guide.md#operations)).

A new schema version with an automatic migration is a minor change; the
changelog says under "Upgrading" that a rollback past it needs that backup.
A state dir that is not migrated forward — one whose clients have to
authorize again — is a major change.

---

## The vault conventions

Covered: what makes a file a note (the domain directories, `projects/<name>/`,
`_` and `.` directories and `skills/` outside the model, `VIGIL_EXCLUDE`), the
frontmatter's `type` and an event's `starts` and `ends`, `_domains.yml`'s
keys, how a note is chunked, and how a **chunk id** and a **slug** are derived
(docs/design.md, "The vault model", "Chunking", "Path normalization and naming
rules"). A chunk id is `path#heading-slug`, the note's preamble has the path
itself, and a colliding heading takes `-2`, `-3`, …; the slug of a name is
`Vigil.Slug.slugify/1`, whose recorded examples are
`test/fixtures/slug_examples.json`.

Chunk ids and slugs are what an assistant's stored references and every
`[[note#heading]]` link are made of. A change that moves the id or the slug of
something in an existing vault is a **major** change, however small the rule.
`update.sh` holds a switch to that: before it switches releases it asks the
running release for the chunk ids it derives from the vault and has the target
compare them (`mix vigil.slug_diff --against`), and a switch that would move
one is asked about — or, under `--non-interactive`, refused unless
`--accept-id-changes` is given ([guide](guide.md#chunk-ids-across-an-update)).

A heading a human edits changes its own id; that is the vault changing, not
vigil, and no version number can promise it away.

---

## The operator scripts

Covered: the commands and flags of `scripts/setup.sh`, `init.sh`,
`update.sh`, `grants.sh`, `rotate_secret.sh` and `init_vault.sh`, as their
`--help` lists them, and their exit codes, which all of them share
(`scripts/lib.sh`; `init_vault.sh`, which creates a vault and nothing else,
uses `0`, `1` and `2`):

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | runtime error — anything not explicitly 2, 3 or 4 |
| `2` | preflight failed — nothing was changed |
| `3` | acceptance (`verify()`) failed; for `update.sh`, rolled back and running again |
| `4` | the operator declined |

`scripts/push_pending.sh`, which `vigil-push.service` runs, is covered by what
the unit does with it: it exits non-zero when a push fails or commits have
waited too long. The units under `deploy/` are covered by their names and by
what `update.sh --update-unit` adopts.

Major: a flag or command removed or renamed; an exit code that means
something else; a default that changes what a command does. Minor: a flag or
a command added.

---

## Deprecation policy

A covered part is removed or changed incompatibly only in a major release, and
only after it was **deprecated** in a minor release before it:

1. The changelog names it under "Deprecated", with its replacement.
2. The documents mark it deprecated where they describe it, and a tool's
   description or a setting's check says so where a user meets it: a
   deprecated setting logs a warning at boot, a deprecated tool or parameter
   says "Deprecated:" in its description.
3. It keeps working, unchanged, for the rest of that major version, and for
   at least one minor release.

A security fix can shorten this (see [above](#semantic-versioning)); the
changelog says so when it does.

---

## How this is held

- **Contract snapshots.** The documents a client is handed are recorded under
  `test/fixtures/contracts/` and compared byte for byte by
  `test/vigil/contracts_test.exs`: the tool list, the `initialize` result and
  the shape of every tool's result, and the two OAuth metadata documents.
  Recording a change is deliberate (`UPDATE_CONTRACTS=1`), and CI's "Contract
  changes" job refuses a pull request that changes a recorded contract without
  an entry in `CHANGELOG.md` (`scripts/check_changelog.sh`).
- **Slugs and chunk ids.** `test/fixtures/slug_examples.json` is checked
  against the Elixir and the Obsidian template's JavaScript copy, a change to
  it without an entry in `CHANGELOG.md` is refused like a contract's
  (`scripts/check_changelog.sh`), and
  `update.sh` compares the running and the target release's chunk ids on the
  real vault before every switch.
- **The state dir.** `test/vigil/oauth/store_schema_version_test.exs` reads a
  state dir without a version, marked older and marked newer;
  `store_compatibility_test.exs` holds the migration of a frozen pre-1.0 state
  dir.
- **Settings.** `Vigil.Settings.Check` is the one table of variables and what
  each accepts, and the guide's table documents it.

---

## Not covered

Log lines and the journal's wording; the text of an error or a refusal; the
`/healthz` body beyond its status code; the order of results that the tools do
not document as ordered; Elixir modules and functions, including the Mix
tasks; `scripts/lib.sh`'s functions and the test seams the scripts carry; the
release tarball's layout beyond `bin/vigil`; the Erlang distribution settings
of the release; and anything under `test/`. A change to one of these is still
named in the changelog when an operator would notice it.
