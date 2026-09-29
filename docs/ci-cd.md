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
| Ship a version | `git tag -s vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z` |
| Deploy it | `sudo ./scripts/update.sh --to vX.Y.Z` on the vault host |
| Undo a bad deploy | `sudo ./scripts/update.sh --rollback` |

## Shipping

Shipping is a tag. Nothing else.

```bash
# 1. Bump the version in mix.exs, rename "## [Unreleased]" in CHANGELOG.md to
#    the version and today's date, open a new empty "Unreleased" above it,
#    commit, merge to main.
# 2. Tag the merged commit with a signed tag and push it.
git tag -s v0.2.0 -m v0.2.0
git push origin v0.2.0
```

The tag must be signed: the tag ruleset below requires signatures on
`refs/tags/v*`, and it forbids moving or deleting a `v*` tag once it is
pushed. A tag that went out wrong is fixed with the next version, not by
re-tagging.

The tag triggers [`release.yml`](../.github/workflows/release.yml), which:

1. runs the **entire CI gate against the tagged commit** — not against
   whatever was green on `main` last week;
2. refuses to continue if the tag disagrees with the version in `mix.exs`,
   because a release that misreports its own version makes every later
   "which version is running?" answer worthless;
3. builds a `MIX_ENV=prod` release, writes its SBOM, packages it
   deterministically, and re-extracts the tarball to confirm the archive is
   complete and its ERTS actually runs;
4. records one signed **build-provenance attestation** for every file it is
   about to publish (verifiable with `gh attestation verify`), so each can be
   traced to this workflow, this repository and this commit;
5. publishes the GitHub Release with the assets below. A tag with a suffix
   (`v0.2.0-rc.1`) is marked as a pre-release, so `update.sh` never picks it
   up by accident.

### Release assets

| Asset | What it is |
| :--- | :--- |
| `<name>.tar.gz` | The OTP release for linux-x86_64, ERTS included, with `LICENSE` and `THIRD_PARTY_NOTICES.md` at its root. |
| `<name>-mix.lock` | The exact dependency set it was built from. |
| `<name>.cdx.json` | A CycloneDX 1.6 SBOM of what the tarball bundles. |
| `<name>-SHA256SUMS` | The checksums of the three above. |
| `<name>.intoto.jsonl` | The build-provenance attestation bundle; its subjects are all four files above. |

`<name>` is `vigil-<version>-otp<OTP version>-linux-x86_64`. Verify a
download with:

```bash
sha256sum -c <name>-SHA256SUMS
gh attestation verify <name>.tar.gz --repo 64x-lunicorn/vigil
gh attestation verify <name>.tar.gz --repo 64x-lunicorn/vigil --bundle <name>.intoto.jsonl
```

The attestation is kept in GitHub's attestation store as well; the bundle is
attached because only an asset is visible from the release itself, which is
where the OpenSSF Scorecard's Signed-Releases check looks.

**The SBOM** is written by the project's own task,
[`mix vigil.sbom`](../lib/mix/tasks/vigil.sbom.ex), run under
`MIX_ENV=prod`: one component per Hex package the release contains, with the
version and package checksum `mix.lock` pins and the licenses its Hex metadata
declares, plus the Erlang/OTP (with its ERTS version) and Elixir the release
bundles from the VM that built it, and the dependency graph between them. A
Hex SBOM generator would do the same with one more third-party package running
in the job that holds the signing permission; all it would read is `mix.lock`
and each dependency's `hex_metadata.config`, so the task reads those itself.

**The tarball** is packed by
[`scripts/package_release.sh`](../scripts/package_release.sh), the same script
[`package_release_test.sh`](../scripts/test/package_release_test.sh) runs in
CI: entries sorted by name, every entry stamped with `SOURCE_DATE_EPOCH` (the
commit time of the tagged commit), owner and group `0` without names, no
group- or world-writable modes, and `gzip -n` so the compressed stream records
neither a name nor a time. Packing the same release directory gives the same
bytes on any machine with GNU tar.

The tarball carries no `releases/COOKIE`. The cookie is Erlang distribution's
only credential, and one in a public file would be the same credential on
every host that installed it. A release without one writes its own — random,
`0400`, owned by whoever ran the command — the first time any `bin/vigil`
command runs ([`rel/env.sh.eex`](../rel/env.sh.eex)). Run that first command
as the service account after unpacking, before the unit starts the release:
its sandbox cannot write into the release, and `bin/vigil` refuses to write
the cookie as root.

