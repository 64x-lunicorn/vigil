# CI/CD

How a change gets from a branch to the vault host, and what has to be true at
each step.

The pipeline is built around one idea: **the checks that guard `main` and the
checks that guard a release are the same checks.** `release.yml` calls
`ci.yml`, so "green on main" and "safe to deploy" are one statement, not two
hopeful ones.

## The short version

| I want to... | Do this |
| :--- | :--- |
| Know if my change passes | `mix ci` |
| Ship a version | `git tag vX.Y.Z && git push origin vX.Y.Z` |
| Deploy it | `sudo ./scripts/update.sh --to vX.Y.Z` on the vault host |
| Undo a bad deploy | `sudo ./scripts/update.sh --rollback` |

## Shipping

Shipping is a tag. Nothing else.

```bash
# 1. Bump the version in mix.exs, commit, merge to main.
# 2. Tag the merged commit and push the tag.
git tag v0.2.0
git push origin v0.2.0
```

The tag triggers [`release.yml`](../.github/workflows/release.yml), which:

1. runs the **entire CI gate against the tagged commit** — not against
   whatever was green on `main` last week;
2. refuses to continue if the tag disagrees with the version in `mix.exs`,
   because a release that misreports its own version makes every later
   "which version is running?" answer worthless;
3. builds a `MIX_ENV=prod` release, packages it, and re-extracts the tarball to
   confirm the archive is complete and its ERTS actually runs;
4. attaches the tarball, a `SHA256SUMS` file and the exact `mix.lock` it was
   built from;
5. records a signed **build-provenance attestation** (verifiable with
   `gh attestation verify`), so the artifact can be traced to this workflow,
   this repository and this commit;
6. publishes the GitHub Release. A tag with a suffix (`v0.2.0-rc.1`) is marked
   as a pre-release, so `update.sh` never picks it up by accident.

### Deploying

Deployment stays a deliberate command on the vault host:

```bash
sudo ./scripts/update.sh --to v0.2.0
```

[`update.sh`](../scripts/update.sh) does its own preflight (unpushed vault
commits, disk space, ownership), aborts on HIGH/CRITICAL advisories, runs the
tests, builds into a new release directory, switches the symlink, and runs
`verify()` — **rolling back automatically** if acceptance fails. The previously
running release stays on disk for `--rollback`.

> [!NOTE]
> CI deliberately has no SSH key and no root on the vault host. Automating that
> last step would mean a compromised workflow is a compromised vault, and it
> would replace a one-line command with an attack surface. The prebuilt tarball
> exists for hosts without a build toolchain; the source path via `update.sh`
> remains the supported route.

## Keeping `main` and releases correct

### The gate

[`ci.yml`](../.github/workflows/ci.yml) runs on every pull request, every push
to `main`, every merge-queue entry, and (through `workflow_call`) every
release.

| Job | What it proves |
| :--- | :--- |
| **Test** | Locked deps resolve, no unused lock entries, formatting is clean, the project compiles with **warnings as errors**, the suite passes, no retired or vulnerable dependencies. |
| **Static analysis** | Credo finds no issues; Dialyzer finds no new type errors. |
| **Deployment scripts** | ShellCheck is clean, and `init.sh --check-only` is still strictly read-only. |
| **Release smoke test** | A real production release boots and serves. See below. |
| **Workflow lint** | actionlint and zizmor: the pipeline's own configuration is checked like code. |
| **Secret scan** | gitleaks over the full history, not just the diff. |
| **CI gate** | Aggregates all of the above into one status check. |

### Required status checks

Protect `main` with a ruleset requiring exactly one check: **`CI gate`**.

Because `gate` depends on every other job and fails when any of them is
anything other than `success`, adding or renaming a job never means editing
branch protection again — and a job that was skipped or cancelled cannot slip
through as green.

Recommended ruleset for `main`:

- Require a pull request before merging, with at least one approval
- Require review from Code Owners ([`CODEOWNERS`](../.github/CODEOWNERS))
- Require status checks to pass: **`CI gate`**
- Require branches to be up to date before merging
- Block force pushes and deletions
- Require conversation resolution

Enable **secret scanning with push protection** in the repository's security
settings as well. gitleaks in CI catches a leaked credential after it is
pushed; push protection catches it before.

### The same gate, locally

```bash
mix ci
```

runs the identical Elixir checks in the same order as CI. For the parts that
need a shell and a running server:

