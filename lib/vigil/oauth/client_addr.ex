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

  What comes back is a **key**, not always a single host. An IPv4 address is
  its own key. An IPv6 address is keyed by the /64 it sits in, written
  `2001:db8:1:2::/64`: a /64 is what one subscriber line or one server is
  handed, so a caller holding one has 2^64 addresses to rotate through, and a
  key per /128 would hand it a fresh budget per request. An IPv4 address
  carried in IPv6 (`::ffff:198.51.100.9`, what a dual-stack socket reports for
  an IPv4 peer) is keyed as the IPv4 address it is — as a /64 it would share
  one bucket with every IPv4 client there is.

  Both configuration values are also arguments, so a test can state a
  deployment rather than install one.
  """

  require Logger

  alias Vigil.Cidr

  @typedoc "A trust anchor: a network address and how many of its leading bits count."
  @type cidr :: Cidr.t()

  @doc """
  The key to count `conn` under: its address, or its /64 for IPv6.

  `:header` is the forwarded header's name (lowercase, as `Plug` stores them)
  or `nil`; `:trusted` is a list from `parse_trusted/1`. Both default to the
  application environment.
  """
  @spec of(Plug.Conn.t(), keyword()) :: String.t()
  def of(conn, opts \\ []) do
    header = Keyword.get_lazy(opts, :header, &configured_header/0)
    trusted = Keyword.get_lazy(opts, :trusted, &configured_trusted/0)

    case forwarded(conn, header, trusted) do
      nil -> key(conn.remote_ip)
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
    case Cidr.parse_address(hop) do
      {:ok, addr} ->
        if trusted?(addr, trusted), do: walk(further_left, trusted), else: key(addr)

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

  A deployment never gets here with a malformed entry: `Vigil.Settings.Check`
  refuses it at boot, naming it, because losing the one anchor would key
  every request on the proxy's own address. For a caller outside the
  supervision tree, one is dropped with a warning rather than treated as a
  match: a typo should lose that one anchor, not gain a wildcard.
  """
  @spec parse_trusted([String.t()]) :: [cidr()]
  def parse_trusted(entries) when is_list(entries), do: Enum.flat_map(entries, &parse_cidr/1)

  defp parse_cidr(entry) do
    case Cidr.parse(entry) do
      {:ok, cidr} ->
        [cidr]

      :error ->
        Logger.warning("ignoring unparseable trusted proxy entry: #{inspect(entry)}")
        []
    end
  end

  defp trusted?(addr, trusted), do: Enum.any?(trusted, &Cidr.member?(addr, &1))

  # The one place an address becomes the key it is counted under. The mapped
  # form is unwrapped before the /64 is taken, since `::ffff:0:0/96` sits
  # inside `::/64`.
  defp key(addr) do
    case Cidr.unmap_v4(addr) do
      {a, b, c, d, _e, _f, _g, _h} -> format({a, b, c, d, 0, 0, 0, 0}) <> "/64"
      ipv4 -> format(ipv4)
    end
  end

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
