defmodule Vigil.MCP.Server do
  @moduledoc false
  use Plug.Router
  require Logger

  alias Vigil.MCP.{Tools, Envelope, Session}
  alias Vigil.RateLimit
  alias Vigil.SkillKey
  alias Vigil.Store
  alias Vigil.OAuth

  # The protocol versions this server speaks, latest first. A tools-only
  # server looks the same on the wire in all three: what 2025-06-18 and
  # 2025-11-25 added to it — a tool's and the server's `title`, `websiteUrl`,
  # a result's `structuredContent` — are fields an older client ignores or
  # that vigil does not send (`docs/design.md`, "Protocol versions").
  @protocol_versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @latest_protocol_version hd(@protocol_versions)
  @default_rpm 60

  # `reload` pulls and reparses the whole vault inside the writer, so it is
  # counted a second time, against a budget of its own well below the one
  # every request spends.
  @default_reload_rpm 6

  # How many bytes of a `/mcp` body are read (docs/design.md, "Input sizes are
  # bounded"). Stated here rather than left to Plug's default, which is a
  # number nothing in vigil decided. It is kept above the longest argument the
  # tool table admits sent as UTF-8 — a million characters of `content`, up
  # to four bytes each — plus the rest of the message, so a too-long note is
  # refused by the validation that names its parameter, not by this. It is
  # deliberately not kept above the same argument sent escaped: `\uXXXX` is
  # six bytes a character and a surrogate pair twelve, and a limit covering
  # that would let every request hold half again as much memory for a
  # client that escapes a whole book of emoji. Such a body gets the 413
  # below instead of the validation error — refused all the same.
  @max_body_bytes 8_000_000

  # Who this server says it is on `initialize`, beside its name and version.
  @server_title "Vigil"
  @website_url "https://github.com/64x-lunicorn/vigil"

  # What this router and the authorization server it forwards to must decide
  # against the same values: where the records are kept, where the windows are
  # counted, what this deployment says it is, and which browser origins may
  # send a request to either. Named once, so handing one down and reading it
  # back are the same list rather than two that have to be kept in step.
  @shared_with_oauth [:persistence, :limiter, :settings, :origins]

  # The authorization server's own options, handed on when a caller states
  # them — `Vigil.Application` does, from the checked settings — and left to
  # its defaults otherwise.
  @oauth_only [:client_addr, :limits]

  plug(:check_origin)
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
        Vigil.OAuth.Endpoint.init(Keyword.take(opts, @shared_with_oauth ++ @oauth_only))
      end)

    opts
    |> Keyword.put_new_lazy(:store, &Store.default_name/0)
    |> Keyword.put_new_lazy(:sessions, &Envelope.default_name/0)
    |> Keyword.put_new_lazy(:rate_limit_budget, fn ->
      RateLimit.configured_budget(:rate_limit_rpm, @default_rpm)
    end)
    |> Keyword.put_new_lazy(:reload_rate_limit_budget, fn ->
      RateLimit.configured_budget(:reload_rate_limit_rpm, @default_reload_rpm)
    end)
    |> Keyword.put(:oauth, oauth)
    |> Keyword.merge(shared_with_oauth!(oauth))
  end

  # Read back out of the authorization server's options rather than resolved a
  # second time, and `fetch!` rather than `get` because every one of them is
  # something `Vigil.OAuth.Endpoint.init/1` always fills in: a missing one is a
  # seam that has come apart, not a value to default.
  defp shared_with_oauth!(oauth),
    do: Enum.map(@shared_with_oauth, &{&1, Keyword.fetch!(oauth, &1)})

  @impl true
  def call(conn, opts) do
    conn
    |> put_private(:store, opts[:store])
    |> put_private(:sessions, opts[:sessions])
    |> put_private(:rate_limit_budget, opts[:rate_limit_budget])
    |> put_private(:reload_rate_limit_budget, opts[:reload_rate_limit_budget])
    |> put_private(:rate_limiter, opts[:limiter])
    |> put_private(:oauth_persistence, opts[:persistence])
    |> put_private(:oauth_opts, opts[:oauth])
    |> put_private(:settings, opts[:settings])
    |> put_private(:origins, opts[:origins])
    |> super(opts)
  end

  # A browser on another site must not reach `/mcp` (`Vigil.Origin`), and the
  # transport says so: MUST validate `Origin`, 403 when it is present and
  # invalid. Checked before the route runs — before the token is looked at and
  # before the body is read. Every other path is the authorization server's,
  # which checks its own, against the same origins.
  defp check_origin(%{path_info: ["mcp"]} = conn, _opts) do
    if Vigil.Origin.allowed?(conn, conn.private.origins) do
      conn
    else
      conn |> send_resp(403, "") |> halt()
    end
  end

  defp check_origin(conn, _opts), do: conn

  ## Routes — MCP

  post "/mcp" do
    handle_mcp(conn)
  end

  # No server-sent stream: the transport lets a server that offers none
  # answer GET with 405, and `Allow` names what `/mcp` does answer.
  get "/mcp" do
    method_not_allowed(conn)
  end

  # Ends the session the header names — the transport's way for a client to
  # say it is done. Authenticated and counted like every other request, and
  # answered as a request in an unknown session is: only the token the session
  # is bound to can end it, and every other answer is 404. Its
  # `MCP-Protocol-Version` is held to the same rule as a POST's — a version
  # this server does not speak, or one other than the session negotiated, is
  # a 400 and ends nothing.
  delete "/mcp" do
    authenticate(conn, fn conn, auth ->
      case check_protocol_version(conn) do
        {:ok, true, conn} ->
          with_session(conn, auth, fn conn, session_id ->
            case Session.finish(conn.private.sessions, session_id, auth.token_digest, unix_now()) do
              :ok -> send_resp(conn, 204, "")
              :error -> send_resp(conn, 404, "")
            end
          end)

        {:ok, false, conn} ->
          send_resp(conn, 400, "")
      end
    end)
  end

  # Any other method on the MCP endpoint is the same refusal as GET, not the
  # authorization server's 404: the path exists, the method does not.
  match "/mcp" do
    method_not_allowed(conn)
  end

  ## Routes — health

  # Whether this server is serving, and how it stands with the remote
  # (docs/design.md, "The server stays in step with the remote"). No token:
  # it is what `update.sh` waits on after a start, before any token exists.
  # So it answers only a request made on this host, and 404 to every other,
  # as if it were not there. 200 when the index is loaded and the writer
  # answers, 503 otherwise. The error text of the last push and of a failed
  # update (`stale`) is left out — git's words can name the remote's URL, and
  # that is the `status` tool's to show, behind a token.
  get "/healthz" do
    if on_this_host?(conn) do
      status = Store.status(conn.private.store)

      report =
        status
        |> Map.update!(:last_push, &without_error/1)
        |> Map.update!(:stale, &without_error/1)

      send_json(conn, if(status.healthy, do: 200, else: 503), report)
    else
      send_resp(conn, 404, "")
    end
  end

  # Everything that is not /mcp is the authorization server's: discovery
  # documents, registration, consent and token. Two protocols, two routers.
  match _ do
    Vigil.OAuth.Endpoint.call(conn, conn.private.oauth_opts)
  end

  defp method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_resp(405, "")
  end

  ## Health

  # The peer alone does not say "on this host": the proxy the deployment puts
  # in front (docs/guide.md) is itself on this host, so everything it forwards
  # arrives from loopback too. A proxy says what it forwarded for, in one of
  # these headers — or in the one the deployment names for the rate limiter —
  # and a request carrying any of them came from elsewhere. The host a request
  # names is checked too: a page that rebinds its own name onto 127.0.0.1
  # still sends that name.
  @proxy_headers ~w(forwarded x-forwarded-for x-real-ip cf-connecting-ip)
  @local_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp on_this_host?(conn) do
    configured = conn.private.oauth_opts |> Keyword.get(:client_addr, []) |> Keyword.get(:header)
    headers = Enum.reject([configured | @proxy_headers], &is_nil/1)

    loopback?(conn.remote_ip) and conn.host in @local_hosts and
      Enum.all?(headers, &(get_req_header(conn, &1) == []))
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # ::ffff:127.x.y.z, an IPv4 loopback peer on a dual-stack socket.
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, high, _low}), do: div(high, 256) == 127
  defp loopback?(_ip), do: false

  defp without_error(nil), do: nil
  defp without_error(report), do: Map.delete(report, :error)

  ## MCP handling

  defp handle_mcp(conn), do: authenticate(conn, &handle_mcp_authenticated/2)

  # The token is validated and counted before anything else about the request
  # is looked at, on every method that reaches it; `fun` gets what the token
  # says about the caller.
  defp authenticate(conn, fun) do
    case validate_access_token(conn) do
      {:ok, scope, token} ->
        budget = conn.private.rate_limit_budget
        now = System.system_time(:second)

        # Counted under the token's digest, not the token: the limiter's table
        # is as much a copy of what the server holds as the `:dets` files are.
        digest = OAuth.Token.digest(token)

        # `Retry-After` comes from the window itself, as on the authorization
        # server's 429s, so the wait it names is a fact rather than a guess.
        if conn.private.rate_limiter.limited?.(digest, budget, now) do
          conn
          |> put_resp_header("retry-after", Integer.to_string(RateLimit.window_seconds()))
          |> send_resp(429, "")
        else
          fun.(conn, %{scope: scope, token_digest: digest})
        end

      {:error, reason} ->
        send_401_challenge(conn, reason)
    end
  end

  # What makes a token acceptable here is `Vigil.OAuth.Token`'s to say — the
  # record's kind, its audience and its hour are its own facts, not the
  # router's. All this adds is the one thing that is HTTP: the header the
  # token arrived in, and that every refusal answers the same challenge —
  # `invalid_token` when a token was presented, nothing more when none was
  # (RFC 6750 §3.1), so a caller still learns nothing from which check
  # rejected it.
  defp validate_access_token(conn) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, scope} <-
           OAuth.Token.validate_access(persistence(conn), token, settings(conn).resource) do
      {:ok, scope, token}
    else
      :none -> {:error, :missing}
      :error -> {:error, :invalid_token}
    end
  end

  # The auth scheme is case-insensitive (RFC 9110 §11.1), so `bearer` and
  # `BEARER` name the same one. One header with a non-empty token is a token
  # presented; anything else — no header, another scheme, two headers — is
  # none.
  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim_leading(token, " ") do
      {:ok, token}
    else
      _ -> :none
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

  defp send_401_challenge(conn, reason) do
    error = if reason == :invalid_token, do: "error=\"invalid_token\", ", else: ""

    challenge =
      "Bearer #{error}resource_metadata=\"#{settings(conn).issuer}/.well-known/oauth-protected-resource\", scope=\"#{OAuth.scope()}\""

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> send_resp(401, "")
  end

  # `auth` is what the validated token says about the caller: its scope, and
  # the token's digest, which is what every budget here is counted against —
  # the token itself goes no further than the lookup.
  defp handle_mcp_authenticated(conn, auth) do
    with {:ok, protocol_version_ok?, conn} <- check_protocol_version(conn),
         true <- protocol_version_ok?,
         {:ok, body, conn} <- Plug.Conn.read_body(conn, length: @max_body_bytes),
         {:ok, msg} <- Jason.decode(body) do
      if is_map(msg), do: handle_message(conn, msg, auth), else: invalid_request(conn)
    else
      false ->
        send_resp(conn, 400, "")

      {:error, %Jason.DecodeError{}} ->
        send_json(conn, 200, %{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: -32700, message: "Parse error"}
        })

      # A body over the limit is not read to its end: nothing short of all of
      # it is a JSON-RPC message, so there is no id to echo. 413 says why at
      # the HTTP layer, the body says it in the protocol's words.
      {:more, _partial, conn} ->
        send_json(conn, 413, %{
          jsonrpc: "2.0",
          id: nil,
          error: %{
            code: -32600,
            message: "Invalid Request: body larger than #{@max_body_bytes} bytes"
          }
        })

      {:error, _} ->
        send_resp(conn, 400, "")
    end
  end

  # Refused before the body is read when it names no version this server
  # speaks, or names several. Whether it names the one a session negotiated
  # is asked once the session is known (`with_session/3`). No header at all is
  # accepted: a 2025-03-26 client sends none, and the version it speaks is the
  # one its session negotiated.
  defp check_protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> {:ok, true, conn}
      [version] -> {:ok, version in @protocol_versions, conn}
      _several -> {:ok, false, conn}
    end
  end

  # The client's version when this server speaks it, otherwise the latest this
  # server speaks — which the client then accepts or disconnects over.
  defp negotiate(%{"protocolVersion" => version}) when version in @protocol_versions,
    do: version

  defp negotiate(_params), do: @latest_protocol_version

  @doc false
  # The body limit, for the tests that have to cross it.
  def max_body_bytes, do: @max_body_bytes

  # A body that parses but is not one JSON-RPC message — a batch, a scalar,
  # an object with no method that is not a response either. Batches were
  # removed from MCP in 2025-06-18, and vigil receives none in any version
  # (`docs/design.md`, "Protocol versions"). The `id` is echoed when there is
  # a usable one.
  defp invalid_request(conn, id \\ nil) do
    send_json(conn, 200, %{
      jsonrpc: "2.0",
      id: if(is_binary(id) or is_integer(id), do: id),
      error: %{code: -32600, message: "Invalid Request"}
    })
  end

  # `initialize` is the one message outside a session, because it is the one
  # that starts one: bound to the token that sent it, under the token's digest,
  # and speaking the version negotiated here.
  defp handle_message(conn, %{"method" => "initialize"} = msg, auth) do
    protocol_version = negotiate(msg["params"])

    session_id =
      Session.issue(conn.private.sessions, auth.token_digest, protocol_version, unix_now())

    result = %{
      protocolVersion: protocol_version,
      serverInfo: %{
        name: "vigil",
        title: @server_title,
        version: Application.spec(:vigil, :vsn) |> to_string(),
        websiteUrl: @website_url
      },
      capabilities: %{tools: %{}},
      instructions: instructions_text(conn.private.store, settings(conn))
    }

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> send_json(200, %{jsonrpc: "2.0", id: msg["id"], result: result})
  end

  # Every other message is sent in a session, and is answered only in a live
  # one of this token's. A response the client sends back — it has `result`
  # or `error` and no `method` — is accepted with 202 like a notification:
  # vigil sends no requests, so there is nothing to match it to. An object
  # that is neither is not a JSON-RPC message.
  defp handle_message(conn, %{"method" => method} = msg, auth) when is_binary(method) do
    with_session(conn, auth, &handle_in_session(&1, msg, auth, &2))
  end

  defp handle_message(conn, msg, auth)
       when not is_map_key(msg, "method") and
              (is_map_key(msg, "result") or
                 is_map_key(msg, "error")) do
    with_session(conn, auth, fn conn, _session_id -> send_resp(conn, 202, "") end)
  end

  defp handle_message(conn, msg, _auth), do: invalid_request(conn, msg["id"])

  defp handle_in_session(conn, %{"method" => "notifications/initialized"}, _auth, _session_id) do
    send_resp(conn, 202, "")
  end

  defp handle_in_session(conn, %{"method" => "ping"} = msg, _auth, _session_id) do
    send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{}})
  end

  # A token that may not write is shown only the tools it may call. Listing the
  # writes to refuse each of them on the call is how users learn to approve
  # whatever is asked.
  defp handle_in_session(conn, %{"method" => "tools/list"} = msg, auth, _session_id) do
    tools = Tools.definitions(writes: OAuth.may_write?(auth.scope))
    send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{tools: tools}})
  end

  defp handle_in_session(
         conn,
         %{"method" => "tools/call", "params" => params} = msg,
         _auth,
         _session_id
       )
       when not is_map(params) and not is_nil(params) do
    send_json(conn, 200, %{
      jsonrpc: "2.0",
      id: msg["id"],
      error: %{code: -32602, message: "Invalid params: params must be an object"}
    })
  end

  # A name that is not a string, or names no tool, is a protocol error rather
  # than a tool result: nothing was called, so there is no envelope to attach
  # and no session state to advance.
  defp handle_in_session(conn, %{"method" => "tools/call"} = msg, auth, session_id) do
    params = msg["params"] || %{}

    case params["name"] do
      name when is_binary(name) ->
        if Tools.known?(name) do
          call_tool(conn, msg, name, params, auth, session_id)
        else
          invalid_params(conn, msg, "Unknown tool: #{name}")
        end

      _ ->
        invalid_params(conn, msg, "Invalid params: name must be a string")
    end
  end

  defp handle_in_session(conn, msg, _auth, _session_id) do
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

  defp invalid_params(conn, msg, message) do
    send_json(conn, 200, %{
      jsonrpc: "2.0",
      id: msg["id"],
      error: %{code: -32602, message: message}
    })
  end

  defp call_tool(conn, msg, name, params, auth, session_id) do
    arguments = params["arguments"] || %{}

    Logger.info("mcp tool_call tool=#{name} session=#{session_id}")

    store = conn.private.store

    {envelope, now} =
      Envelope.for_tool(conn.private.sessions, session_id, name, store, settings(conn).tz)

    result =
      cond do
        Tools.write_tool?(name) and not OAuth.may_write?(auth.scope) ->
          {:error, "Read-only token: write access denied."}

        reload_limited?(conn, name, auth.token_digest) ->
          {:error,
           "Rate limit exceeded for reload: at most #{conn.private.reload_rate_limit_budget} per minute. Try again in #{RateLimit.window_seconds()} seconds."}

        true ->
          Tools.dispatch(store, name, arguments, now, SkillKey.key(settings(conn)))
      end

    body = build_tool_call_result(result, envelope)
    send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: body})
  end

  # `reload`'s own window, per access token, in the same limiter as every
  # other budget and under a key of its own, so the two are counted apart. It
  # answers as a tool error rather than a 429: the request itself was within
  # its budget, the session goes on, and the caller is told which call to
  # stop repeating.
  defp reload_limited?(conn, "reload", token_digest) do
    conn.private.rate_limiter.limited?.(
      {:reload, token_digest},
      conn.private.reload_rate_limit_budget,
      System.system_time(:second)
    )
  end

  defp reload_limited?(_conn, _name, _token_digest), do: false

  # A request in a session names it in one non-empty header, or is a 400. An
  # id that is not a live session of this token's — never issued, another
  # token's, expired, ended, or issued before a restart — is a 404, which the
  # transport tells a client to answer by initializing a new one. Nothing
  # here adds a row: only `initialize` does (`Vigil.MCP.Session`). A
  # `MCP-Protocol-Version` header naming a version other than the one the
  # session negotiated is a 400; no header is the negotiated version.
  defp with_session(conn, auth, fun) do
    with_header_session(conn, fn session_id ->
      case Session.resume(conn.private.sessions, session_id, auth.token_digest, unix_now()) do
        {:ok, protocol_version} ->
          if get_req_header(conn, "mcp-protocol-version") in [[], [protocol_version]] do
            fun.(conn, session_id)
          else
            send_resp(conn, 400, "")
          end

        :error ->
          send_resp(conn, 404, "")
      end
    end)
  end

  defp with_header_session(conn, fun) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] when session_id != "" -> fun.(session_id)
      _ -> send_resp(conn, 400, "")
    end
  end

  defp unix_now, do: System.system_time(:second)

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
  #
  # What a result says about itself beside its value — `stale: true` for a
  # read answered from a vault that could not be brought up to date — sits
  # next to `result` or `error`, so it reads the same on every tool whatever
  # the result's own shape.
  defp build_tool_call_result({tag, value}, envelope),
    do: build_tool_call_result({tag, value, %{}}, envelope)

  defp build_tool_call_result({:ok, value, beside}, envelope),
    do: %{content: [text_content(Map.put(beside, :result, value), envelope)]}

  defp build_tool_call_result({:error, message, beside}, envelope),
    do: %{content: [text_content(Map.put(beside, :error, message), envelope)], isError: true}

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
