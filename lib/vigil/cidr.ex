defmodule Vigil.Cidr do
  @moduledoc """
  IP addresses and the blocks they sit in, read one way for the two modules
  that judge an address by its block: `Vigil.OAuth.ClientAddr`, which
  believes a forwarded header only from a trusted proxy's block, and
  `Vigil.OAuth.Cimd`, which fetches a client's metadata only from an address
  outside every special-purpose one.

  A block is `{address, prefix}`: an `:inet` address tuple and how many of its
  leading bits count. Written, it is `10.0.0.0/8` or `2001:db8::/32`, and a
  bare address is its own single-host block.
  """

  import Bitwise

  @typedoc "A network address and how many of its leading bits count."
  @type t :: {:inet.ip_address(), non_neg_integer()}

  @doc """
  The block `text` writes, or `:error`: an address, optionally bracketed, and
  a prefix no longer than the address. Without a prefix, the whole address.
  """
  @spec parse(String.t()) :: {:ok, t} | :error
  def parse(text) when is_binary(text) do
    {address, prefix} =
      case String.split(text, "/", parts: 2) do
        [address] -> {address, nil}
        [address, prefix] -> {address, prefix}
      end

    with {:ok, ip} <- parse_address(address),
         {:ok, prefix} <- prefix(prefix, bit_size(bits(ip))) do
      {:ok, {ip, prefix}}
    end
  end

  defp prefix(nil, width), do: {:ok, width}

  defp prefix(text, width) do
    case Integer.parse(text) do
      {prefix, ""} when prefix in 0..width//1 -> {:ok, prefix}
      _ -> :error
    end
  end

  @doc """
  The one address `text` writes, or `:error`. It may be written `[2001:db8::1]`;
  one with a port is refused rather than guessed at, since `1.2.3.4:5678` and
  `1:2:3:4:5:6:7:8` cannot both be split on a colon.
  """
  @spec parse_address(String.t()) :: {:ok, :inet.ip_address()} | :error
  def parse_address(text) when is_binary(text) do
    text
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Whether `ip` sits inside the block. A family mismatch is never a match: an
  IPv4 block, `0.0.0.0/0` included, says nothing about an IPv6 address — an
  IPv4-mapped one included, which `unmap_v4/1` turns into the IPv4 address
  it carries first where that is what is meant.
  """
  @spec member?(:inet.ip_address(), t) :: boolean()
  def member?(ip, {net, prefix}) when tuple_size(ip) == tuple_size(net) do
    <<subject::bitstring-size(^prefix), _::bitstring>> = bits(ip)
    <<block::bitstring-size(^prefix), _::bitstring>> = bits(net)
    subject == block
  end

  def member?(_ip, _block), do: false

  @doc """
  The IPv4 address an IPv4-mapped IPv6 address carries (`::ffff:198.51.100.9`,
  RFC 4291 §2.5.5.2 — what a dual-stack socket reports for an IPv4 peer), and
  every other address as it is.
  """
  @spec unmap_v4(:inet.ip_address()) :: :inet.ip_address()
  def unmap_v4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  def unmap_v4(ip), do: ip

  defp bits({a, b, c, d}), do: <<a, b, c, d>>

  defp bits({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
end