```bash
shellcheck -x scripts/*.sh scripts/test/*.sh
bash scripts/test/check_only_test.sh
bash scripts/test/release_smoke.sh
```

A check that only exists in CI is a check contributors discover too late.

## How the project is hardened against mistakes

Each layer catches a class of failure the layer above it structurally cannot
see.

**Compile time.** `mix compile --warnings-as-errors --force`. `--force`
matters: with a warm build cache an incremental compile skips unchanged files
and never re-emits their warnings, so warnings-as-errors quietly stops
enforcing anything.

**Type level.** Dialyzer with `error_handling`, `extra_return`,
`missing_return` and `unknown`. Findings that are known and understood live in
[`.dialyzer_ignore.exs`](../.dialyzer_ignore.exs) **with a written reason**,
and `list_unused_filters` fails the build when an entry there goes stale, so
the ignore list cannot rot into a dumping ground.

**Code level.** Credo, configured in [`.credo.exs`](../.credo.exs) as a
*ratchet*: complexity and nesting limits are pinned to the worst value in the
codebase today, so existing code passes but nothing is allowed to get worse.
Purely stylistic checks are off — a gate nobody can make green on day one gets
bypassed rather than respected.

**Behaviour.** `mix test`, in `MIX_ENV=test` against the fixture vault.

**Boot and runtime.**
[`scripts/test/release_smoke.sh`](../scripts/test/release_smoke.sh) is the
layer that catches what the suite is blind to. `mix test` never boots an OTP
release, so it cannot see a broken `runtime.exs`, a missing application in the
release, a config value only read at startup, or a filename-encoding failure
under the host locale. The smoke test builds a production release, boots it
against a throwaway git-backed vault with its own bare remote, and drives it
over HTTP:

- unauthenticated calls are rejected with 401
- a `vault:read` token is *authenticated* and still refused by a write tool
  (a 401 there would prove nothing about scope enforcement)
- a note whose **filename** contains non-ASCII characters can be read — the
  regression that produced the `LANG=C.UTF-8` lines in
  [`vigil.service`](../deploy/vigil.service)
- a write is committed **and pushed to the git remote**, verified against the
  bare repository rather than the server's own claim
- `reload` reports no `pull_failed`
- the release shuts down on SIGTERM, which is what `systemctl stop` sends

**Shell.** The deployment scripts run as root on the vault host, so a bug there
is an incident, not a lint warning. ShellCheck is blocking, and
`check_only_test.sh` guards the specific regression where `--check-only`
silently fell through to apply-mode.

**Supply chain.** `mix hex.audit` (retired packages) and `mix deps.audit`
(published CVEs) run in CI. Every third-party action is pinned to a **commit
SHA**, not a tag; gitleaks binaries are downloaded and **checksum-verified**
rather than pulled in as another action with repository access. Workflows
declare `permissions: {}` by default and grant the minimum per job, and
`persist-credentials: false` keeps the workflow token out of `.git/config`
where later steps could read it.

**Time.** [`audit.yml`](../.github/workflows/audit.yml) re-runs the dependency
audit nightly and **files an issue** when it turns red. Nothing in the
repository has to change for `main` to become vulnerable: a CVE published today
does that on its own, and a scheduled workflow failing quietly in the Actions
tab is indistinguishable from nobody looking.

**Dependencies.** [`dependabot.yml`](../.github/dependabot.yml) opens pull
requests for Hex and GitHub Actions, which means updates go through the same
gate as everything else — including the release smoke test. Without it, the
SHA-pinned actions would rot.

## Maintenance

**Elixir/OTP versions.** CI reads [`.tool-versions`](../.tool-versions) via
`erlef/setup-beam`, so there is one source of truth for contributors, CI and
the server. Bumping the file bumps CI. The advisory `next` matrix leg tests the
following Elixir/OTP pair and is allowed to fail: it is an early warning, not a
reason to block an unrelated bugfix.

**Pinned tool versions.** `actionlint`, `zizmor` and `gitleaks` are pinned by
version in the workflow `env:` blocks. When bumping gitleaks, update
`GITLEAKS_SHA256` from the release's `checksums.txt` in the same commit.

**Loosening a ratchet.** Lower a `.credo.exs` threshold whenever a refactor
makes room for it; remove a `.dialyzer_ignore.exs` entry when the finding is
fixed — CI will tell you if you forget, because the filter becomes unused.
