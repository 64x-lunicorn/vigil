# Third-party notices

vigil's own source code is distributed under the [MIT License](LICENSE),
with its existing copyright notice:

> Copyright (c) 2026 Lunicorn-lab

Third-party software and documentation retain their original copyrights and
license terms. The project license does not relicense those components.

## Bundled development skills

The development skills in [`.agents/skills/`](.agents/skills/) originate from
[mattpocock/skills](https://github.com/mattpocock/skills), by Matt Pocock, under
the MIT License. The repository also contains agent guidance adapted from that
collection in [`docs/agents/`](docs/agents/).

- **Copyright:** Copyright (c) 2026 Matt Pocock
- **License text:** [`.agents/skills/LICENSE`](.agents/skills/LICENSE)
- **Upstream license:** <https://github.com/mattpocock/skills/blob/main/LICENSE>
- **Installed-source manifest:** [`skills-lock.json`](skills-lock.json)

These skills are development aids, not runtime dependencies of the vigil
server. Keep their license notice with any copies or substantial portions.
The manifest records source paths and content hashes, not upstream Git commit
identifiers.

## Locked Elixir/Erlang dependencies

This inventory reflects [`mix.lock`](mix.lock). Versions and declared licenses
were checked against the locally installed Hex packages' metadata on
2026-09-09. Optional dependencies absent from the lockfile are not included.

### Runtime dependencies

These are compiled into a production release and are the ones that matter when
you redistribute a build.

| Package | Locked version | Declared license |
| :--- | :--- | :--- |
| [bandit](https://hex.pm/packages/bandit/1.12.5) | 1.12.5 | MIT |
| [hpax](https://hex.pm/packages/hpax/1.0.4) | 1.0.4 | Apache-2.0 |
| [jason](https://hex.pm/packages/jason/1.4.5) | 1.4.5 | Apache-2.0 |
| [mime](https://hex.pm/packages/mime/2.0.7) | 2.0.7 | Apache-2.0 |
| [plug](https://hex.pm/packages/plug/1.20.3) | 1.20.3 | Apache-2.0 |
| [plug_crypto](https://hex.pm/packages/plug_crypto/2.2.0) | 2.2.0 | Apache-2.0 |
| [telemetry](https://hex.pm/packages/telemetry/1.4.2) | 1.4.2 | Apache-2.0 |
| [thousand_island](https://hex.pm/packages/thousand_island/1.5.0) | 1.5.0 | MIT |
| [tz](https://hex.pm/packages/tz/0.28.2) | 0.28.2 | Apache-2.0 |
| [websock](https://hex.pm/packages/websock/0.5.3) | 0.5.3 | MIT |
| [yamerl](https://hex.pm/packages/yamerl/0.10.0) | 0.10.0 | BSD-2-Clause |
| [yaml_elixir](https://hex.pm/packages/yaml_elixir/2.12.2) | 2.12.2 | MIT |

Hex lists yamerl's license as `BSD 2-Clause`; the table uses the SPDX identifier
`BSD-2-Clause` for the same license.

### Development and CI dependencies

Declared `only: [:dev, :test], runtime: false` in [`mix.exs`](mix.exs). They run
the quality gate (formatting, static analysis, dependency auditing) and are
**not** part of a `MIX_ENV=prod` release, so they are outside the scope of the
redistribution note below.

| Package | Locked version | Declared license |
| :--- | :--- | :--- |
| [bunt](https://hex.pm/packages/bunt/1.0.0) | 1.0.0 | MIT |
| [credo](https://hex.pm/packages/credo/1.7.19) | 1.7.19 | MIT |
| [dialyxir](https://hex.pm/packages/dialyxir/1.4.8) | 1.4.8 | Apache-2.0 |
| [erlex](https://hex.pm/packages/erlex/0.2.9) | 0.2.9 | Apache-2.0 |
| [file_system](https://hex.pm/packages/file_system/1.1.1) | 1.1.1 | Apache-2.0 |
| [mix_audit](https://hex.pm/packages/mix_audit/2.1.5) | 2.1.5 | BSD-3-Clause |

Dependencies are fetched by Mix and are not vendored into the source
repository. This table is an attribution inventory, not a replacement for
their license texts.

## Redistributing a build

If you distribute a release, container image or other bundle that includes
dependencies, include their applicable license texts, copyright notices and
any required upstream `NOTICE` files. Preserve the Apache-2.0 terms for
Apache-licensed components rather than presenting an entire bundle as
MIT-only. Check the actual artifacts you ship, including the Elixir/Erlang
runtime and any operating-system packages; those are outside the Hex inventory
above.

Update this inventory when the lockfile or bundled third-party material
changes. Your own vault content is separate from this software and is not
relicensed by using vigil.
