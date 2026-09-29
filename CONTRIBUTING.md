# Contributing to vigil

Thanks for helping make assistant memory more transparent and portable.
Bug reports, clearer documentation and focused code changes are welcome.

## Before you start

- Search [existing issues](https://github.com/64x-lunicorn/vigil/issues) before
  opening a new one. Discuss larger features or architectural changes in an
  issue before starting a pull request.
- Read the [project overview](README.md) and [design notes](docs/design.md).
  Plain Markdown, Git-backed history and the single-writer model are deliberate
  constraints, not missing features.
- Keep discussions respectful, constructive and focused on the work.
- For vulnerabilities, follow [SECURITY.md](SECURITY.md) rather than opening a
  public issue.

## Development setup

Install Git, Bash, and the Elixir/Erlang versions in
[`.tool-versions`](.tool-versions), then work from your fork or a local clone:

```bash
git clone https://github.com/64x-lunicorn/vigil.git
cd vigil
git switch -c your-change
mix deps.get
mix test
```

For a running server, use the [isolated local demo](README.md#quickstart).
Never point development commands at a production vault or production OAuth
state.

## Checks

Run the smallest tests that cover your change while developing:

```bash
mix test test/vigil/parser_test.exs test/vigil/index_test.exs
```

Before submitting an Elixir change, format the files you touched and run the
suite:

```bash
mix format path/to/changed_file.ex
mix test
```

Check formatting on changed Elixir files with
`mix format --check-formatted path/to/changed_file.ex`.
Replace the example paths with the actual files in your change.

Before pushing, run the whole gate in one command:

```bash
mix ci
```

This is exactly what CI runs, in the same order: unused lock entries,
formatting, compilation with warnings as errors, Credo, the dependency audits,
the test suite and Dialyzer. The first Dialyzer run builds a PLT and takes a
few minutes; later runs reuse it from `priv/plts/`.

Tests run in `MIX_ENV=test`; do not run them with `MIX_ENV=prod` or source
production environment files first. Test configuration pins the vault path,
the OAuth state path, the authorization server's issuer, resource and
consent password, and the SkillKey secret independently of deployment environment variables.

For changes to the deployment scripts, also run ShellCheck and the existing
shell tests:

```bash
shellcheck -x scripts/*.sh scripts/test/*.sh
bash scripts/test/check_only_test.sh
bash scripts/test/update_test.sh
bash scripts/test/verify_test.sh
bash scripts/test/secrets_test.sh
bash scripts/test/git_settings_test.sh
bash scripts/test/push_safety_net_test.sh
bash scripts/test/conventions_skill_test.sh
bash scripts/test/grants_test.sh
bash scripts/test/obsidian_templates_test.sh
node scripts/test/slug_js_test.mjs
bash scripts/test/operator_secrets_test.sh
```

CI pins ShellCheck to the version named in
[`ci.yml`](.github/workflows/ci.yml) and verifies its checksum. If your local
ShellCheck is older it may report findings that version no longer emits, and
miss ones it does — match it when a local run and CI disagree.

`verify_test.sh` drives each of `verify()`'s twelve checks against both
outcomes, with `systemctl`, `journalctl`, `curl`, `mcp_call` and `as_vigil`
replaced by stand-ins and the installation layout pointed at a temp directory.
Every check's own logic — its conditions, its verdict, its exit code — is the
real one.

`update_test.sh` drives `update.sh` against a throwaway prefix: the
switchover, the automatic rollback when `verify()` goes red, `--rollback`, the
refusals that must leave the running service alone (among them an env file
without `VIGIL_SKILLKEY_SECRET`), and the release retention
rule. It needs no root, no systemd and no production paths.

`secrets_test.sh` checks the secrets `init.sh` writes: that what it generates
passes the boot check's floor for the SkillKey secret, and that the consent
password and the SkillKey secret are generated apart and both written.

`git_settings_test.sh` checks that the scripts read the vault's remote and
branch from the env file — against a real repository on `master` — and that no
script or deploy file names `github` or `main` as either again.

`push_safety_net_test.sh` drives `push_pending.sh` against real repositories —
the lock directory it refuses, a refusing pre-push hook that must not run, an
ssh that never answers, a remote that is gone, commits older than the alert —
and `install_push_timer` against a throwaway systemd directory, with
`systemctl` and `systemd-analyze` as stand-ins on `PATH`.

`grants_test.sh` drives `grants.sh`, the operator's command for listing and
revoking grants, against a fake release that records what it is asked to
evaluate: the arguments it accepts, the confirmation before revoking
everything, that an id reaches the node as data, and the exit codes. It also
holds `init.sh --keep-token` to minting no long-lived token.

`operator_secrets_test.sh` holds the scripts to exposing no secret: a `curl`
on `PATH` records every argument `verify()` gives it and none is a token or a
SkillKey (and a real curl, against a listener on loopback, sends what was
handed to it on stdin); `verify()`, `update.sh --rollback` and
`rotate_secret.sh` under `--verbose` trace none; an answer with a quote, a
`$(…)` or a backtick comes back from the env file and through `as_vigil` (a
`runuser` stand-in on `PATH`) as that value; and `rotate_secret.sh` replaces
one line, keeps every other, restarts the service and names
`grants.sh revoke-all`.

Those two and `release_smoke.sh` source
[`scripts/test/harness.sh`](scripts/test/harness.sh) for the counting and the
reporting — `pass`, `fail`, `assert_eq`, `section`, and the `report` a suite
ends on, which is what decides its exit code. `check_only_test.sh` is the
exception: its `assert_eq` and `assert_contains` carry a message shape of
their own. A new suite sources the harness.

`obsidian_templates_test.sh` runs `init_vault.sh` against a temp directory:
that a new vault gets the Obsidian templates committed, and that a vault's own
copies are kept. `slug_js_test.mjs` is plain Node without dependencies: it
checks the JavaScript slug in the Templater user script against
`test/fixtures/slug_examples.json`, the table `mix test` checks `Vigil.Slug`
against. Change one slug and the table, and both have to follow.

For changes to `mix.exs`, `config/`, the release or anything on the boot path,
run the release smoke test. It builds a production release, boots it against a
throwaway git-backed vault and exercises the read path, scope enforcement, the
write-commit-push path and shutdown:

```bash
bash scripts/test/release_smoke.sh
```

If your change touches the MCP tool table (`Vigil.MCP.Tools`) or the OAuth
metadata (`Vigil.OAuth`), the recorded contracts under
`test/fixtures/contracts/` will no longer match and the suite will say so.
These files are what already-connected clients see, so a change to one is a
change to a published interface. Read the diff the failure prints; if it is
what you meant, record it and commit the updated file with the change:

```bash
UPDATE_CONTRACTS=1 mix test test/vigil/contracts_test.exs
```

These checks use throwaway fixture vaults and do not require root or a
production installation. Do not run the root-level deployment workflow just
to validate a contribution.

Documentation-only changes do not need an application build or test run.
Verify links, examples and documented behavior instead.

The pipeline itself is described in [docs/ci-cd.md](docs/ci-cd.md).

## Writing a useful issue

Include:

- The version or commit, operating system, and Elixir/Erlang versions.
- What you expected, what happened, and minimal steps to reproduce.
- Relevant error messages and a small synthetic vault example when needed.

Redact passwords, access tokens, private repository URLs, personal notes and
OAuth state. Do not upload a real vault or an environment file.

## Submitting a pull request

1. Keep the change focused and avoid unrelated formatting or refactors.
2. Explain the problem and solution, and link the relevant issue.
3. Add regression tests for behavior changes and update the affected docs.
4. List the checks you ran and any known limitations.
5. Preserve copyright and license notices. If dependencies or copied assets
   change, update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and retain
   the upstream license terms.

Only contribute material you have the right to submit. Contributions to
vigil's own code and documentation are made under the existing
[MIT License](LICENSE); third-party material retains its applicable license.
