defmodule Vigil.MCP.Server do
  @moduledoc false
  use Plug.Router
  require Logger

  alias Vigil.MCP.{Tools, Envelope, RateLimit}
  alias Vigil.Store
  alias Vigil.OAuth

  @protocol_version "2025-11-25"

  plug(:match)
  plug(:dispatch)

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
    Vigil.OAuth.Endpoint.call(conn, Vigil.OAuth.Endpoint.init([]))
  end

  ## MCP handling

  defp handle_mcp(conn) do
    case validate_access_token(conn) do
      {:ok, scope, token} ->
        if RateLimit.limited?(token) do
          send_resp(conn, 429, "")
        else
          handle_mcp_authenticated(conn, scope)
        end

      {:error, :challenge} ->
        send_401_challenge(conn)
    end
  end

  defp validate_access_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case check_access_token(token) do
          {:ok, scope} -> {:ok, scope, token}
          {:error, :challenge} -> {:error, :challenge}
        end

      _ ->
        {:error, :challenge}
    end
  end

  defp check_access_token(token) do
    case OAuth.Store.get_token(token) do
      :error ->
        {:error, :challenge}

      {:ok, %{type: :refresh}} ->
        {:error, :challenge}

      {:ok, record} ->
        now = System.system_time(:second)

        cond do
          record.expires_at <= now ->
            OAuth.Store.delete_token(token)
            {:error, :challenge}

          not Plug.Crypto.secure_compare(record.aud, OAuth.resource()) ->
            {:error, :challenge}

          true ->
            {:ok, Map.get(record, :scope, OAuth.scope())}
        end
    end
  end

  defp send_401_challenge(conn) do
    challenge =
      "Bearer resource_metadata=\"#{OAuth.issuer()}/.well-known/oauth-protected-resource\", scope=\"#{OAuth.scope()}\""

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
      instructions: instructions_text()
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

      result =
        if scope == OAuth.read_scope() and Tools.write_tool?(name) do
          {:error, "Read-only token: write access denied."}
        else
          Tools.dispatch(name, arguments)
        end

      body = build_tool_call_result(name, result, session_id)
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

  defp build_tool_call_result(name, {:ok, value}, session_id) do
    now = Vigil.Clock.now()
    snapshot = Store.snapshot(now)
    envelope = envelope_for(name, session_id, now, snapshot)
    text = Jason.encode!(Map.merge(%{result: value}, envelope))
    %{content: [%{type: "text", text: text}]}
  end

  defp build_tool_call_result(_name, {:error, message}, _session_id) do
    %{content: [%{type: "text", text: message}], isError: true}
  end

  defp envelope_for("current", session_id, now, snapshot),
    do: Envelope.for_current(session_id, now, snapshot)

  defp envelope_for(_name, session_id, now, snapshot),
    do: Envelope.for_call(session_id, now, snapshot)

  # Sent to the client on `initialize`. These are writing rules for the vault,
  # not rules for this server, which is why the two things they depend on —
  # who the vault belongs to and which language it is written in — come from
  # configuration rather than being hardcoded. `VIGIL_VAULT_LANGUAGE` governs
  # the language of the *notes*; the server itself always speaks English.
  defp base_instructions do
    owner = Application.get_env(:vigil, :vault_owner, "the vault owner")
    language = Application.get_env(:vigil, :vault_language, "English")

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

  defp instructions_text do
    base_instructions() <>
      "\n\n## Domains (_domains.yml)\n\n```yaml\n" <> Store.instructions_domains_text() <> "\n```"
  end

  ## shared helpers

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
