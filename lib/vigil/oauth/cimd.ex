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
  alias Vigil.OAuth.RedirectUri

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

  `resolve_timeout` bounds the resolution, both families together, in
  milliseconds. It travels with the resolver so a test that fakes a resolver
  which never answers can wait for a deadline of its choosing; a `net` without
  it gets the same 5 s the request has.
  """
  def net, do: %{request: &http_get/2, resolve: &:inet.getaddr/2, resolve_timeout: @timeout}

  @doc """
  Fetches and validates a CIMD document, cached for 1h through the persistence
  it is handed. Returns `{:ok, client_meta}` or `:error`.
  """
  def fetch(persistence, url, now \\ System.system_time(:second), net \\ net()) do
    case persistence.cimd_cache_get.(url, now) do
      {:ok, doc} ->
        {:ok, doc}

      :error ->
        with {:ok, uri} <- validate_url(url),
             {:ok, ip} <- public_address(uri.host, net),
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

          persistence.cimd_cache_put.(url, doc, now)
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
  # the host has no A record. Both lookups together run under one deadline: the
  # resolver is the other party's DNS, and a name server that never answers
  # would otherwise hold the request that asked for the client open for as long
  # as the system resolver cares to wait.
  defp public_address(host, net) do
    host = String.to_charlist(host)
    timeout = Map.get(net, :resolve_timeout, @timeout)
    task = Task.async(fn -> lookup(host, net.resolve) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, ip}} -> if(public?(ip), do: {:ok, ip}, else: :error)
      _ -> :error
    end
  end

  defp lookup(host, resolve) do
    case resolve.(host, :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> resolve.(host, :inet6)
    end
  end

  # The guard is an allow-list. A deny-list of the ranges someone remembered
  # to name is only as good as that memory, and it had already missed NAT64,
  # 6to4, Teredo, the TEST-NETs and 240.0.0.0/4. Here an IPv4 address is
  # reachable only outside every block below, and an IPv6 address only inside
  # 2000::/3, the global unicast space, and outside every block below.
  #
  # The tables are the IANA IPv4 and IPv6 Special-Purpose Address Registries
  # (RFC 6890), every entry, including the few the registry marks globally
  # reachable — an anycast relay or an AS112 sink is never where a client
  # publishes its metadata.
  cidr = fn block ->
    [address, length] = String.split(block, "/")
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))
    bits = if tuple_size(ip) == 4, do: 8, else: 16
    value = ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 * Bitwise.bsl(1, bits) + &1))
    {value, String.to_integer(length)}
  end

  @ipv4_special Enum.map(
                  [
                    # "This network" — RFC 791 §3.2 (0.0.0.0/32, "this host", inside it)
                    "0.0.0.0/8",
                    # Private-use — RFC 1918
                    "10.0.0.0/8",
                    # Shared address space, carrier-grade NAT — RFC 6598
                    "100.64.0.0/10",
                    # Loopback — RFC 1122 §3.2.1.3
                    "127.0.0.0/8",
                    # Link-local — RFC 3927
                    "169.254.0.0/16",
                    # Private-use — RFC 1918
                    "172.16.0.0/12",
                    # IETF protocol assignments — RFC 6890 §2.1; holds DS-Lite
                    # 192.0.0.0/29 (RFC 7335), the dummy address 192.0.0.8/32
                    # (RFC 7600), PCP anycast 192.0.0.9/32 (RFC 7723), TURN
                    # anycast 192.0.0.10/32 (RFC 8155) and NAT64/DNS64
                    # discovery 192.0.0.170/31 (RFC 8880)
                    "192.0.0.0/24",
                    # Documentation, TEST-NET-1 — RFC 5737
                    "192.0.2.0/24",
                    # AS112-v4 — RFC 7535
                    "192.31.196.0/24",
                    # AMT — RFC 7450
                    "192.52.193.0/24",
                    # Deprecated 6to4 relay anycast — RFC 7526
                    "192.88.99.0/24",
                    # Private-use — RFC 1918
                    "192.168.0.0/16",
                    # Direct delegation AS112 service — RFC 7534
                    "192.175.48.0/24",
                    # Benchmarking — RFC 2544
                    "198.18.0.0/15",
                    # Documentation, TEST-NET-2 — RFC 5737
                    "198.51.100.0/24",
                    # Documentation, TEST-NET-3 — RFC 5737
                    "203.0.113.0/24",
                    # Multicast — RFC 5771. Not a special-purpose entry, it has
                    # a registry of its own, but no unicast fetch belongs there.
                    "224.0.0.0/4",
                    # Reserved — RFC 1112 §4
                    "240.0.0.0/4",
                    # Limited broadcast — RFC 8190, RFC 919 §7 (inside 240/4 too)
                    "255.255.255.255/32"
                  ],
                  cidr
                )

  @global_unicast cidr.("2000::/3")

  # The registry entries outside 2000::/3 are refused by that alone; they are
  # listed anyway so this table reads as the registry does. Four entries are
  # absent because the address they carry decides instead — ::ffff:0:0/96,
  # 64:ff9b::/96, 2001::/32 and 2002::/16, see `embedded_ipv4/1` — and one,
  # 64:ff9b:1::/48, is refused by a clause of its own.
  @ipv6_special Enum.map(
                  [
                    # Unspecified — RFC 4291
                    "::/128",
                    # Loopback — RFC 4291
                    "::1/128",
                    # Discard-only — RFC 6666
                    "100::/64",
                    # Dummy IPv6 prefix — RFC 9780
                    "100:0:0:1::/64",
                    # IETF protocol assignments — RFC 2928; holds PCP anycast
                    # 2001:1::1 (RFC 7723), TURN anycast 2001:1::2 (RFC 8155),
                    # DNS-SD SRP anycast 2001:1::3 (RFC 9665), benchmarking
                    # 2001:2::/48 (RFC 5180), AMT 2001:3::/32 (RFC 7450),
                    # AS112-v6 2001:4:112::/48 (RFC 7535), ORCHID 2001:10::/28
                    # (RFC 4843), ORCHIDv2 2001:20::/28 (RFC 7343) and Drone
                    # Remote ID 2001:30::/28 (RFC 9374). Teredo, 2001::/32, is
                    # the one entry inside it judged by what it carries.
                    "2001::/23",
                    # Documentation — RFC 3849
                    "2001:db8::/32",
                    # Direct delegation AS112 service — RFC 7534
                    "2620:4f:8000::/48",
                    # Documentation — RFC 9637
                    "3fff::/20",
                    # Segment Routing (SRv6) SIDs — RFC 9602
                    "5f00::/16",
                    # Unique local — RFC 4193, RFC 8190
                    "fc00::/7",
                    # Link-local unicast — RFC 4291
                    "fe80::/10"
                  ],
                  cidr
                )

  defp public?({_, _, _, _} = ip), do: not in_any?(integer(ip, 8), 32, @ipv4_special)

  defp public?(ip) do
    case embedded_ipv4(ip) do
      {:carries, ipv4s} ->
        Enum.all?(ipv4s, &public?/1)

      :refuse ->
        false

      :native ->
        value = integer(ip, 16)
        in_block?(value, 128, @global_unicast) and not in_any?(value, 128, @ipv6_special)
    end
  end

  # The IPv6 forms that are an IPv4 address in transit. Each is judged by the
  # IPv4 address it will end up at, so a NAT64 or tunnel prefix is exactly as
  # reachable as the address inside it, and `64:ff9b::10.0.0.1` is 10.0.0.1.
  #
  # `::` and `::1` share their shape with the IPv4-compatible form, which would
  # unfold them into 0.0.0.0/8 and refuse them anyway. They are named first so
  # the IPv6 unspecified and loopback addresses are refused as themselves
  # rather than by coincidence.
  defp embedded_ipv4({0, 0, 0, 0, 0, 0, 0, a}) when a in [0, 1], do: :native
  # IPv4-mapped — RFC 4291 §2.5.5.2
  defp embedded_ipv4({0, 0, 0, 0, 0, 0xFFFF, ab, cd}), do: {:carries, [unfold(ab, cd)]}
  # IPv4-compatible, deprecated — RFC 4291 §2.5.5.1
  defp embedded_ipv4({0, 0, 0, 0, 0, 0, ab, cd}), do: {:carries, [unfold(ab, cd)]}
  # NAT64 well-known prefix 64:ff9b::/96 — RFC 6052 §2.1: the last 32 bits
  defp embedded_ipv4({0x64, 0xFF9B, 0, 0, 0, 0, ab, cd}), do: {:carries, [unfold(ab, cd)]}
  # NAT64 local-use prefix 64:ff9b:1::/48 — RFC 8215. Where the IPv4 address
  # sits depends on the length of the network-specific prefix the operator cut
  # from it (RFC 6052 §2.2), which nothing in the address says, so the address
  # it carries cannot be told and the prefix is refused outright.
  defp embedded_ipv4({0x64, 0xFF9B, 1, _, _, _, _, _}), do: :refuse
  # 6to4 2002::/16 — RFC 3056 §2: bits 16–47
  defp embedded_ipv4({0x2002, ab, cd, _, _, _, _, _}), do: {:carries, [unfold(ab, cd)]}
  # Teredo 2001::/32 — RFC 4380 §4: the server in bits 32–63, the client in the
  # last 32 bits with every bit inverted. Both are addresses the packet reaches.
  defp embedded_ipv4({0x2001, 0, server_ab, server_cd, _, _, client_ab, client_cd}) do
    client = unfold(Bitwise.bxor(client_ab, 0xFFFF), Bitwise.bxor(client_cd, 0xFFFF))
    {:carries, [unfold(server_ab, server_cd), client]}
  end

  defp embedded_ipv4(_ip), do: :native

  defp unfold(ab, cd), do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  defp in_any?(value, width, blocks), do: Enum.any?(blocks, &in_block?(value, width, &1))

  defp in_block?(value, width, {prefix, length}) do
    Bitwise.bsr(value, width - length) == Bitwise.bsr(prefix, width - length)
  end

  defp integer(ip, bits) do
    ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 * Bitwise.bsl(1, bits) + &1))
  end

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
