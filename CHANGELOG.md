# Changelog

Every change to vigil a client, an assistant or an operator would notice, by
release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and from 1.0 the version numbers follow [Semantic Versioning](https://semver.org/)
as [docs/compatibility.md](docs/compatibility.md) defines it for vigil. Each
release has an **Upgrading** note: what an operator has to do, or check, when
moving to it with `update.sh`.

A pull request that changes a recorded contract under
`test/fixtures/contracts/` names the change under "Unreleased", and CI refuses
one that does not.

## [Unreleased]

The road to 1.0: what vigil keeps stable is written down, and the gaps a year
of use and a review found are closed.

### Upgrading

Read all of it before the first `update.sh` to this version. Back up the state
dir first (the [backups](docs/guide.md#backups) section of the guide): the
OAuth state is migrated on first boot, and a release before this one cannot
read it afterwards.

- **Check out this version first, then run `update.sh`.** Bash keeps reading
  the script it started with, so `update.sh` from 0.2 would run this update
  with 0.2's steps: none of this version's preflight checks, and an
  acceptance check this version refuses (0.2's sessions), which rolls back
  after the OAuth state was already migrated — every client would authorize
  again. Move the checkout yourself, so that this version's `update.sh` is the
  one that runs:

  ```bash
  sudo -u vigil git -C /opt/vigil/repo fetch --tags
  sudo -u vigil git -C /opt/vigil/repo checkout v1.0.0
  cd /opt/vigil/repo && sudo ./scripts/update.sh --to v1.0.0
  ```

  The running revision is read from the release, not the checkout, and a run
  that stops puts the checkout back on it. From this version on `update.sh`
  hands the run to the target's own `update.sh` once it has moved the
  checkout, so later updates need no such step.
- **Add `VIGIL_SKILLKEY_SECRET` to `/etc/vigil/env`.** The SkillKey now has a
  secret of its own instead of the consent password, and the service refuses to
  boot without one. `update.sh` checks for the line before it changes anything
  (exit 2) and prints the command that adds it, with the checkout already on
  this version: `sudo ./scripts/rotate_secret.sh skillkey`.
  Every SkillKey a client holds is invalid after the switch; the next
  `skill_read('vigil-vault-conventions')` hands out a new one.
- **Check `VIGIL_GIT_REMOTE`.** Its default is now `github`, the remote
  `init.sh` creates, instead of `origin`. A vault whose remote is called
  something else needs the line; the boot check refuses a remote the clone does
  not have and names it. `VIGIL_GIT_BRANCH` is new: unset, it is the clone's
  checked-out branch when that tracks one on the remote, `main` otherwise, and
  it must track `<remote>/<branch>` and be the branch checked out.
- **Set the trusted-proxy lines for the tunnel.** cloudflared runs on the same
  host, so the peer vigil sees is loopback, and the Cloudflare edge ranges the
  guide used to suggest never matched. A new `init.sh` writes
  `VIGIL_TRUSTED_PROXY_HEADER=CF-Connecting-IP` and
  `VIGIL_TRUSTED_PROXIES=127.0.0.1/32,::1/128`; add both to an existing env
  file, or the rate limits and the consent lockout count every client as one
  address.
- **`VIGIL_TZ` now defaults to `UTC`**, no longer `Europe/Berlin`. `init.sh`
  always wrote the zone, so a scripted host is unaffected; an env file without
  the line moves every timestamp. An unknown zone refuses to boot rather than
  becoming UTC.
- **Every setting is checked at boot**, and a bad one stops the start with a
  message naming it: ports, budgets and the SkillKey window must be positive
  integers, `VIGIL_READ_FETCH_INTERVAL` non-negative, `VIGIL_BIND` an address,
  `VIGIL_ALLOWED_ORIGINS` a list of origins, and in prod `VIGIL_ISSUER` and
  `VIGIL_RESOURCE` must be `https` on one origin. A value 0.2.0 silently
  replaced by its default now refuses to boot.
- **New settings**, each with a default that needs no line:
  `VIGIL_ALLOWED_ORIGINS` (empty — a browser-based client such as the MCP
  Inspector needs its origin listed), `VIGIL_RELOAD_RATE_LIMIT_RPM` (6),
  `VIGIL_CONSENT_FAILURES_PER_HOUR` (50), `VIGIL_READ_FETCH_INTERVAL` (60),
  and for the push safety net `VIGIL_PUSH_TIMEOUT` (120) and
  `VIGIL_PUSH_ALERT_AFTER` (60).
- **The push safety net is a systemd timer.** `update.sh` installs
  `vigil-push.service`, `vigil-push.timer` and `vigil-notify@.service` on every
  update that stands, removes `/etc/cron.d/vigil-push-safety-net` and enables the timer.
  Replace the notification unit's `ExecStart=` in a drop-in to be told about a
  failed push ([the push safety net](docs/guide.md#the-push-safety-net)).
- **Adopt the hardened unit with `update.sh --update-unit`.** The shipped
  `deploy/vigil.service` gains a sandbox scored at an exposure of 3.0 or lower;
  without the flag the old unit stays and `update.sh` says so. The release node
  now listens on loopback only (`vigil@127.0.0.1`, no epmd, port 4370) and its
  cookie is `0400`. The published tarball carries no cookie: a release
  unpacked from it writes its own on the first `bin/vigil` command, run as the
  service user (`sudo -u vigil <release>/bin/vigil version`).
- **Mask epmd on a host set up before this.** Debian's `erlang-base` enables
  `epmd.socket`, which listens on port 4369 on every interface; `setup.sh` now
  stops and masks it. On an existing host:
  `sudo systemctl disable --now epmd.socket epmd.service && sudo systemctl mask epmd.socket epmd.service`.
- **The OAuth state is rekeyed on first boot.** Codes and tokens are kept
  under their SHA-256 digest instead of their value; the first boot rewrites
  the files and logs how many rows it moved, and every client stays connected.
  The state dir now records its schema version in `oauth_meta.dets`. A release
  before this one does not find the rekeyed tokens: after a rollback past this
  version every client authorizes again, unless the state dir is restored from
  the backup.
- **MCP sessions are required.** `initialize` issues an `Mcp-Session-Id`, and
  every later request must carry it: none is a 400, an unknown or expired one a
  404, which a client answers by initializing again (after every restart).
  Claude's clients do this; a script that calls `/mcp` directly has to
  initialize first. A session ends after an hour without a request or on
  `DELETE /mcp`.
- **`search` answers `{results, next_cursor}`** instead of a bare list, and
  takes a `cursor`. `lint` and `links` at depth 2 are capped and say
  `truncated`. A client that parsed the list breaks.
- **Scopes are an allow-list.** A write needs exactly `vault`; `tools/list`
  shows a `vault:read` token only the tools it may call. An empty scope at the
  token endpoint is `vault`.
- **Seeded tokens live 90 days** instead of ten years (`init.sh`,
  `mix vigil.seed_token`). Tokens already seeded keep their lifetime:
  `sudo ./scripts/grants.sh list` shows them, and `revoke` or `revoke-all`
  ends them.
- **The conventions skill can no longer be replaced through `skill_write`**,
  and replacing any other existing skill needs `confirm: true`. Edit
  `skills/vigil-vault-conventions.md` by hand and `reload`.
- **`update.sh` compares chunk ids before it switches**, from the release after
  this one on (this version is the first that can list its own). A switch that
  would move one is asked about, or refused under `--non-interactive` unless
  `--accept-id-changes` is given. Unattended updates may need the flag.

### Added

- `docs/compatibility.md`: what vigil keeps stable from 1.0 — the tools,
  `initialize`, OAuth metadata and scopes, settings, the OAuth state, the vault
  conventions and the operator scripts — what a major, minor or patch change
  to each is, and the deprecation policy. This changelog.
- Contract snapshots for the `initialize` result (instructions included) and
  the shape of every tool's result, beside the tool list and the OAuth
  metadata; CI fails a pull request that changes one without a changelog entry
  (`scripts/check_changelog.sh`).
- `oauth_meta.dets` with the OAuth state's `schema_version`: older state is
  migrated and marked, state from a newer release is refused with both
  versions named and left untouched.
- `update.sh` compares the running release's chunk ids with the target's
  before switching (`bin/vigil eval 'Vigil.Release.chunk_ids()'`,
  `mix vigil.slug_diff --against <ids-file> <vault>`), with
  `--accept-id-changes`.
- `list`: a domain's notes page by page, as cards (id, title, type,
  updated_at).
- `history` and `read` with `at`: the commits that touched a note, following
  renames, and a note or chunk as it was at one of them.
- `status` and `GET /healthz` (loopback only): whether the index is loaded,
  the writer answers and the branch is checked out, ahead/behind, the commits a force-push took off the
  remote (`rewritten`) and the last push; `update.sh` waits on `/healthz`.
- `move_note` with `update_links` rewrites every link to the moved note in the
  same commit; `rewrite_note` reports `broken_chunk_links`.
- `request_id` on every write, so a retried write is applied once
  (`already_applied: true`); `if_match` on `replace_section` and
  `delete_section`, against the `hash` `read` hands out per chunk.
- Tool annotations (`title`, `readOnlyHint`, `destructiveHint`,
  `idempotentHint`, `openWorldHint`), and `title` and `websiteUrl` in
  `serverInfo`.
- MCP protocol versions `2025-06-18` and `2025-03-26` besides `2025-11-25`.
- `scripts/grants.sh`: list and revoke grants and clients.
  `scripts/rotate_secret.sh`: replace the consent password or the SkillKey
  secret.
- `update.sh --rebuild`: build the running commit again, for an Erlang/OTP
  security update.
- `mix vigil.vault_check` names Markdown files vigil ignores
  (`b7_ignored_files`) and notes that are not UTF-8 (`b0_encoding`).
- New vaults get Obsidian templates, a Templater title script that slugs like
  vigil, and a Dataview dashboard; vault adoption keeps `.trash/` out of the
  history.
- Releases carry a CycloneDX SBOM, `SHA256SUMS` and a build-provenance
  attestation for every asset, packed deterministically.
- `docs/clients.md`: setup steps for Claude.ai, Claude Desktop, Claude Code,
  ChatGPT and Cursor, as drafts until tested.

### Changed

- `search` matches every word of a query, not only the phrase, and folds query
  and text the same way (`heizoel` finds `Heizöl`); phrase hits rank first.
- Reads fetch what another clone pushed, at most once per
  `VIGIL_READ_FETCH_INTERVAL`; a read that could not is answered with
  `stale: true`.
- Before every write the vault is brought up to date with the remote, and
  vigil's own unpushed commits are rebased onto a push from elsewhere instead of
  leaving the vault diverged. A rebase that conflicts is aborted and reported;
  a human's work is never merged or overwritten. Only vigil's own commits are
  replayed: what a force-push took off the remote leaves the vault too, and no
  push puts it back.
- No hook in the vault clone runs for vigil's commits, pushes, fetches,
  fast-forwards or rebases, and its pushes are never signed.
- `read` of a note returns its preamble, the text before the first `##`, as
  `body`.
- `update_frontmatter` edits only `type`, `starts` and `ends` and keeps every
  other key byte for byte.
- A note that is not UTF-8 is skipped with a warning and listed by `lint`
  instead of stopping the boot; a CRLF or BOM note keeps its line endings.
- `reload` has its own per-token budget, `VIGIL_RELOAD_RATE_LIMIT_RPM`.
- The consent lockout counts an IPv6 client by its `/64`, and all wrong
  passwords together have an hourly budget.
- An unknown tool is a JSON-RPC `-32602`, `GET /mcp` a 405, a 429 carries
  `Retry-After`, and a presented but invalid token's challenge says
  `invalid_token`.
- `update.sh` reads the running revision from the release, puts the code
  checkout back on it whenever a run does not end on the target, and rolls
  back a release that never comes up.
- `update.sh` hands the run to the target checkout's own `update.sh`, with the
  same arguments, as soon as it has moved the checkout, so an update is always
  made by the version it installs.
- `setup.sh` reaches GitHub over SSH on port 443 by default
  (`--github-ssh-port`).

### Removed

- The envelope's 24-hour "stale session" rule: a session lives no longer than
  its hour.

### Fixed

- A failed commit leaves the working tree and the index as they were, for
  every write, including `delete_note` and `move_note`.
- A write while another branch is checked out in the vault's clone — a
  `git switch` there after boot — is refused, and so is the update before it,
  naming `VIGIL_GIT_BRANCH` and the branch found; it used to commit on that
  branch, push `VIGIL_GIT_BRANCH` and answer `pushed: true`.
- `replace_section` refuses a replacement that opens a code fence and never
  closes it; `append`'s `heading` is one non-empty line.
- Heading parsing and the link rewrite of `move_note` take linear time on long
  runs of whitespace.
- `mix vigil.slug_diff` honours `VIGIL_EXCLUDE`; it walked excluded
  directories on every real run.
- `THIRD_PARTY_NOTICES.md` names `tz` 0.28.4, the locked version, and the suite
  now fails when it falls behind `mix.lock` again.
- The documentation says that a failed push answers success with
  `pushed: false`, that the `/mcp` budget counts every request, and how a
  seeded token relates to OAuth.

### Security

- OAuth codes and tokens are stored as SHA-256 digests, never as themselves,
  and the rate limiter counts under the digest too.
- The SkillKey is keyed with its own random secret, so a key handed to a
  client is no offline test of the consent password.
- `/mcp` and the authorization server's POST endpoints validate `Origin`.
- Client registration is bounded in size (16 KB body, 200-character name, 10
  redirect URIs), in number (1000 clients) and in lifetime (a client that never
  completes a consent is dropped after 24 hours).
- Every string parameter declares a maximum length, and `/mcp` bodies are read
  up to 8 MB (413 above).
- A Client ID Metadata Document is fetched only from globally routable
  addresses, by allow-list, with a resolution deadline.
- The consent password is compared by digest, so the time a guess takes does
  not depend on its length or the password's.
- The release node listens on loopback only, and the unit runs sandboxed.
- The operator scripts hand no token or secret to a command line or a
  `--verbose` trace, and write operator answers as values, never as code.
- `skill_write` cannot replace the conventions skill every session reads.
- CI runs Sobelow as a security scan, and verifies every tool it downloads.

## [0.2.0] - 2026-09-29

Write-path hardening, deployment fixes and cleanup.

### Upgrading

- **Prod refuses to boot without `VIGIL_VAULT_PATH`, `VIGIL_STATE_DIR`,
  `VIGIL_ISSUER` and `VIGIL_RESOURCE`**, and names the missing one. 0.1.1 fell
  back to the demo vault, the release directory or `localhost` instead.
- **The listener binds to `VIGIL_BIND`, `127.0.0.1` by default.** cloudflared
  on the same host is unaffected; a proxy on another host needs the line.
- **`VIGIL_EXCLUDE` applies at any depth.** A name listed there now also hides
  `projects/<name>/`, which was parsed, searchable and writable before.
- **Chunk ids of repeated headings can move.** A heading takes the first free
  `slug-2`, `slug-3`, … in document order; a note with `## Setup`, `## Setup`,
  `## Setup 2` used to give two headings the same id. References to such ids
  may need updating.

### Added

- `VIGIL_BIND`.
- `mix vigil.seed_token --ttl-seconds`; `update.sh`'s acceptance tokens live
  15 minutes instead of ten years.
- `setup.sh --tunnel-name` and `--hostname`, and a Cloudflare tunnel from
  Cloudflare's signed apt repository; `init.sh` asks for owner, language and
  time zone and takes `--ignore-audit`.

### Changed

- A failed push answers success with `pushed: false` and `push_error` instead
  of an error, so a client does not retry and duplicate content.
- Git's network calls are bounded (SSH keepalive and connect timeout, HTTP
  low-speed abort, no prompts), and a store call waits 120 seconds.
- A write that changes nothing succeeds with the note's last commit.
- `reload` is callable with `vault:read`: it catches the server up with the
  remote and changes nothing a note says.
- An unnamed client registers as "Unnamed client".

### Removed

- The vendored agent skills under `.agents/skills/`.

### Fixed

- Notes with non-ASCII names, and renamed notes, keep their creation and
  update dates across a restart.
- Redeeming a code and rotating a refresh token are serialized, so each is
  spent once.
- A malformed JSON-RPC body, batch or `tools/call` params, and malformed
  registration input answer protocol errors instead of a 500.
- `update_frontmatter` gives a note without frontmatter one.
- `vigil_seed_token` works against the running node again, so `init.sh` and
  `update.sh` no longer stop at seeding.
- The conventions skill and the SkillKey refusal name the installed skill,
  `vigil-vault-conventions`, and the key's real window.
- `setup.sh`, `init.sh` and `update.sh` work on a fresh Debian 13 container,
  and `init.sh` installs the push safety net as a valid `cron.d` file.
- The release notes and asset name state the OTP version without a doubled
  `OTP-` prefix.

### Security

- The SSRF guard in front of a CIMD fetch also refuses IPv4-compatible IPv6
  addresses, multicast and broadcast.

## [0.1.1] - 2026-09-11

The first published release: the same code as 0.1.0, whose release pipeline
stopped before it built anything.

### Upgrading

- Nothing to do. 0.1.0 published no artifacts; 0.1.1 is the first release to
  install.

### Fixed

- `release.yml` reads the declared version without compiling the project.

## [0.1.0] - 2026-09-11

First tagged release, never published. A self-hosted MCP server that turns a
Git-backed Markdown vault into long-term memory for an assistant.

### Added

- Tools: `search`, `read`, `links`, `create`, `append`, `replace_section`,
  `rewrite_note`, `delete_section`, `update_frontmatter`, `delete_note`,
  `move_note`, `lint`, `current`, `reload`, `skill_list`, `skill_read` and
  `skill_write`, declared once in a table that drives their schemas and
  validation.
- Chunk-level retrieval: a note is chunked at its `##` to `####` headings, and
  a chunk id is `path#heading-slug`.
- Every write is a commit, pushed to the vault's remote.
- An OAuth 2.1 authorization server: Authorization Code with PKCE, Dynamic
  Client Registration and Client ID Metadata Documents, scopes `vault` and
  `vault:read`, rotating refresh tokens.
- The SkillKey: writes need a key handed out with the vault's conventions.
- The time envelope on every tool response.
- `scripts/setup.sh`, `init.sh`, `update.sh` and `init_vault.sh` for a Debian
  host behind a Cloudflare tunnel, with automatic rollback.

[Unreleased]: https://github.com/64x-lunicorn/vigil/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/64x-lunicorn/vigil/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/64x-lunicorn/vigil/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/64x-lunicorn/vigil/releases/tag/v0.1.0
