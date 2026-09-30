# Governance

vigil has one maintainer, [@64x-lunicorn](https://github.com/64x-lunicorn),
who decides what the project does, reviews and merges every change, cuts
releases and handles security reports. This file says how that works and what
happens if the maintainer is not there.

## How decisions are made

- Behaviour, vocabulary and design decisions are recorded in
  [docs/design.md](docs/design.md). A change that contradicts it changes it in
  the same pull request, with the reason.
- Larger changes start as an issue, so the question of *whether* is settled
  before the question of *how*. See [CONTRIBUTING.md](CONTRIBUTING.md).
- Every change reaches `main` through a pull request that passes the CI gate
  and is reviewed by the maintainer ([CODEOWNERS](.github/CODEOWNERS)).
- Releases are tags, published by [release.yml](.github/workflows/release.yml)
  only after the full gate passes against the tagged commit
  ([docs/ci-cd.md](docs/ci-cd.md)).
- Conduct is governed by the [Code of Conduct](CODE_OF_CONDUCT.md), security
  reports by the [security policy](SECURITY.md).

## Continuity

A project with one maintainer stops when that person does, and it is better
to say so than to imply otherwise:

- Today nobody else holds admin rights on the repository or can publish a
  release. If the maintainer is unavailable, issues and security reports wait,
  and the response targets in [SECURITY.md](SECURITY.md) cannot be kept.
- Everything needed to continue is public: the source, the design record, the
  CI and release workflows, and the scripts that deploy a vault host. Nothing
  the project depends on lives only with the maintainer, apart from access to
  the repository itself.
- vigil is MIT-licensed. Anyone may fork it and carry it on under another name.
- A vigil deployment does not depend on this repository at runtime: a running
  host keeps working, and its vault is a plain Git repository of Markdown
  files that is readable without vigil.