```bash
sudo -u vigil /opt/vigil/releases/<name>/bin/vigil version
```

### Reproducibility

Two builds of one commit do not yet give the same tarball. The packing is
deterministic; one file of the release it packs is not:

| File | Why it differs between builds |
| :--- | :--- |
| `lib/tz-*/ebin/Elixir.Tz.PeriodsProvider.beam` | The `tz` dependency compiles its build time into the module (`compiled_at/0`). |

`mix release` also writes a new random `releases/COOKIE` for every build, but
the tarball leaves it out (below).

Everything else is byte for byte the same when the builds use the same
toolchain (`.tool-versions`) and the same checkout path — compiled modules
record where their source was, and the release workflow always builds in the
same directory. [`scripts/test/reproducible_release.sh`](../scripts/test/reproducible_release.sh)
builds `HEAD` twice from a clean `_build` and passes when the two trees differ
in exactly this file, so a new source of difference fails it rather than
hiding behind the known one. It takes a few minutes and is not part of the
CI gate; run it after changing the release configuration or the packaging.

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
| **Test** | Locked deps resolve, no unused lock entries, formatting is clean, the project compiles with **warnings as errors**, the suite passes (including the recorded interface contracts), no retired or vulnerable dependencies. |
| **Static analysis** | Credo finds no issues; Dialyzer finds no new type errors. |
| **Security scan** | Sobelow finds nothing that was not triaged, and its SARIF goes to the repository's Security tab. See below. |
| **Deployment scripts** | ShellCheck is clean, `init.sh --check-only` is still strictly read-only, `update.sh` switches over, rolls back and prunes releases correctly, and each of `verify()`'s twelve checks decides both outcomes correctly. |
| **Contract changes** | A pull request or merge group that changes a recorded contract under `test/fixtures/contracts/` also changes `CHANGELOG.md` ([`check_changelog.sh`](../scripts/check_changelog.sh)). See below. |
| **Release smoke test** | A real production release boots and serves. See below. |
| **Workflow lint** | actionlint and zizmor, both verified before they run: the pipeline's own configuration is checked like code. |
| **Secret scan** | gitleaks over the full history, not just the diff. |
| **CI gate** | Aggregates all of the above into one status check. |

### Required status checks

Protect `main` with a ruleset requiring exactly one check: **`CI gate`**.

Because `gate` depends on every other job and fails when any of them is
anything other than `success`, adding or renaming a job never means editing
branch protection again — and a job that was skipped or cancelled cannot slip
through as green.

### Recommended ruleset

vigil has one maintainer ([GOVERNANCE.md](../GOVERNANCE.md)), so the rules
follow the **Solo** model: a pull request is required but no approval, and
nobody can bypass the rules, so the CI gate binds the admin exactly as it
binds everyone else. One required approval with an admin bypass would
describe a review that never takes place: a sole maintainer cannot approve
their own pull request, so every merge would go through the bypass, and the
bypass skips the gate along with the approval.

Code-owner review is therefore **not enforced**.
[`CODEOWNERS`](../.github/CODEOWNERS) still requests the maintainer's review
on pull requests from anyone else, and becomes a requirement only once a second
maintainer exists (the **Two maintainers** model: one approval, code-owner
review, stale-review dismissal and approval of the last push).

