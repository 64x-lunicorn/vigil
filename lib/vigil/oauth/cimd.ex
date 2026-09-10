defmodule Vigil.OAuth.Cimd do
  @moduledoc """
  Client ID Metadata Document fetching (draft-ietf-oauth-client-id-metadata-document).
  `client_id` is an https:// URL pointing at a JSON document describing the client.

  This is the only place vigil makes an outbound request to an address an
  untrusted party chooses, so the guard around it is the module's real subject.
  The host is resolved **once**; that address is checked, and that same address
  is what the socket is opened against. A guard that resolves and then hands a
  URL to an HTTP client which resolves again is bypassed by answering the two
  lookups differently, which is DNS rebinding and the standard bypass for a
  guard shaped that way.
  """
  alias Vigil.OAuth.{Store, RedirectUri}

  @timeout 5_000
  @max_bytes 65_536

  @doc """
  The two facts the fetch reaches for outside itself: the outbound request and
  the name resolution the SSRF guard decides on.

  They travel bundled, the way `Vigil.SkillKey`'s secret and window do, because
  neither is useful alone: a test that fakes the request but not the resolution
  still asks a real resolver about a host, and one that fakes the resolution but
  not the request still opens a socket. Only both together take this module off
  the network.
  """
  def net, do: %{request: &http_get/2, resolve: &:inet.getaddr/2}

  @doc "Fetches and validates a CIMD document, cached for 1h. Returns {:ok, client_meta} | :error."
  def fetch(url, now \\ System.system_time(:second), net \\ net()) do
    case Store.cimd_cache_get(url, now) do
      {:ok, doc} ->
        {:ok, doc}

      :error ->
        with {:ok, uri} <- validate_url(url),
             {:ok, ip} <- public_address(uri.host, net.resolve),
             {:ok, body} <- net.request.(uri, ip),
             # `read_capped/2` already refuses an oversized body during the
             # read. The bound is repeated here because the request is a seam:
             # the cap belongs to the fetch's contract, not to one
             # implementation of the request behind it.
             true <- byte_size(body) <= @max_bytes,
             {:ok, json} <- Jason.decode(body),
             :ok <- validate_document(json, url) do
          doc = %{
            client_id: url,
            name: Map.get(json, "client_name", url),
            redirect_uris: Map.get(json, "redirect_uris", [])
          }

          Store.cimd_cache_put(url, doc, now)
          {:ok, doc}
        else
          _ -> :error
        end
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} = uri when is_binary(host) and host != "" -> {:ok, uri}
      _ -> :error
    end
  end

  ## The SSRF guard

  # One lookup, one decision, one address handed on. IPv4 first, IPv6 only when
  # the host has no A record.
  defp public_address(host, resolve) do
    host = String.to_charlist(host)

    case resolve.(host, :inet) do
      {:ok, ip} ->
        if_public(ip)

      {:error, _} ->
        case resolve.(host, :inet6) do
          {:ok, ip} -> if_public(ip)
          {:error, _} -> :error
        end
    end
  end

  defp if_public(ip), do: if(private_ip?(ip), do: :error, else: {:ok, ip})

  # An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is an IPv4 address wearing an
  # eight-element tuple: it matches neither the IPv6 loopback clause nor
  # fc00::/7, so without this it fell through to "public" and `::ffff:127.0.0.1`
  # reached the loopback interface. Unfolded first, so every IPv4 range below
  # covers its mapped form too.
  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    private_ip?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({198, b, _, _}) when b >= 18 and b <= 19, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp private_ip?(_), do: false

  ## The request

  defp http_get(uri, ip) do
    :inets.start()
    :ssl.start()

    options = [sync: false, stream: :self, body_format: :binary]

    case :httpc.request(:get, request_for(uri, ip), http_options(uri.host), options) do
      {:ok, ref} -> read_capped(ref)
      _ -> :error
    end
  end

  @doc """
  The `:httpc` request for fetching `uri` from the address `ip`.

  This is where "the address the guard checked is the address connected to"
  actually happens, so it is public and asserted on directly: the URL names the
  address, never the host, and the host travels as the `Host` header instead —
  and as the TLS server name, via `http_options/1`. Everything else about the
  URL has to survive the rewrite: the path, the query and a non-default port.
  """
  def request_for(uri, ip) do
    {connect_url(uri, ip), [{~c"host", String.to_charlist(host_header(uri))}]}
  end

  defp connect_url(uri, ip) do
    path = uri.path || "/"
    query = if uri.query, do: "?" <> uri.query, else: ""

    String.to_charlist("https://#{address_literal(ip)}:#{uri.port || 443}#{path}#{query}")
  end

  # An IPv6 address has to be bracketed before it can carry a port.
  defp address_literal(ip) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]"
  defp address_literal(ip), do: "#{:inet.ntoa(ip)}"

  defp host_header(%URI{host: host, port: port}) when port in [nil, 443], do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  @doc """
  The `:httpc` options for a CIMD fetch against `host`.

  Public so the two properties that are easy to lose in a refactor can be
  asserted: redirects stay refused, so a 302 into the private range cannot be
  followed, and TLS stays verified against the system trust store with a
  hostname check.
  """
  def http_options(host) do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      # The socket is opened against a pinned address, so the host reaches TLS
      # only through here. In OTP's `:ssl` this value is both the SNI extension
      # and the reference identity the hostname check runs against, so pinning
      # the address costs nothing in certificate verification.
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    [timeout: @timeout, connect_timeout: @timeout, autoredirect: false, ssl: ssl]
  end

  @doc """
  Reads a streamed `:httpc` response, refusing it the moment it exceeds the
  64 KB cap rather than after the whole body has been buffered.

  Two ways to be too big, and both are refused before the bytes are read: a
  declared `content-length` over the cap ends the request without reading any
  body at all, and a body that has no declared length is counted as it arrives
  and cancelled on the chunk that crosses the cap.

  Public because the cap is the whole point of the function, and a test can
  drive it with the exact message sequence `:httpc` produces.
  """
  def read_capped(ref, cancel \\ &:httpc.cancel_request/1), do: collect(ref, 0, [], cancel)

  defp collect(ref, seen, acc, cancel) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        if refuse_start?(headers) do
          refuse(ref, cancel)
        else
          collect(ref, seen, acc, cancel)
        end

      {:http, {^ref, :stream, data}} ->
        seen = seen + byte_size(data)

        if seen > @max_bytes do
          refuse(ref, cancel)
        else
          collect(ref, seen, [data | acc], cancel)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      # `:httpc` streams 200 and 206 and delivers everything else whole. A
      # non-200 is refused on its status; nothing here looks at its body.
      {:http, {^ref, {{_version, _status, _reason}, _headers, _body}}} ->
        :error

      {:http, {^ref, {:error, _reason}}} ->
        :error
    after
      # A backstop, not the deadline. This `after` is per-message, so a body
      # trickled a byte at a time would reset it forever — but `:httpc`'s own
      # `timeout:` bounds the whole request even in streaming mode, verified
      # against a server sending one chunk every two seconds: it answered
      # `{:error, :timeout}` after 5s and 3 bytes. This clause is what catches
      # `:httpc` going away without saying so.
      @timeout -> refuse(ref, cancel)
    end
  end

  defp refuse(ref, cancel) do
    cancel.(ref)
    flush(ref)
    :error
  end

  # `:httpc.cancel_request/1` is asynchronous: chunks already in flight still
  # arrive. Left behind they accumulate in a connection process that serves
  # more than one request — on the one path where how much arrives is the
  # other party's choice.
  defp flush(ref) do
    receive do
      {:http, {^ref, _}} -> flush(ref)
      {:http, {^ref, _, _}} -> flush(ref)
    after
      0 -> :ok
    end
  end

  # `:httpc` streams 200 and 206 alike and the stream_start message carries no
  # status, so a 206 is recognised by the Content-Range it must carry: this
  # fetch sends no Range header, so a partial response is a server that cannot
  # be taken at its word.
  defp refuse_start?(headers) do
    declared_over_cap?(headers) or header(headers, ~c"content-range") != nil
  end

  defp declared_over_cap?(headers) do
    case header(headers, ~c"content-length") do
      nil -> false
      value -> match?({length, ""} when length > @max_bytes, Integer.parse(to_string(value)))
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if :string.lowercase(key) == name, do: value
    end)
  end

  ## The document

  defp validate_document(%{"client_id" => doc_client_id} = json, url) do
    cond do
      doc_client_id != url -> :error
      not is_binary(Map.get(json, "client_name")) -> :error
      not is_list(Map.get(json, "redirect_uris")) -> :error
      Map.get(json, "redirect_uris") == [] -> :error
      not Enum.all?(json["redirect_uris"], &RedirectUri.valid_candidate?/1) -> :error
      true -> :ok
    end
  end

  defp validate_document(_json, _url), do: :error
end
