defmodule Vigil.MCP.Server do
  @moduledoc false
  use Plug.Router
  require Logger

  alias Vigil.MCP.{Tools, Envelope}
  alias Vigil.RateLimit
  alias Vigil.Store
  alias Vigil.OAuth

  @protocol_version "2025-11-25"
  @default_rpm 60

  plug(:match)
  plug(:dispatch)

  # Resolves the writer, the rate limit budget, the limiter, OAuth persistence
  # and the authorization server's own options once, when Bandit starts this
  # plug (or a test calls init/1 directly — several do, with no options, and
  # that must keep working), rather than reading application config on every
  # request. Forwarding used to call `Vigil.OAuth.Endpoint.init/1` per request,
  # which re-parsed the trusted proxy list every time.
  #
  # The writer and the session table are resolved here because both halves of a
  # response are decided against them — the tool call and the envelope that
  # wraps it — and this router is the only thing that knows they are the same
  # vault and the same session. Defaulting inside each half instead is how one
  # of them came to be given a writer and the other left to find one by name,
  # so neither half defaults: both are asked for on every call.
  #
  # Persistence, the limiter and the deployment's settings are handed down to
  # the authorization server's options and read back out of them rather than
  # resolved twice: the token this router verifies and the token that server
  # minted are kept in the same place by construction, the windows both count
  # in are the same windows, and both halves agree on what this server is
  # called and what it protects — including when a caller hands the server's
  # options in ready-made.
  @impl true
  def init(opts) do
    oauth =
      Keyword.get_lazy(opts, :oauth, fn ->
        Vigil.OAuth.Endpoint.init(Keyword.take(opts, [:persistence, :limiter, :settings]))
      end)

    opts
    |> Keyword.put_new_lazy(:store, &Store.default_name/0)
    |> Keyword.put_new_lazy(:sessions, &Envelope.default_name/0)
    |> Keyword.put_new_lazy(:rate_limit_budget, fn ->
      RateLimit.budget(:rate_limit_rpm, @default_rpm)
    end)
    |> Keyword.put(:oauth, oauth)
    |> Keyword.put(:persistence, Keyword.fetch!(oauth, :persistence))
    |> Keyword.put(:limiter, Keyword.fetch!(oauth, :limiter))
    |> Keyword.put(:settings, Keyword.fetch!(oauth, :settings))
  end

  @impl true
  def call(conn, opts) do
    conn
    |> put_private(:store, opts[:store])
    |> put_private(:sessions, opts[:sessions])
    |> put_private(:rate_limit_budget, opts[:rate_limit_budget])
    |> put_private(:rate_limiter, opts[:limiter])
    |> put_private(:oauth_persistence, opts[:persistence])
    |> put_private(:oauth_opts, opts[:oauth])
    |> put_private(:settings, opts[:settings])
    |> super(opts)
  end

  ## Routes — MCP

  post "/mcp" do
    handle_mcp(conn)
  end

  get "/mcp" do
    send_resp(conn, 405, "")
  end

  delete "/mcp" do
    send_resp(conn, 405, "")
  end

  # Everything that is not /mcp is the authorization server's: discovery
  # documents, registration, consent and token. Two protocols, two routers.
  match _ do
    Vigil.OAuth.Endpoint.call(conn, conn.private.oauth_opts)
  end

  ## MCP handling

  defp handle_mcp(conn) do
    case validate_access_token(conn) do
      {:ok, scope, token} ->
        budget = conn.private.rate_limit_budget
        now = System.system_time(:second)

        if conn.private.rate_limiter.limited?.(token, budget, now) do
          send_resp(conn, 429, "")
        else
          handle_mcp_authenticated(conn, scope)
        end

      {:error, :challenge} ->
        send_401_challenge(conn)
    end
  end

  # What makes a token acceptable here is `Vigil.OAuth.Token`'s to say — the
  # record's kind, its audience and its hour are its own facts, not the
  # router's. All this adds is the one thing that is HTTP: the header the
  # token arrived in, and that every refusal answers the same challenge.
  defp validate_access_token(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, scope} <-
           OAuth.Token.validate_access(persistence(conn), token, settings(conn).resource) do
      {:ok, scope, token}
    else
      _ -> {:error, :challenge}
    end
  end

  # Where the record this token is checked against is kept. Resolved in
  # `init/1`, out of the authorization server's own options.
  defp persistence(conn), do: conn.private.oauth_persistence

  # What the deployment says about itself: the resource a token is checked
  # against, the issuer a challenge points at, the timezone a response is
  # stamped with, and the two strings the writing instructions are shaped by.
  # Resolved in `init/1`, out of the authorization server's own options, for
  # the same reason persistence is.
  defp settings(conn), do: conn.private.settings

  defp send_401_challenge(conn) do
    challenge =
      "Bearer resource_metadata=\"#{settings(conn).issuer}/.well-known/oauth-protected-resource\", scope=\"#{OAuth.scope()}\""

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> send_resp(401, "")
  end

  defp handle_mcp_authenticated(conn, scope) do
    with {:ok, protocol_version_ok?, conn} <- check_protocol_version(conn),
         true <- protocol_version_ok?,
         {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, msg} <- Jason.decode(body) do
      handle_message(conn, msg, scope)
    else
      false ->
        send_resp(conn, 400, "")

      {:error, %Jason.DecodeError{}} ->
        send_json(conn, 200, %{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: -32700, message: "Parse error"}
        })

      {:error, _} ->
        send_resp(conn, 400, "")
    end
  end

  defp check_protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> {:ok, true, conn}
      [@protocol_version] -> {:ok, true, conn}
      [_other] -> {:ok, false, conn}
    end
  end

  defp handle_message(conn, %{"method" => "initialize"} = msg, _scope) do
    session_id = Vigil.Uuid.v4()

    result = %{
      protocolVersion: @protocol_version,
      serverInfo: %{name: "vigil", version: Application.spec(:vigil, :vsn) |> to_string()},
      capabilities: %{tools: %{}},
      instructions: instructions_text(conn.private.store, settings(conn))
    }

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> send_json(200, %{jsonrpc: "2.0", id: msg["id"], result: result})
  end

  defp handle_message(conn, %{"method" => "notifications/initialized"}, _scope) do
    send_resp(conn, 202, "")
  end

  defp handle_message(conn, %{"method" => "ping"} = msg, _scope) do
    with_session(conn, fn _session_id ->
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{}})
    end)
  end

  defp handle_message(conn, %{"method" => "tools/list"} = msg, _scope) do
    with_session(conn, fn _session_id ->
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{tools: Tools.definitions()}})
    end)
  end

  defp handle_message(conn, %{"method" => "tools/call"} = msg, scope) do
    with_session(conn, fn session_id ->
      params = msg["params"] || %{}
      name = params["name"]
      arguments = params["arguments"] || %{}

      Logger.info("mcp tool_call tool=#{name} session=#{session_id}")

      store = conn.private.store

      {envelope, now} =
        Envelope.for_tool(conn.private.sessions, session_id, name, store, settings(conn).tz)

      result =
        if scope == OAuth.read_scope() and Tools.write_tool?(name) do
          {:error, "Read-only token: write access denied."}
        else
          Tools.dispatch(store, name, arguments, now)
        end

      body = build_tool_call_result(result, envelope)
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: body})
    end)
  end

  defp handle_message(conn, msg, _scope) do
    if Map.has_key?(msg, "id") do
      send_json(conn, 200, %{
        jsonrpc: "2.0",
        id: msg["id"],
        error: %{code: -32601, message: "Method not found"}
      })
    else
      send_resp(conn, 202, "")
    end
  end

  defp with_session(conn, fun) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] when session_id != "" -> fun.(session_id)
      _ -> send_resp(conn, 400, "")
    end
  end

  # The envelope is attached around both outcomes rather than inside the
  # success branch, so "every tool response carries exactly one of `_`, `_t` or
  # `_!`" (docs/design.md, "The time envelope") is structurally true instead of
  # true in one of two branches. It is obtained before the call because the
  # instant it was decided at is the one the call itself is then made with,
  # and a response has exactly one. The envelope therefore describes the
  # vault as the request found it, not as the call left it: a write that puts
  # an event into or out of its window is reported on the session's next
  # response rather than on its own — a lag the envelope can afford, where
  # the alternative cannot: deciding after the call costs either a second
  # clock read or an instant the router holds on the envelope's behalf, and
  # those are the two things this stopped doing. An error advances the
  # session's state too: a failed first call is still a call the session
  # made, and repeating the long first form on the next one would be a lie
  # about which response is first.
  defp build_tool_call_result(result, envelope) do
    case result do
      {:ok, value} ->
        %{content: [text_content(%{result: value}, envelope)]}

      {:error, message} ->
        %{content: [text_content(%{error: message}, envelope)], isError: true}
    end
  end

  defp text_content(payload, envelope) do
    %{type: "text", text: Jason.encode!(Map.merge(payload, envelope))}
  end

  # Sent to the client on `initialize`. These are writing rules for the vault,
  # not rules for this server, which is why the two things they depend on —
  # who the vault belongs to and which language it is written in — are the
  # deployment's rather than hardcoded. `VIGIL_VAULT_LANGUAGE` governs the
  # language of the *notes*; the server itself always speaks English.
  defp base_instructions(settings) do
    owner = settings.vault_owner
    language = settings.vault_language

    """
    Voice: use #{owner}'s own phrasing verbatim, do not smooth it out. What they
    said, in their words — when in doubt quote more rawly rather than summarize
    more elegantly. Mark your own interpretations and suggestions explicitly as
    such ("Suggestion from Claude: …"). In five years the vault must still sound
    like #{owner}, not like Claude.

    Language: write notes and headings in #{language}. Established technical
    terms stay in the language they are normally used in; do not translate them
    in either direction.

    Atomicity: every section must stand on its own — it gets retrieved
    individually. No "as mentioned above", no pronouns pointing outside the
    section.

    Frugality: always search before create. Prefer appending to something that
    exists over adding a new note. Do not write summaries of things the vault
    already contains.

    type: reference = a fact about the world (does not age). decision = a fact
    about #{owner} (ages). event = has starts/ends. When in doubt, decision.

    Skills: call skill_write only when explicitly told to. Never create or
    change skills on your own initiative, not even when it seems obvious.
    Skills are instructions to Claude; writing them is #{owner}'s decision, not
    Claude's.
    """
  end

  defp instructions_text(store, settings) do
    base_instructions(settings) <>
      "\n\n## Domains (_domains.yml)\n\n```yaml\n" <>
      Store.instructions_domains_text(store) <> "\n```"
  end

  ## shared helpers

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
