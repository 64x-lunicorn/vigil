<!--
CI runs formatting, warnings-as-errors, tests, Credo, Dialyzer, ShellCheck,
the dependency audits, a secret scan and a full production-release smoke test.
Run `mix ci` before pushing to get the same answer in a couple of minutes
instead of after a round trip.
-->

## What and why

<!-- The problem, and why this is the right fix. Link the issue: Fixes #123 -->

## Checks

<!-- Delete what does not apply; say so if something could not be run. -->

- [ ] `mix ci` passes locally
- [ ] `bash scripts/test/check_only_test.sh` (deployment script changes)
- [ ] `bash scripts/test/release_smoke.sh` (release, config or boot-path changes)
- [ ] Regression test added for the changed behaviour
- [ ] Affected documentation updated
- [ ] [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) updated (dependency changes)

## Deployment impact

<!--
Anything the operator must know before `sudo ./scripts/update.sh --to <ref>`:
new or renamed environment variables, a changed systemd unit (needs
`--update-unit`), a vault migration, a changed OAuth surface.
Write "none" if there is none — that is useful information too.
-->

## Notes for the reviewer

<!-- Known limitations, deliberate trade-offs, what you are unsure about. -->

<!--
Please use synthetic vault data in examples and tests — never personal notes,
real tokens or a production environment file.
-->
