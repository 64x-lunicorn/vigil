# Security policy

vigil handles private notes, Git credentials and OAuth tokens. Please keep
security reports confidential until a fix or mitigation can be coordinated.

## Reporting a vulnerability

Use GitHub's **[Report a vulnerability](https://github.com/64x-lunicorn/vigil/security/advisories/new)**
form for a private report to the repository maintainers.

**Do not disclose vulnerabilities in public issues or pull requests.**
If you cannot access the private form, open a public issue asking only for a
private contact channel. Do not include vulnerability details there.

Include in the private report:

- The affected version or commit and deployment configuration.
- A description of the impact and prerequisites.
- Minimal reproduction steps using synthetic data.
- A proposed mitigation or fix, if available.

Never include real passwords, access tokens, SSH private keys, personal notes,
or copies of OAuth state. Do not test against someone else's deployment
without permission.

## Maintenance scope

vigil is an early-stage, single-user project. Fixes are developed against the
current `main` branch; there is no published long-term-support or older-release
backport policy. This project does not offer a guaranteed security response
time.

## Deployment precautions

- Use HTTPS and the documented Cloudflare Access setup for internet-facing
  deployments. Do not expose the application port directly.
- Set a unique, strong `VIGIL_AUTH_PASSWORD`. The application requires at least
  12 characters; this password also supplies the SkillKey HMAC secret.
- Prefer the `vault:read` scope unless a client genuinely needs write access.
- Treat the SkillKey as a writing-conventions check, **not** an authorization
  boundary. OAuth scopes control access.
- Restrict permissions on the vault, environment files, SSH credentials and
  OAuth state directory. Seeded tokens are secrets too.
- Keep the vault remote private and use a repository-scoped deploy key where
  possible.
- Maintain independent backups. A Git remote is not a substitute for a backup
  strategy, and failed pushes can leave changes committed only locally.
- Keep dependencies and the host runtime updated, and review changes before
  deploying them.

See the [security model](docs/guide.md#security-model),
[configuration reference](docs/guide.md#configuration), and
[OAuth implementation notes](docs/oauth.md) for details.
