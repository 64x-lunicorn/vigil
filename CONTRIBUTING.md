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
mix test test/vigil/parser_test.exs test/vigil/search_test.exs
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
the OAuth state path and the authorization server's issuer, resource and
consent password independently of deployment environment variables.

For changes to the deployment scripts, also run ShellCheck and the existing
shell tests:

```bash
shellcheck -x scripts/*.sh scripts/test/*.sh
bash scripts/test/check_only_test.sh
```

For changes to `mix.exs`, `config/`, the release or anything on the boot path,
run the release smoke test. It builds a production release, boots it against a
throwaway git-backed vault and exercises the read path, scope enforcement, the
write-commit-push path and shutdown:

```bash
bash scripts/test/release_smoke.sh
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
