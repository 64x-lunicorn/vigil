defmodule Vigil.OAuth.ClientAddrTest do
  @moduledoc """
  The address a rate limit may be keyed on.

  Every test states the peer explicitly: `conn.remote_ip` is what vigil sees
  without configuration, and the point of the module is when it may be
  overruled by a header and when it may not.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Vigil.OAuth.ClientAddr

  defp conn_from(peer, headers \\ []) do
    Enum.reduce(headers, %{conn(:get, "/") | remote_ip: peer}, fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
  end

  # One trust anchor for every test that needs one: the proxy tier itself
  # (203.0.113.0/24) plus a private hop behind it (10.0.0.0/8). Peers outside
  # both — 192.0.2.5, 198.51.100.9 — are somebody else.
  defp trusted, do: ClientAddr.parse_trusted(["203.0.113.0/24", "10.0.0.0/8"])

  describe "with nothing configured" do
    test "the peer of the TCP connection is the address" do
      conn = conn_from({203, 0, 113, 7})
      assert ClientAddr.of(conn, header: nil, trusted: []) == "203.0.113.7"
    end

    test "a forwarded header is not read at all" do
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "198.51.100.9"}])
      assert ClientAddr.of(conn, header: nil, trusted: []) == "203.0.113.7"
    end

    test "an IPv6 peer is formatted as IPv6" do
      conn = conn_from({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert ClientAddr.of(conn, header: nil, trusted: []) == "2001:db8::1"
    end
  end

  describe "with a header named but no trusted peer" do
    test "the header is still not believed — a name alone is not a trust anchor" do
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "198.51.100.9"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: []) == "203.0.113.7"
    end
  end

  describe "with a trusted peer" do
    test "the header from a trusted peer is the client" do
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "198.51.100.9"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "198.51.100.9"
    end

    test "the same header from an untrusted peer is not believed" do
      conn = conn_from({192, 0, 2, 5}, [{"x-forwarded-for", "198.51.100.9"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "192.0.2.5"
    end

    test "a trusted peer that sends no header falls back to the peer" do
      conn = conn_from({203, 0, 113, 7})
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "203.0.113.7"
    end

    test "a single-address header such as CF-Connecting-IP works the same way" do
      conn = conn_from({203, 0, 113, 7}, [{"cf-connecting-ip", "198.51.100.9"}])
      assert ClientAddr.of(conn, header: "cf-connecting-ip", trusted: trusted()) == "198.51.100.9"
    end
  end

  describe "several hops" do
    test "the rightmost untrusted hop wins, not the leftmost claim" do
      # The client claimed 1.2.3.4; the proxies appended what they actually
      # saw. 198.51.100.9 is the last hop we did not put there ourselves.
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "1.2.3.4, 198.51.100.9, 10.0.0.6"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "198.51.100.9"
    end

    test "a header split across repeated fields is one list" do
      conn =
        conn(:get, "/")
        |> Map.put(:remote_ip, {203, 0, 113, 7})
        |> put_req_header("x-forwarded-for", "1.2.3.4")

      conn = %{conn | req_headers: conn.req_headers ++ [{"x-forwarded-for", "198.51.100.9"}]}

      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "198.51.100.9"
    end

    test "when every hop is trusted the peer wins, not the leftmost claim" do
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "10.0.0.5, 10.0.0.6"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "203.0.113.7"
    end

    test "a hop that is not an address halts the walk rather than being skipped" do
      # Skipping it would let a client push the walk leftward onto a value it
      # chose. Halting falls back to the peer, which it cannot choose.
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "1.2.3.4, not-an-address"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "203.0.113.7"
    end

    test "an empty header falls back to the peer" do
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "   "}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "203.0.113.7"
    end

    test "a bracketed IPv6 hop is understood" do
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "[2001:db8::9]"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "2001:db8::9"
    end

    test "a hop carrying a port is refused rather than guessed at" do
      conn = conn_from({203, 0, 113, 7}, [{"x-forwarded-for", "198.51.100.9:41234"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted()) == "203.0.113.7"
    end
  end

  describe "parse_trusted/1" do
    test "a bare address is its own /32" do
      trusted = ClientAddr.parse_trusted(["198.51.100.9"])
      conn = conn_from({198, 51, 100, 9}, [{"x-forwarded-for", "1.2.3.4"}])
      assert ClientAddr.of(conn, header: "x-forwarded-for", trusted: trusted) == "1.2.3.4"

      neighbour = conn_from({198, 51, 100, 10}, [{"x-forwarded-for", "1.2.3.4"}])

      assert ClientAddr.of(neighbour, header: "x-forwarded-for", trusted: trusted) ==
               "198.51.100.10"
    end

    test "an IPv6 prefix matches inside its range and not outside it" do
      trusted = ClientAddr.parse_trusted(["2001:db8::/32"])
      inside = conn_from({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, [{"cf-connecting-ip", "1.2.3.4"}])
      assert ClientAddr.of(inside, header: "cf-connecting-ip", trusted: trusted) == "1.2.3.4"

      outside = conn_from({0x2001, 0xDB9, 0, 0, 0, 0, 0, 1}, [{"cf-connecting-ip", "1.2.3.4"}])
      assert ClientAddr.of(outside, header: "cf-connecting-ip", trusted: trusted) == "2001:db9::1"
    end

    test "an IPv4 prefix never matches an IPv6 peer" do
      trusted = ClientAddr.parse_trusted(["0.0.0.0/0"])
      conn = conn_from({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, [{"cf-connecting-ip", "1.2.3.4"}])
      assert ClientAddr.of(conn, header: "cf-connecting-ip", trusted: trusted) == "2001:db8::1"
    end

    test "a malformed entry is dropped rather than trusted" do
      assert ClientAddr.parse_trusted(["not-a-cidr"]) == []
      assert ClientAddr.parse_trusted(["10.0.0.0/33"]) == []
      assert ClientAddr.parse_trusted(["10.0.0.0/-1"]) == []
      assert ClientAddr.parse_trusted(["2001:db8::/129"]) == []
      assert ClientAddr.parse_trusted([""]) == []
    end

    test "the good entries of a mixed list survive" do
      assert length(ClientAddr.parse_trusted(["not-a-cidr", "10.0.0.0/8"])) == 1
    end
  end
end