> [!IMPORTANT]
> This is the **target** configuration. It is applied by the maintainer with
> the commands under [How to apply](#how-to-apply); until then the repository
> may still run the previous rules. After applying, replace these blocks with
> the export (`gh api repos/64x-lunicorn/vigil/rulesets/<id>`) if they
> differ.

**`main`** — the default-branch ruleset (`Master_Branch`, id `22632000`):

```json
{
  "name": "Master_Branch",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "required_reviewers": [],
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "require_extra_approval_for_unattributed_changes": false,
        "allowed_merge_methods": ["squash"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "CI gate", "integration_id": 15368 }
        ]
      }
    }
  ]
}
```

What it means:

- Every change reaches `main` through a pull request — for admins too, since
  `bypass_actors` is empty. A direct push is rejected.
- **`CI gate`** must pass, reported by GitHub Actions (integration id
  `15368`), so another app cannot post a green status of the same name.
- The branch must be up to date with `main` before merging, and every review
  conversation resolved.
- Squash merges only, which keeps the history linear and gives one commit per
  pull request; no force pushes, no deletion of `main`.
- No approval is required, for the reason above.

**Release tags** — a new ruleset for `refs/tags/v*`, since pushing a `v*` tag
cuts a release:

```json
{
  "name": "Release_Tags",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["refs/tags/v*"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "update" },
    { "type": "non_fast_forward" },
    { "type": "required_signatures" }
  ]
}
```

A `v*` tag can be created, but only signed, and once pushed it can be neither
moved nor deleted. A published release therefore always names the commit it
was built from.

### How to apply

Run these as the repository admin. The JSON above goes into two files,
`main-ruleset.json` and `tag-ruleset.json`.

```bash
# Replace the default-branch ruleset (PUT replaces rules and bypass actors).
gh api --method PUT repos/64x-lunicorn/vigil/rulesets/22632000 \
  --input main-ruleset.json

# Create the tag ruleset.
gh api --method POST repos/64x-lunicorn/vigil/rulesets \
  --input tag-ruleset.json

# Squash merges only; delete the branch on merge.
gh api --method PATCH repos/64x-lunicorn/vigil \
  -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F delete_branch_on_merge=true

# Secret scanning: non-provider patterns and validity checks.
gh api --method PATCH repos/64x-lunicorn/vigil --input - <<'JSON'
{
  "security_and_analysis": {
    "secret_scanning_non_provider_patterns": { "status": "enabled" },
    "secret_scanning_validity_checks": { "status": "enabled" }
  }
}
JSON

# Actions may only run actions pinned to a full commit SHA.
gh api --method PUT repos/64x-lunicorn/vigil/actions/permissions \
  -F enabled=true -f allowed_actions=all -F sha_pinning_required=true
```

The same settings as a checklist, for the web UI:

- [ ] **Rules → Rulesets → `Master_Branch`**: no bypass list; require a pull
      request with 0 approvals, squash as the only merge method, conversation
      resolution on; `CI gate` required from GitHub Actions, up to date before
      merging; linear history; block force pushes and deletions.
- [ ] **Rules → Rulesets → New tag ruleset `Release_Tags`**: target
      `refs/tags/v*`, no bypass list; restrict updates and deletions, block
      force pushes, require signed commits.
- [ ] **General → Pull Requests**: allow squash merging only; automatically
      delete head branches.
- [ ] **Advanced Security → Secret Protection**: secret scanning and push
      protection (already on), plus non-provider patterns and validity checks.
- [ ] **Actions → General**: require actions to be pinned to a full-length
      commit SHA.

Then confirm what the rules are for. First read back the rules that now
apply, then try what they forbid:

```bash
gh api repos/64x-lunicorn/vigil/rules/branches/main
gh api repos/64x-lunicorn/vigil/rulesets

# A direct push to main is rejected, for the admin too (on an up-to-date main).
git commit --allow-empty -m "ruleset check" && git push origin HEAD:main

# An unsigned v* tag is rejected.
git tag -a --no-sign v0.0.0-rulecheck -m check && git push origin v0.0.0-rulecheck
```

Both pushes must fail; delete the local commit and tag afterwards
(`git reset --hard HEAD~1`, `git tag -d v0.0.0-rulecheck`). Run them only
after the read-back shows the rules: a tag that got through could not be
deleted, and would start a release run that stops at the version check.

**gitleaks** in CI catches a leaked credential after it is pushed; secret
scanning's push protection catches it before, and the non-provider patterns
extend it to generic secrets such as private keys and connection strings that
no provider registers a pattern for.

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

**Security.** Sobelow, the security-focused static analyser for Elixir —
CodeQL, which fills the Security tab for most languages, has no Elixir support.
Everything it is told lives in [`.sobelow-conf`](../.sobelow-conf), so
`mix ci` and the **Security scan** job run the same scan: every finding at any
confidence fails it, no update check goes out over the network, and vigil being
a Plug application rather than Phoenix is stated (`router: :none`) instead of
warned about. The job uploads the scan as SARIF through
`github/codeql-action/upload-sarif`, so findings show up as code-scanning
alerts on the Security tab, and a fixed one closes there too.

Sobelow over-reports on purpose, so each finding is triaged, and a skipped one
carries its reason:

- a finding inside a function is skipped with a `# sobelow_skip [...]` comment
  directly above that function, and the comment above it says why. Most are
  `Traversal.FileModule` at the file layer: the paths there were either
  enumerated from the vault by vigil itself, come from the operator's
  configuration, or already passed `Vigil.Slug.safe_path/1`, the rule every
  client path crosses. The skip names one check, so any other finding in the
  same function still fails the gate.
- a finding in `config/` has no function to annotate, so it is an entry in
  [`.sobelow-skips`](../.sobelow-skips), with its reason in that file's header.
  Those entries are keyed by line: when the line moves the finding comes back
  and the gate fails, which is the prompt to check the reason still holds and
  re-mark it with `mix sobelow --mark-skip-all`. Only `Config.HTTPS` is left
  there, and it sits on line 0, which does not move.
- `config/test.exs` is left out of the scan (`ignore_files` in
  [`.sobelow-conf`](../.sobelow-conf)). It holds the suite's consent password
  and SkillKey secret, which key nothing outside the suite, and nothing else
  that Sobelow checks.

**Behaviour.** `mix test`, in `MIX_ENV=test` against the fixture vault.

**Published interfaces.** The MCP tool list, the `initialize` result, the
shape of every tool's result and the two OAuth metadata documents are recorded
under
[`test/fixtures/contracts/`](../test/fixtures/contracts/) and compared byte for
byte by
[`contracts_test.exs`](../test/vigil/contracts_test.exs). These documents are
contracts with software that is already connected, and a renamed parameter, a
reordered enum or a dropped field is a one-line change here and a broken client
out there. A test that asserts field by field cannot see it: such a test only
knows about the fields somebody thought to name in it. Recording a change is
deliberate — `UPDATE_CONTRACTS=1 mix test test/vigil/contracts_test.exs` — and
the diff in the pull request is the review of the interface change. The
"Contract changes" job then holds the pull request to naming it in
`CHANGELOG.md` ([`scripts/check_changelog.sh`](../scripts/check_changelog.sh),
diffing against the base with three dots; run it locally as
`bash scripts/check_changelog.sh origin/main`), and
[compatibility.md](compatibility.md) says whether it is a major, minor or
patch change.

**Notices.** `THIRD_PARTY_NOTICES.md` lists every locked Hex package at its
locked version, and
[`third_party_notices_test.exs`](../test/vigil/third_party_notices_test.exs)
fails the Test job when a dependency bump leaves it behind.

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

It also walks the authorization flow a real client walks, which no other check
does: every other token in the pipeline is seeded out of band through
`mix vigil.seed_token`, the path `verify()` and first access take. Dynamic
registration, the consent page, PKCE, the code exchange and refresh rotation
are well covered by the unit suite and were never run against a built release —
which is exactly where a value that only exists in `MIX_ENV=prod` goes wrong.
The flow is driven end to end, including that a wrong consent password mints no
code, that a code is one-time use, that the redirect carries the RFC 9207 `iss`
parameter the metadata advertises, and that replaying a spent refresh token
revokes the whole token family (RFC 9700 §4.14.2) — the defence rotation exists
for, and one that cannot be observed anywhere but end to end.

**Acceptance.** [`scripts/test/verify_test.sh`](../scripts/test/verify_test.sh)
covers `verify()`, which is what update.sh's automatic rollback hangs on. It was
one 210-line block that could only run against a real vault host — systemd,
journald, Cloudflare, a git remote and a booted release — so the one thing
nothing could test was the thing that decides whether a delivery stands. It is
twelve functions now, and each is driven against both outcomes: what stays real
is every check's own logic, and what is replaced is only what it reaches for
outside the process.

The split also took two GNU-only constructs out of `verify()` — `grep -oP` for
the chunk count and for the SkillKey — because a check that cannot run off the
vault host cannot be tested at all. Same argument as `df --output` and
`mapfile` before them.

**Shell.** The deployment scripts run as root on the vault host, so a bug there
is an incident, not a lint warning. ShellCheck is blocking, and
`check_only_test.sh` guards the specific regression where `--check-only`
silently fell through to apply-mode.

`verify_test.sh`, `update_test.sh` and `release_smoke.sh` share one assertion
harness, [`scripts/test/harness.sh`](../scripts/test/harness.sh). Each keeps
its own subjects and its own stand-ins; what it sources is the counting, the
headings and the summary — one statement of what a pass prints and what a
green run exits with, rather than three kept in step by hand. Each of the
three ends on `report`, which is what turns the counters into an exit code.
`check_only_test.sh` is the exception: its `assert_eq` and `assert_contains`
carry a message shape of their own.

**Delivery.** [`scripts/test/update_test.sh`](../scripts/test/update_test.sh)
covers the script that actually ships a change. The smoke test above proves a
release boots and serves; it says nothing about switching between two of them,
which is where the rollback lives — and a rollback path that has never been
executed is code whose first run is a production incident. The test drives the
real `update.sh` against a throwaway prefix
(`VIGIL_UPDATE_TEST_STUBS=1` stands in for root, the service account, systemd
and a booted release) and pins:

- a healthy release is switched to, and `.previous_release` records what it
  replaced
- a red `verify()` rolls back automatically, the service comes up on the old
  release, and the operator gets exit 3 rather than a silent failure; so does
  a new release that never comes up at all
- a rollback that is *also* red says manual intervention is needed (exit 1)
- `--rollback` returns to the recorded release, and refuses — rather than
  reporting success for a switch it did not make — when an automatic rollback
  has already left `current` and `.previous_release` naming the same release
- a red suite, unpushed vault commits and an env file without
  `VIGIL_SKILLKEY_SECRET` never reach the switchover, and leave the running
  service and the code checkout as they were
- the retention rule keeps the running release, the rollback target and one
  more — including when the prefix is reached through a symlink, which is the
  case that had the protection comparing resolved paths against unresolved
  ones and deleting the rollback target
- the running revision is read from the release, not the checkout, and the
  checkout is put back on it after a failed build, an automatic rollback and
  `--rollback` — so a failed update run again proceeds instead of reporting
  nothing to do
- `--rebuild` builds the running commit into a new release directory and
  switches to it

**Supply chain.** `mix hex.audit` (retired packages) and `mix deps.audit`
(published CVEs) run in CI. Every third-party action is pinned to a **commit
SHA**, not a tag. Every tool CI downloads is verified before it runs:
gitleaks, ShellCheck and actionlint are pinned by version and their release
tarball by **SHA-256**, rather than pulled in as another action with
repository access, and zizmor is installed with
`pip install --require-hashes --only-binary=:all:` from
[`.github/zizmor-requirements.txt`](../.github/zizmor-requirements.txt), which
pins its version and the digest of every one of its wheels. Workflows
declare `permissions: {}` by default and grant the minimum per job, and
`persist-credentials: false` keeps the workflow token out of `.git/config`
where later steps could read it.

**Time.** [`audit.yml`](../.github/workflows/audit.yml) re-runs the dependency
audit nightly and **files an issue** when it turns red. Nothing in the
repository has to change for `main` to become vulnerable: a CVE published today
does that on its own, and a scheduled workflow failing quietly in the Actions
tab is indistinguishable from nobody looking.

[`scorecard.yml`](../.github/workflows/scorecard.yml) runs the OpenSSF
Scorecard weekly and on every push to `main`: an outside reading of pinned
dependencies, token permissions, branch protection and static analysis. Its
SARIF goes to the Security tab, and its published result is the badge in the
README.

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

**Pinned tool versions.** `actionlint`, `gitleaks` and `ShellCheck` are pinned
by version in the workflow `env:` blocks, each beside the SHA-256 of its
release tarball. Bump both in the same commit: `ACTIONLINT_SHA256` from the
release's `actionlint_<version>_checksums.txt`, `GITLEAKS_SHA256` from its
`checksums.txt`, and `SHELLCHECK_SHA256` from `sha256sum` of the downloaded
tarball, which ShellCheck's releases do not publish. `zizmor` is pinned in
[`.github/zizmor-requirements.txt`](../.github/zizmor-requirements.txt):
replace the version and every `--hash` line together, from
`https://pypi.org/pypi/zizmor/<version>/json`. Sobelow is a Hex dependency
and moves with `mix.lock` like any other.

**Loosening a ratchet.** Lower a `.credo.exs` threshold whenever a refactor
makes room for it; remove a `.dialyzer_ignore.exs` entry when the finding is
fixed — CI will tell you if you forget, because the filter becomes unused.

**zizmor's severity floor is a ratchet too.** It runs at `--min-severity=low`
because the workflows are clean at low today. A threshold set above the current
state suppresses everything underneath it without saying so; the one finding
not worth acting on carries an inline `# zizmor: ignore[...]` with the reason
written beside it in `release.yml`. Because the version is pinned, new findings
arrive only with a deliberate bump — which is the moment to fix them or write
down why not.
