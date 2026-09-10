defmodule Vigil.OAuth.ClientAddr do
  @moduledoc """
  The address a rate limit may be keyed on.

  `conn.remote_ip` is the peer of the TCP connection. Behind the proxy
  `docs/guide.md` deploys, that peer is the proxy and not the person at the
  consent form, so every attempt from everywhere lands in one bucket — which
  makes a per-address limit both globally exhaustible and stricter than
  intended.

  The fix is not "read `X-Forwarded-For`". A forwarded header is
  attacker-controlled unless something guarantees otherwise, and believing one
  blindly turns a global limit into no limit at all: every attempt simply
  claims a new address. RFC 9700 §4.13 states the condition that has to hold
  first — "A reverse proxy MUST therefore sanitize any inbound requests to
  ensure the authenticity and integrity of all header values relevant for the
  security of the application servers".

  So this module believes a header only under three conditions, and falls back
  to the peer whenever one of them fails:

    * a header **name** is configured — there is no default header, because a
      guess about the proxy is worse than no opinion about it;
    * the peer is inside the configured set of **trusted** addresses, which is
      empty by default, so a deployment that has not been told about its proxy
      keeps exactly today's behaviour rather than silently getting worse;
    * the header yields an address that is *not* one of ours.

  The last condition is why the walk runs right to left. A proxy tier appends
  what it saw, so the hops it added are the rightmost ones; anything further
  left is a claim that arrived from outside. Taking the leftmost value would
  hand the key straight back to the caller.

  Two deliberate refusals, both of them "fall back to the peer":

    * a hop that is not an address **halts** the walk rather than being
      skipped, because skipping it would let a caller inject garbage to push
      the walk leftward onto a value it chose;
    * when every hop is trusted there is no client hop to find, and the peer —
      which the caller cannot choose — is the answer, not the leftmost claim.

  Both configuration values are also arguments, so a test can state a
  deployment rather than install one.
  """

  require Logger

  @typedoc "A trust anchor: a network address and how many of its leading bits count."
  @type cidr :: {:inet.ip_address(), non_neg_integer()}

  @doc """
  The address to key on for `conn`.

  `:header` is the forwarded header's name (lowercase, as `Plug` stores them)
  or `nil`; `:trusted` is a list from `parse_trusted/1`. Both default to the
  application environment.
  """
  @spec of(Plug.Conn.t(), keyword()) :: String.t()
  def of(conn, opts \\ []) do
    header = Keyword.get_lazy(opts, :header, &configured_header/0)
    trusted = Keyword.get_lazy(opts, :trusted, &configured_trusted/0)

    case forwarded(conn, header, trusted) do
      nil -> format(conn.remote_ip)
      address -> address
    end
  end

  defp forwarded(_conn, nil, _trusted), do: nil
  defp forwarded(_conn, _header, []), do: nil

  defp forwarded(conn, header, trusted) do
    if trusted?(conn.remote_ip, trusted) do
      conn
      |> Plug.Conn.get_req_header(header)
      |> hops()
      |> client_hop(trusted)
    end
  end

  # One header may arrive as several fields, and each field may carry several
  # comma-separated hops. Order is preserved across both: leftmost claim
  # first, nearest proxy last.
  defp hops(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp client_hop(hops, trusted), do: hops |> Enum.reverse() |> walk(trusted)

  defp walk([], _trusted), do: nil

  defp walk([hop | further_left], trusted) do
    case parse_address(hop) do
      {:ok, addr} ->
        if trusted?(addr, trusted), do: walk(further_left, trusted), else: format(addr)

      :error ->
        nil
    end
  end

  @doc """
  The deployment's proxy configuration, resolved once for a caller that will
  reuse it across requests — `Vigil.OAuth.Endpoint.init/1` does.

  Passing the result back as `of/2`'s options is the same thing `of/2` would
  have worked out for itself; it just stops the CIDR list being parsed again
  on every request.
  """
  @spec config() :: keyword()
  def config, do: [header: configured_header(), trusted: configured_trusted()]

  @doc """
  Parses trust anchors — `"10.0.0.0/8"`, `"2001:db8::/32"`, or a bare address,
  which is its own single-host prefix.

  A malformed entry is dropped with a warning rather than failing the boot or,
  worse, being treated as a match: a deployment with one typo in the list
  should lose that one anchor, not gain a wildcard.
  """
  @spec parse_trusted([String.t()]) :: [cidr()]
  def parse_trusted(entries) when is_list(entries), do: Enum.flat_map(entries, &parse_cidr/1)

  defp parse_cidr(entry) do
    {address, prefix} =
      case String.split(entry, "/", parts: 2) do
        [address] -> {address, nil}
        [address, prefix] -> {address, prefix}
      end

    with {:ok, addr} <- parse_address(address),
         {:ok, bits} <- prefix_bits(prefix, bit_size(bits(addr))) do
      [{addr, bits}]
    else
      :error ->
        Logger.warning("ignoring unparseable trusted proxy entry: #{inspect(entry)}")
        []
    end
  end

  defp prefix_bits(nil, width), do: {:ok, width}

  defp prefix_bits(prefix, width) do
    case Integer.parse(prefix) do
      {bits, ""} when bits >= 0 and bits <= width -> {:ok, bits}
      _ -> :error
    end
  end

  # A hop may be written `[2001:db8::1]`; a hop with a port is not understood
  # and is refused by `:inet.parse_address/1` rather than guessed at, since
  # `1.2.3.4:5678` and `1:2:3:4:5:6:7:8` cannot both be split on a colon.
  defp parse_address(text) do
    text
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, addr} -> {:ok, addr}
      {:error, _reason} -> :error
    end
  end

  defp trusted?(addr, trusted), do: Enum.any?(trusted, &within?(addr, &1))

  # A family mismatch is never a match: an IPv4 anchor, `0.0.0.0/0` included,
  # says nothing about an IPv6 peer.
  defp within?(addr, {net, prefix}) when tuple_size(addr) == tuple_size(net) do
    <<subject::bitstring-size(^prefix), _::bitstring>> = bits(addr)
    <<anchor::bitstring-size(^prefix), _::bitstring>> = bits(net)
    subject == anchor
  end

  defp within?(_addr, _cidr), do: false

  defp bits({a, b, c, d}), do: <<a, b, c, d>>

  defp bits({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  defp format(addr), do: addr |> :inet.ntoa() |> List.to_string()

  defp configured_header do
    case Application.get_env(:vigil, :trusted_proxy_header) do
      name when is_binary(name) and name != "" -> String.downcase(name)
      _ -> nil
    end
  end

  defp configured_trusted do
    case Application.get_env(:vigil, :trusted_proxies, []) do
      entries when is_list(entries) -> parse_trusted(entries)
      _ -> []
    end
  end
end
