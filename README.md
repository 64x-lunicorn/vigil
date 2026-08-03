# vigil

Elixir-Server, der einen Markdown-Vault liest, wie spät es ist weiß, und über MCP
als Gedächtnis-Backend für Claude dient. Siehe [`vigil-spec.md`](vigil-spec.md)
für die vollständige Spezifikation und [`vigil-oauth-spec.md`](vigil-oauth-spec.md)
für die OAuth-2.1-Erweiterung (v1.1).

## Entwicklung

```bash
mix deps.get
mix test
```

Für einen lokalen Testlauf gegen einen frischen Vault:

```bash
./scripts/init_vault.sh /tmp/mein-vault
cd /tmp/mein-vault && git remote add origin <gitea-url> && git push -u origin main
cd -

VIGIL_VAULT_PATH=/tmp/mein-vault \
VIGIL_ISSUER=http://localhost:4000 \
VIGIL_RESOURCE=http://localhost:4000/mcp \
VIGIL_AUTH_PASSWORD=ein-langes-lokales-testpasswort \
VIGIL_STATE_DIR=/tmp/mein-vault-oauth \
VIGIL_PORT=4000 \
mix run --no-halt
```

## Konfiguration

Alle Werte über Environment-Variablen (siehe `config/runtime.exs`):

| Variable | Default | Zweck |
|---|---|---|
| `VIGIL_VAULT_PATH` | `test/fixtures/vault` | Pfad zum Git-Clone des Vaults |
| `VIGIL_PORT` | `4000` | HTTP-Port |
| `VIGIL_GIT_REMOTE` | `origin` | Remote-Name für Push |
| `VIGIL_TZ` | `Europe/Berlin` | Zeitzone für `current`, Envelope, relative Zeiten |
| `VIGIL_EXCLUDE` | leer | Kommagetrennte Ordnernamen, die nie geparst werden |
| `VIGIL_ISSUER` | `http://localhost:4000` | OAuth-Issuer, z. B. `https://vault.factory-lab.org` |
| `VIGIL_RESOURCE` | `http://localhost:4000/mcp` | Kanonische URI des MCP-Endpunkts (Audience) |
| `VIGIL_AUTH_PASSWORD` | — | Consent-Passwort, **Pflicht, min. 12 Zeichen** — Start bricht sonst ab |
| `VIGIL_STATE_DIR` | `tmp/oauth_state` | Verzeichnis für die drei `:dets`-Dateien (Clients/Codes/Tokens) |

`vigil` ist sein eigener OAuth-2.1-Autorisierungsserver (siehe `vigil-oauth-spec.md`).
Es gibt keinen statischen Bearer-Token mehr — jeder Client (claude.ai, Claude Code,
Claude iOS) authentifiziert sich über den Standard-OAuth-Flow mit PKCE, entweder per
Dynamic Client Registration oder per Client-ID-Metadata-Document.

## Release & Deployment

```bash
MIX_ENV=prod mix release
```

Das Release nach `/opt/vigil` auf den Ziel-LXC kopieren, `deploy/vigil.env.example`
nach `/etc/vigil/vigil.env` kopieren und ausfüllen, dann:

```bash
sudo cp deploy/vigil.service /etc/systemd/system/vigil.service
sudo systemctl daemon-reload
sudo systemctl enable --now vigil
```

Cloudflare Tunnel läuft als zweite systemd-Unit (`deploy/cloudflared.service`)
und leitet `vault.<domain>` auf `localhost:4000`.

Deploy-Trigger ist bewusst manuell: Git-Tag im Code-Repo → CI baut Release →
SSH-Copy in den LXC → `systemctl restart vigil`. Kein Auto-Pull bei jedem Commit.

`write_and_commit` pusht bei jedem Write selbst und meldet einen Fehler an den
Client, wenn der Push scheitert. `deploy/vigil-push-safety-net.cron` ist ein
zusätzliches Sicherheitsnetz für das Zeitfenster, in dem ein Push zur
Schreibzeit scheiterte — kein Ersatz für den Push im Write-Pfad. Installation
z. B. via `crontab -u vigil -e` oder als `/etc/cron.d/vigil-push-safety-net`.

`VIGIL_STATE_DIR` muss zwischen Deploys erhalten bleiben (z. B. `/var/lib/vigil`,
außerhalb des Release-Verzeichnisses) — sonst verliert Daniel bei jedem Deploy
alle Access- und Refresh-Tokens und muss jeden Client neu autorisieren.

## Architektur

```
lib/vigil/
├── application.ex   # Supervisor: Store, Envelope, OAuth.Store, OAuth.Janitor, MCP.Server
├── store.ex          # GenServer — ETS-Chunks/Links/Files, Suche, Writes
├── parser.ex         # Datei → Frontmatter + Chunks + Links
├── search.ex          # reine Ranking-Funktionen
├── git.ex             # System.cmd-Wrapper: add/commit/push/log
├── time_fmt.ex        # relative Zeitformatierung
├── uuid.ex            # UUIDv4 (Sessions, DCR-Client-IDs)
├── oauth/
│   ├── store.ex       # :dets (Clients/Codes/Tokens) + ETS (Rate-Limit, CIMD-Cache)
│   ├── janitor.ex      # periodisches Aufräumen abgelaufener Einträge
│   ├── client.ex        # Client-Auflösung: DCR (dets) oder CIMD (HTTPS-Fetch)
│   ├── cimd.ex           # Client-ID-Metadata-Document-Fetch mit SSRF-Schutz
│   ├── redirect_uri.ex   # Redirect-URI-Validierung/-Matching
│   ├── token.ex           # Zufalls-Token + PKCE-Prüfung
│   └── consent_page.ex    # Inline-EEx-Consent-Seite
└── mcp/
    ├── server.ex      # Bandit + Plug: MCP-JSON-RPC + OAuth-Endpunkte
    ├── tools.ex        # Tool-Definitionen + Dispatch
    └── envelope.ex     # Zeit-Envelope, Session-Delta-Tracking
```
