# Security policy

vigil handles private notes, Git credentials and OAuth tokens. Please keep
security reports confidential until a fix or mitigation can be coordinated.

## Reporting a vulnerability

Use GitHub's **[Report a vulnerability](https://github.com/64x-lunicorn/vigil/security/advisories/new)**
form for a private report to the repository maintainers.

**Do not disclose vulnerabilities in public issues or pull requests.**
The issue forms route security reports to the private form as well.

If you cannot use the private form, write to the maintainer at
**[MAINTAINER CONTACT E-MAIL — to be added before publishing]**, or open a
public issue asking only for a private contact channel. Do not include
vulnerability details in a public issue.

Include in the private report:

- The affected version or commit and deployment configuration.
- A description of the impact and prerequisites.
- Minimal reproduction steps using synthetic data.
- A proposed mitigation or fix, if available.

Never include real passwords, access tokens, SSH private keys, personal notes,
or copies of OAuth state. Do not test against someone else's deployment
without permission.

## Supported versions

Security fixes go into `main` and ship in a new release of the latest minor
version. Older releases get no backports: update to the latest release with
`sudo ./scripts/update.sh --to <tag>`.

| Version | Supported |
| :--- | :--- |
| 0.2.x (latest release) | Yes |
| < 0.2 | No |
| Pre-releases (`-rc`) | No, superseded by the release that follows them |

## Response targets

vigil has a single maintainer (see [GOVERNANCE.md](GOVERNANCE.md)), so these
are targets a single person can keep, not a service-level agreement:

- **Initial response:** within **14 days** of the report, acknowledging it and
  saying whether more information is needed.
- **Assessment:** within 30 days, whether the report is accepted as a
  vulnerability and how severe it is.
- **Fix:** a release with a fix or a documented mitigation within **90 days**
  of the report for an accepted vulnerability, sooner for one that is severe
  or exploited. If a fix takes longer, the reporter hears why and when.

## How a report is handled

1. The report arrives as a private GitHub Security Advisory (GHSA) draft,
   visible only to the reporter and the maintainer.
2. The maintainer confirms the issue, agrees the severity (CVSS) with the
   reporter, and develops the fix in the advisory's temporary private fork,
   so nothing about it is public before the release.
3. A patched release is tagged. Its artifacts carry checksums, an SBOM and
   build-provenance attestations (see [docs/ci-cd.md](docs/ci-cd.md)).
4. The advisory is published with the affected and fixed versions. For a
   vulnerability that affects released versions, a CVE is requested through
   GitHub, which is a CVE Numbering Authority, from the advisory itself.
5. The reporter is credited in the advisory unless they prefer not to be.

Please give the maintainer the time above before disclosing a vulnerability
yourself; if a target is missed without word, you may disclose after telling
the maintainer when you will.

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
