# Connecting clients

[Back to vigil](../README.md) · [Documentation index](README.md) · [User guide](guide.md)

How to connect Claude.ai, Claude Desktop, Claude Code, ChatGPT and Cursor to a
vigil deployed as the [user guide](guide.md#deploy-on-a-server) describes, and
what Cloudflare Access has to let through for each of them.

> **Every client section below is a draft.** None of them has been tested end
> to end against a vigil deployment yet. Each is written from the vendor's
> documentation as it stood on 2026-09-29, and its status line says so. A
> section becomes a tested one when its status line names the date and the
> client version it was tested with — see
> [verifying a section](#verifying-a-section).

- [At a glance](#at-a-glance)
- [Cloudflare Access](#cloudflare-access)
- [Claude.ai](#claudeai)
- [Claude Desktop](#claude-desktop)
- [Claude Code](#claude-code)
- [ChatGPT](#chatgpt)
- [Cursor](#cursor)
- [Seeding a token for a header client](#seeding-a-token-for-a-header-client)
- [Verifying a section](#verifying-a-section)

---

## At a glance

| Client | Requests come from | Authentication | Behind the service-token policy `setup.sh` describes |
|---|---|---|---|
| [Claude.ai](#claudeai) | Anthropic's servers | OAuth | no — needs [the bypass](#the-bypass-for-cloud-connectors) |
| [Claude Desktop](#claude-desktop) | Anthropic's servers | OAuth | no — needs the bypass |
| [Claude Code](#claude-code) | your machine | OAuth, or a seeded token in a header | yes, with the service token and a seeded token |
| [ChatGPT](#chatgpt) | OpenAI's servers | OAuth | no — needs the bypass |
| [Cursor](#cursor) (desktop app) | your machine | OAuth, or a seeded token in a header | yes, with the service token and a seeded token |

The column that decides it is the second. A client that calls from its
vendor's servers cannot carry a Cloudflare service token, so it reaches vigil
only through paths Access lets anyone through. A client on your machine sends
whatever headers you configure.

Every client is given the same URL: **`VIGIL_RESOURCE`**, e.g.
`https://vault.example.org/mcp`. Claude's documentation says the `resource`
in the server's metadata must match the URL entered exactly, so enter it the
way `/etc/vigil/env` spells it.

The consent page grants the scope the client asks for. A client that follows
the scope in vigil's 401 challenge asks for `vault`, full access; `vault:read`
is for a client that asks for it, or for a seeded token (see
[OAuth: scopes](oauth.md#token-verification-at-mcp)).

---

## Cloudflare Access

### What the scripts set up

Nothing in Cloudflare Access. `setup.sh` creates the tunnel and its DNS
record, then prints instructions for Access as a manual step: one
self-hosted application for the tunnel's hostname, with a policy of type
**Service Auth** and a service token for the MCP client. Everything in this
section is manual.

What the scripts do is *check* for Access. `verify()` in
[`scripts/lib.sh`](../scripts/lib.sh), which `init.sh` runs at its end and
`update.sh` runs as the acceptance check after every update, sends a `GET`
without any credentials to `VIGIL_RESOURCE` and requires **403** — Cloudflare's
answer; vigil itself answers a GET on `/mcp` with 405. `init.sh
--allow-unprotected` skips that check. `update.sh` has no such switch, and a
failed acceptance check makes it [roll back](guide.md#operations).

### The service-token policy

One Access application for the whole hostname, one Service Auth policy, one
service token — what `setup.sh` describes and what the acceptance check
passes on. A request without the token's two headers never reaches vigil
([Cloudflare: service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)):

```
CF-Access-Client-Id: <client id>
CF-Access-Client-Secret: <client secret>
```

It lets through only a client that can send those headers — Claude Code and
Cursor, configured as their sections show — and shuts out every client that
calls from its vendor's servers. It shuts out OAuth's browser step too: the
browser that opens `/oauth/authorize` carries no service token. Under this
policy alone a client connects with a seeded token, not through the consent
page.

[An Access policy for the consent page](guide.md#an-access-policy-for-the-consent-page)
adds a second application for `/oauth/authorize` with an identity-provider
login and MFA. Where two applications match, the more specific path wins
([Cloudflare: application paths](https://developers.cloudflare.com/cloudflare-one/policies/access/app-paths/)),
so the consent page then answers a person while the rest of the host keeps the
service-token policy.

### The bypass for cloud connectors

Claude.ai, Claude Desktop and ChatGPT call from their vendor's servers: they
read the discovery documents, register, send the owner's browser to the
consent page and redeem the code, all without a Cloudflare header. They work
only when the paths they call are exempt from Access. On top of the two
applications above, add one whose destinations are the bypassed paths below,
with a policy whose action is **Bypass** and whose rule includes everyone:

| Path | Access | Why OAuth covers it |
|---|---|---|
| `/mcp` | Bypass | every request needs a bearer token vigil issued for this resource, unexpired and unrevoked; anything else is a 401 before a tool runs, and every token is rate limited |
| `/.well-known/*`, `/.well-known/oauth-protected-resource/mcp` | Bypass | the metadata documents: public by design, read-only, no secret in them. The second path is named on its own because a path wildcard covers one level |
| `/oauth/register` | Bypass | a registration is a public client with no secret and grants nothing until the owner consents; rate limited per address and bounded in size and count ([OAuth: client registration](oauth.md#client-registration)) |
| `/oauth/token` | Bypass | redeems only a code the consent page issued, with its PKCE verifier and the same redirect URI, or a refresh token vigil issued; rate limited per address |
| `/oauth/authorize` | Allow: identity provider **with MFA** | the one path a person uses — the consent password is typed here. The owner's own browser opens it, so an identity-provider login works where a service token cannot ([the consent page policy](guide.md#an-access-policy-for-the-consent-page)) |
| everything else | Service Auth, as before | nothing else is served (`/healthz` answers on the host only) |

Access can step aside on these paths because vigil does not trust the network
there to begin with: each one either needs a credential only the consent page
hands out, or hands out nothing. The consent page is the one place a person
proves who they are, and it keeps a person's policy. What the bypassed paths
lose is Access's own logging — a bypassed request "is not logged"
([Cloudflare: policy actions](https://developers.cloudflare.com/cloudflare-one/policies/access/));
vigil's rate limits and its journal remain.

A Bypass rule accepts non-identity selectors such as an IP range, so it can be
narrowed from everyone to the vendors' published egress ranges: Anthropic's
outbound range is `160.79.104.0/21`
([Anthropic: IP addresses](https://platform.claude.com/docs/en/api/ip-addresses)),
and OpenAI publishes ChatGPT's at `https://openai.com/chatgpt-connectors.json`
([OpenAI: IP addresses](https://developers.openai.com/api/docs/guides/ip-addresses)).
Both change over time; a narrowed bypass that falls behind them fails closed.

> **The acceptance check cannot tell the bypass from missing Access.** With
> `/mcp` bypassed, its anonymous `GET` reaches vigil and is answered 405, not
> 403. `init.sh` then needs `--allow-unprotected`, and `update.sh` fails its
> acceptance check and rolls back **every** update. Until the check learns
> about the bypass, a host that serves cloud connectors cannot be updated with
> `update.sh`. This is an open problem, not a setting.

Clients on your machine that send the service token keep working with the
bypass in place, whichever application a request lands in.

---

## Claude.ai

**Status: Not yet verified — tested on: <date>, client version: <version>.**
Draft from the vendor documentation of 2026-09-29.

- **Docs:** [Add an unlisted connector](https://claude.com/docs/connectors/custom/add-unlisted),
  [Connector authentication](https://claude.com/docs/connectors/building/authentication),
  [Getting started with custom connectors](https://support.claude.com/en/articles/11175166-getting-started-with-custom-connectors-using-remote-mcp)
- **Requests come from:** Anthropic's servers, not your device. The server
  and its discovery documents must be reachable from Anthropic's ranges.
- **Authentication:** OAuth. vigil's metadata advertises Client-ID Metadata
  Documents (`client_id_metadata_document_supported`, with
  `token_endpoint_auth_methods_supported: ["none"]`), so Claude uses its
  published identity; without them it falls back to Dynamic Client
  Registration, which vigil also supports. A seeded token does not fit:
  custom request headers are a beta for a limited set of organizations, and
  an `Authorization` header is not allowed on an OAuth connection.
- **Redirect URI:** `https://claude.ai/api/mcp/auth_callback`, shared by the
  web app, Desktop and mobile.
- **Access:** needs [the bypass](#the-bypass-for-cloud-connectors).

Steps on Free, Pro and Max (Free allows one custom connector):

1. **Customize › Connectors › Add custom connector.**
2. Enter `VIGIL_RESOURCE`, e.g. `https://vault.example.org/mcp`.
3. Leave the OAuth client fields empty, or, where the dialog offers the
   choice, pick *Use Claude's published identity*. vigil has no
   pre-registered client to enter. The authentication settings cannot be
   edited later: to change them, remove the connector and add it again.
4. **Add**, then **Connect**. The browser opens vigil's consent page (after
   the identity-provider login, if that is set up); enter the consent
   password.

On Team and Enterprise an owner adds it under **Organization settings ›
Connectors › Add › Custom › Web**, and each member then connects it under
**Customize › Connectors**. vigil has one vault and one consent password:
every member who connects reaches the same vault.

---

## Claude Desktop

**Status: Not yet verified — tested on: <date>, client version: <version>.**
Draft from the vendor documentation of 2026-09-29.

- **Docs:** [Getting started with custom connectors](https://support.claude.com/en/articles/11175166-getting-started-with-custom-connectors-using-remote-mcp),
  [When to use desktop and web connectors](https://support.claude.com/en/articles/11725091-when-to-use-desktop-and-web-connectors),
  [Connector authentication](https://claude.com/docs/connectors/building/authentication)
- **Requests come from:** Anthropic's servers, not your machine — a remote
  connector in Desktop is the same connector as on Claude.ai.
- **Authentication:** OAuth, as for Claude.ai, with the same redirect URI.
- **Access:** needs [the bypass](#the-bypass-for-cloud-connectors).

Steps: add the connector as for [Claude.ai](#claudeai), under **Customize ›
Connectors**, in Desktop or on the web. Desktop extensions (**Settings ›
Extensions**) are for servers that run on your machine and are not how vigil
is connected. The documentation does not say whether an entry in
`claude_desktop_config.json` can name a remote URL; use the connector.

---

## Claude Code

**Status: Not yet verified — tested on: <date>, client version: <version>.**
Draft from the vendor documentation of 2026-09-29.

- **Docs:** [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp),
  [Connector authentication](https://claude.com/docs/connectors/building/authentication)
- **Requests come from:** your machine.
- **Authentication:** OAuth — Claude Code runs the flow itself, with a
  Client-ID Metadata Document of its own and a loopback redirect,
  `http://localhost:<port>/callback`, whose port vigil ignores — or a seeded
  token sent as a header.
- **Access:** behind the service-token policy with a seeded token, or behind
  [the bypass](#the-bypass-for-cloud-connectors) with OAuth.

**With OAuth** (the bypass in place):

```bash
claude mcp add --transport http vigil https://vault.example.org/mcp
```

Then run `/mcp` in a session, pick `vigil` and authenticate, or run
`claude mcp login vigil` from the shell. The browser opens the consent page.

**With a seeded token** (the service-token policy):

```bash
claude mcp add --transport http --scope user vigil https://vault.example.org/mcp \
  --header "CF-Access-Client-Id: <client id>" \
  --header "CF-Access-Client-Secret: <client secret>" \
  --header "Authorization: Bearer <token>"
```

The token is the one `init.sh` printed, or a new one
([seeding a token](#seeding-a-token-for-a-header-client)). The headers are
stored as written in `~/.claude.json`. Never add them with `--scope project`,
which writes them into the repository's `.mcp.json`; a `.mcp.json` can name
`${VIGIL_TOKEN}`-style variables instead, which Claude Code expands. With an
`Authorization` header configured, Claude Code does not fall back to OAuth: a
token vigil refuses — expired after 90 days, or revoked — is a failed
connection until the header carries a new one.

The documentation does not say whether the configured headers are also sent
on OAuth's discovery and token requests, so OAuth behind the service-token
policy alone is not a documented setup.

---

## ChatGPT

**Status: Not yet verified — tested on: <date>, client version: <version>.**
Draft from the vendor documentation of 2026-09-29.

- **Docs:** [Developer mode](https://developers.openai.com/api/docs/guides/developer-mode),
  [Connect to ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt),
  [Apps SDK: authentication](https://developers.openai.com/apps-sdk/build/auth),
  [IP addresses](https://developers.openai.com/api/docs/guides/ip-addresses)
- **Requests come from:** OpenAI's servers.
- **Authentication:** OAuth. ChatGPT prefers Client-ID Metadata Documents,
  then Dynamic Client Registration; vigil offers both. No static bearer-token
  option is documented.
- **Redirect URI:** `https://chatgpt.com/connector_platform_oauth_redirect`,
  the one ChatGPT uses for an authorization server that supports RFC 9207
  issuer identification, as vigil's metadata says it does
  (`authorization_response_iss_parameter_supported`).
- **Access:** needs [the bypass](#the-bypass-for-cloud-connectors).

Steps on Plus, Pro, Business, Enterprise and Education, on the web (workspace
policy may hide it):

1. **Settings › Security and login › Developer mode**, on.
2. Open the plugins page and add one (**+**), with a name and a description.
3. Under **Connection**, enter `VIGIL_RESOURCE`, e.g.
   `https://vault.example.org/mcp`, with OAuth as the authentication.
4. Create it and connect; the browser opens vigil's consent page.

OpenAI's documentation now calls these plugins or developer-mode apps rather
than connectors; the labels above are the ones it used on 2026-09-29.

---

## Cursor

**Status: Not yet verified — tested on: <date>, client version: <version>.**
Draft from the vendor documentation of 2026-09-29.

- **Docs:** [Model Context Protocol](https://cursor.com/docs/context/mcp)
- **Requests come from:** your machine, for the desktop app, whose OAuth
  redirect is on `localhost`. The documentation does not say where Cursor's
  web app and cloud agents call from; treat them as cloud connectors.
- **Authentication:** OAuth through Dynamic Client Registration, or a seeded
  token in `headers`.
- **Redirect URIs:** `http://localhost:8787/callback` for the desktop app,
  `https://www.cursor.com/agents/mcp/oauth/callback` for the web app and
  agents. vigil's registration accepts both.
- **Access:** the desktop app works behind the service-token policy with a
  seeded token, or behind [the bypass](#the-bypass-for-cloud-connectors) with
  OAuth.

In `~/.cursor/mcp.json` (every project) or `.cursor/mcp.json` (one project),
with OAuth:

```json
{
  "mcpServers": {
    "vigil": { "url": "https://vault.example.org/mcp" }
  }
}
```

With a seeded token and the service-token policy, every secret read from the
environment so the file holds none:

```json
{
  "mcpServers": {
    "vigil": {
      "url": "https://vault.example.org/mcp",
      "headers": {
        "CF-Access-Client-Id": "${env:CF_ACCESS_CLIENT_ID}",
        "CF-Access-Client-Secret": "${env:CF_ACCESS_CLIENT_SECRET}",
        "Authorization": "Bearer ${env:VIGIL_TOKEN}"
      }
    }
  }
}
```

Cursor also takes a fixed OAuth client (`auth` with `CLIENT_ID`); vigil has
none to give, and Dynamic Client Registration needs none.

---

## Seeding a token for a header client

`init.sh` prints one `vault` and one `vault:read` token, each living 90 days.
A client that sends a header needs a new one when its token ends or is
revoked. There is no operator script for that yet; on the host, against the
running service, it is the call `init.sh` makes (`vigil_seed_token` in
[`scripts/lib.sh`](../scripts/lib.sh)):

```bash
sudo runuser -u vigil -- /opt/vigil/current/bin/vigil rpc \
  'IO.puts(Vigil.OAuth.Token.issue_out_of_band(Vigil.OAuth.Store.over_tables(), "https://vault.example.org/mcp", "vault", 7776000, System.system_time(:second)))'
```

The resource is `VIGIL_RESOURCE`, the scope `vault` or `vault:read`, the
lifetime in seconds (7776000 is 90 days). The token is printed once and kept
nowhere; `sudo ./scripts/grants.sh list` shows its grant as `(seeded)`, and it
is revoked like any other ([revoking access](guide.md#revoking-access)). Never
run `mix vigil.seed_token` while the service runs.

---

## Verifying a section

A section is verified when someone has connected the client to a deployed
vigil and, in one go:

1. connected — through the consent page, or with a seeded token for the
   header setup;
2. seen the tools listed, and called `status`, `search` and `read`;
3. called `skill_read` on `vigil-vault-conventions`, then written — `create`
   a throwaway note, then `delete_note` it with `confirm: true` — and seen
   both commits on the remote;
4. with a `vault:read` grant, seen the write tools missing and a write
   refused;
5. revoked the grant (`sudo ./scripts/grants.sh revoke <grant-id>`) and seen
   the client's next call refused.

Then replace the section's status line with the date, the client's version
(and plan, where the client has plans), the Access layout it went through, and
anything that differed from the draft.
