# Documentation

| Document | What it is |
|---|---|
| [Project overview](../README.md) | **Start here.** What vigil is, why it exists and a local quickstart. |
| [User guide](guide.md) | Vault structure, the full tool reference, configuration, deployment, operations and troubleshooting. |
| [Connecting clients](clients.md) | Claude.ai, Claude Desktop, Claude Code, ChatGPT and Cursor: the steps, OAuth or a seeded token, and the Cloudflare Access policy each needs. Drafts until tested. |
| [design.md](design.md) | Why it is built this way: principles, the vault model, chunking, search, the link index, the write path, deliberate non-goals and known trade-offs. |
| [oauth.md](oauth.md) | The OAuth 2.1 implementation: endpoints, discovery documents, registration, redirect-URI matching, token handling, storage. |
| [history.md](history.md) | What was built in each round and why, including the bugs found along the way. |
| [compatibility.md](compatibility.md) | What vigil keeps stable from 1.0: what counts as a major, minor or patch change to the tools, `initialize`, OAuth, settings, state, vault conventions and scripts, and the deprecation policy. |
| [Changelog](../CHANGELOG.md) | Every release's changes, with an "Upgrading" note for operators. |
| [ci-cd.md](ci-cd.md) | The pipeline: how to ship a version, what guards `main` and a release, and how the project is hardened against mistakes. |
| [Contributing](../CONTRIBUTING.md) | Development setup, checks and contribution guidelines. |
| [Security policy](../SECURITY.md) | Private vulnerability reporting, supported versions, response targets and deployment precautions. |
| [Code of Conduct](../CODE_OF_CONDUCT.md) | The Contributor Covenant, and whom to contact. |
| [Governance](../GOVERNANCE.md) | The single-maintainer model and what continuity there is. |
| [Third-party notices](../THIRD_PARTY_NOTICES.md) | Dependency licenses and attribution for bundled development skills. |

For the writing conventions handed to the assistant itself, see
[`scripts/templates/vigil-vault-conventions.md`](../scripts/templates/vigil-vault-conventions.md)
— that file is installed into the vault as a skill by `init.sh`.

The code is the authority for behaviour. Where a document and the code
disagree, the code is right and the document is a bug.
