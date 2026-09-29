defmodule Vigil.OAuth.CimdTest do
  @moduledoc """
  The CIMD fetch is the only place vigil makes an outbound request to an
  address an untrusted party chooses. Every test here drives it through a
  fake `net`, so the suite exercises the guard rather than the internet.
  """

  use ExUnit.Case, async: true

  alias Vigil.OAuth.Cimd

  @url "https://client.example.org/metadata.json"
  @public {93, 184, 216, 34}
  @loopback {127, 0, 0, 1}
  @now 1_700_000_000

  setup do
    Vigil.OAuthCase.setup!()
  end

  ## Fake net

  # Records every call on the test process, so a test can assert on what the
  # fetch did *not* do as easily as on what it did. Each queue repeats its
  # last entry, so a test only lists the answers it actually cares about.
  defp net(opts) do
    responses = Keyword.get(opts, :responses, [{:ok, Keyword.get(opts, :body, document(%{}))}])
    addresses = Keyword.get(opts, :addresses, [{:ok, @public}])
    test = self()

    {:ok, response_queue} = Agent.start_link(fn -> responses end)
    {:ok, address_queue} = Agent.start_link(fn -> addresses end)

    %{
      request: fn uri, ip ->
        send(test, {:request, URI.to_string(uri), ip})
        Agent.get_and_update(response_queue, &next/1)
      end,
      resolve: fn host, family ->
        send(test, {:resolve, List.to_string(host), family})
        Agent.get_and_update(address_queue, &next/1)
      end
    }
  end

  defp next([last]), do: {last, [last]}
  defp next([head | tail]), do: {head, tail}

  defp document(overrides) do
    %{
      "client_id" => @url,
      "client_name" => "Example",
      "redirect_uris" => ["https://client.example.org/cb"]
    }
    |> Map.merge(Map.new(overrides))
    |> Jason.encode!()
  end

  # Drives `fetch` against a host whose only resolved address is `ip`.
  defp fetch_resolving_to(persistence, ip) do
    Cimd.fetch(persistence, @url, @now, net(addresses: [{:ok, ip}]))
  end

  ## The happy path

  test "a valid document becomes a client, and the fetch resolves before it requests", %{
    persistence: persistence
  } do
    assert {:ok, doc} = Cimd.fetch(persistence, @url, @now, net([]))

    assert doc == %{
             client_id: @url,
             name: "Example",
             redirect_uris: ["https://client.example.org/cb"]
           }

    assert_received {:resolve, "client.example.org", :inet}
    assert_received {:request, @url, @public}
  end

  test "a document without client_name is refused rather than defaulted to the URL", %{
    persistence: persistence
  } do
    # `fetch` reads client_name with a default, but validation requires it, so
    # the default is unreachable. Pinned here so removing either is visible.
    assert :error =
             Cimd.fetch(persistence, @url, @now, net(body: document(%{"client_name" => nil})))
  end

  ## The URL

  test "a non-https client_id is refused without resolving or requesting", %{
    persistence: persistence
  } do
    assert :error =
             Cimd.fetch(persistence, "http://client.example.org/metadata.json", @now, net([]))

    refute_received {:resolve, _, _}
    refute_received {:request, _, _}
  end

  test "an https URL without a host is refused", %{persistence: persistence} do
    assert :error = Cimd.fetch(persistence, "https:///metadata.json", @now, net([]))
    refute_received {:request, _, _}
  end

  ## One resolution, not two

  test "the address the guard checked is the address the request is given", %{
    persistence: persistence
  } do
    assert {:ok, _doc} = Cimd.fetch(persistence, @url, @now, net([]))
    assert_received {:request, @url, @public}
  end

  test "a host answering public and then loopback never reaches the loopback address", %{
    persistence: persistence
  } do
    # DNS rebinding: the attacker controls the host's DNS and answers the
    # guard's lookup with a public address and the connection's lookup with
    # 127.0.0.1. There is only one lookup now, so the second answer is never
    # asked for — and the request carries the address that was checked.
    net = net(addresses: [{:ok, @public}, {:ok, @loopback}])

    assert {:ok, _doc} = Cimd.fetch(persistence, @url, @now, net)

    assert_received {:resolve, "client.example.org", :inet}
    refute_received {:resolve, _, _}

    assert_received {:request, @url, @public}
    refute_received {:request, _, @loopback}
  end

  ## The SSRF guard

  test "a host resolving to a private address is refused without requesting", %{
    persistence: persistence
  } do
    assert :error = fetch_resolving_to(persistence, @loopback)
    assert_received {:resolve, "client.example.org", :inet}
    refute_received {:request, _, _}
  end

  test "a host with no A record is retried as AAAA", %{persistence: persistence} do
    net = net(addresses: [{:error, :nxdomain}, {:ok, {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}}])
    assert {:ok, _doc} = Cimd.fetch(persistence, @url, @now, net)

    assert_received {:resolve, "client.example.org", :inet}
    assert_received {:resolve, "client.example.org", :inet6}
  end

  test "a host that resolves in neither family is refused", %{persistence: persistence} do
    assert :error = Cimd.fetch(persistence, @url, @now, net(addresses: [{:error, :nxdomain}]))
    refute_received {:request, _, _}
  end

  test "a resolver that does not answer makes the fetch fail within the timeout", %{
    persistence: persistence
  } do
    net = %{
      net([])
      | resolve: fn _host, _family -> Process.sleep(:infinity) end
    }

    net = Map.put(net, :resolve_timeout, 100)

    {elapsed, result} =
      :timer.tc(fn -> Cimd.fetch(persistence, @url, @now, net) end, :millisecond)

    assert result == :error
    assert elapsed < 1_000
    refute_received {:request, _, _}
  end

  test "the resolution is bounded by the same 5 s the request is" do
    assert Cimd.net().resolve_timeout == 5_000
  end

  ## The ranges the guard refuses

  # Every entry of the IANA IPv4 Special-Purpose Address Registry, and
  # multicast, which has a registry of its own.
  @ipv4_special [
    "0.0.0.0/8",
    "0.0.0.0/32",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.0.0/29",
    "192.0.0.8/32",
    "192.0.0.9/32",
    "192.0.0.10/32",
    "192.0.0.170/31",
    "192.0.2.0/24",
    "192.31.196.0/24",
    "192.52.193.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "192.175.48.0/24",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
    "255.255.255.255/32"
  ]

  # Every entry of the IANA IPv6 Special-Purpose Address Registry. The
  # translation and tunnel prefixes are refused here through the IPv4 address
  # at each end of the block — 0.0.0.0 and 255.255.255.255 — which is what
  # they carry; a public one is the test further down.
  @ipv6_special [
    "::1/128",
    "::/128",
    "::ffff:0:0/96",
    "64:ff9b::/96",
    "64:ff9b:1::/48",
    "100::/64",
    "100:0:0:1::/64",
    "2001::/23",
    "2001::/32",
    "2001:1::1/128",
    "2001:1::2/128",
    "2001:1::3/128",
    "2001:2::/48",
    "2001:3::/32",
    "2001:4:112::/48",
    "2001:10::/28",
    "2001:20::/28",
    "2001:30::/28",
    "2001:db8::/32",
    "2002::/16",
    "2620:4f:8000::/48",
    "3fff::/20",
    "5f00::/16",
    "fc00::/7",
    "fe80::/10"
  ]

  # The first and the last address of a block, worked out here rather than
  # asked of the guard.
  defp edges(block) do
    [address, length] = String.split(block, "/")
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))
    {bits, width} = if tuple_size(ip) == 4, do: {8, 32}, else: {16, 128}
    value = ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 * Bitwise.bsl(1, bits) + &1))
    host_bits = width - String.to_integer(length)
    last = Bitwise.bor(value, Bitwise.bsl(1, host_bits) - 1)
    [value, last] |> Enum.map(&to_tuple(&1, bits, div(width, bits))) |> Enum.uniq()
  end

  defp to_tuple(value, bits, count) do
    for(
      i <- (count - 1)..0//-1,
      do: Bitwise.band(Bitwise.bsr(value, i * bits), Bitwise.bsl(1, bits) - 1)
    )
    |> List.to_tuple()
  end

  test "every IANA special-purpose IPv4 block is refused, at both of its edges", %{
    persistence: persistence
  } do
    for block <- @ipv4_special, ip <- edges(block) do
      assert :error = fetch_resolving_to(persistence, ip),
             "#{:inet.ntoa(ip)} in #{block} was not refused"
    end
  end

  test "every IANA special-purpose IPv6 block is refused, at both of its edges", %{
    persistence: persistence
  } do
    for block <- @ipv6_special, ip <- edges(block) do
      assert :error = fetch_resolving_to(persistence, ip),
             "#{:inet.ntoa(ip)} in #{block} was not refused"
    end
  end

  test "an address just outside a special-purpose IPv4 block stays reachable", %{
    persistence: persistence
  } do
    for {label, ip} <- [
          {"1.0.0.0 is not 0.0.0.0/8", {1, 0, 0, 1}},
          {"100.63.x is below the CGNAT range", {100, 63, 255, 254}},
          {"100.128.x is above the CGNAT range", {100, 128, 0, 1}},
          {"192.0.1.x is between 192.0.0.0/24 and TEST-NET-1", {192, 0, 1, 1}},
          {"192.0.3.x is above TEST-NET-1", {192, 0, 3, 1}},
          {"198.17.x is below the benchmarking range", {198, 17, 255, 254}},
          {"198.20.x is above the benchmarking range", {198, 20, 0, 1}},
          {"203.0.112.x is below TEST-NET-3", {203, 0, 112, 1}},
          {"223.x is below the multicast range", {223, 255, 255, 254}}
        ] do
      assert {:ok, _doc} = fetch_resolving_to(persistence, ip), "#{label} was refused"
    end
  end

  test "an IPv6 address outside global unicast 2000::/3 is refused", %{
    persistence: persistence
  } do
    for {label, ip} <- [
          {"1fff:ffff:... is below 2000::/3", {0x1FFF, 0xFFFF, 0, 0, 0, 0, 0, 1}},
          {"4000::1 is above 2000::/3", {0x4000, 0, 0, 0, 0, 0, 0, 1}},
          {"fec0::1 (site-local, deprecated)", {0xFEC0, 0, 0, 0, 0, 0, 0, 1}},
          {"ff02::1 (multicast)", {0xFF02, 0, 0, 0, 0, 0, 0, 1}},
          {"ff0e::1 (global multicast)", {0xFF0E, 0, 0, 0, 0, 0, 0, 1}}
        ] do
      assert :error = fetch_resolving_to(persistence, ip), "#{label} was not refused"
    end
  end

  test "a global unicast IPv6 address just outside a special-purpose block stays reachable",
       %{persistence: persistence} do
    for {label, ip} <- [
          {"2001:200::1 is above 2001::/23", {0x2001, 0x0200, 0, 0, 0, 0, 0, 1}},
          {"2001:db9::1 is above 2001:db8::/32", {0x2001, 0x0DB9, 0, 0, 0, 0, 0, 1}},
          {"2003::1 is above 6to4", {0x2003, 0, 0, 0, 0, 0, 0, 1}},
          {"3fff:1000::1 is above 3fff::/20", {0x3FFF, 0x1000, 0, 0, 0, 0, 0, 1}},
          {"2606:2800::1", {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}}
        ] do
      assert {:ok, _doc} = fetch_resolving_to(persistence, ip), "#{label} was refused"
    end
  end

  ## Addresses that carry an IPv4 address

  test "an address that embeds a private IPv4 address is refused", %{persistence: persistence} do
    for {label, ip} <- [
          {"64:ff9b::10.0.0.1 (NAT64)", {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001}},
          {"64:ff9b::127.0.0.1 (NAT64)", {0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001}},
          {"64:ff9b::169.254.169.254 (NAT64)", {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE}},
          {"2002:c0a8:101:: (6to4 of 192.168.1.1)", {0x2002, 0xC0A8, 0x0101, 0, 0, 0, 0, 1}},
          {"2002:7f00:1:: (6to4 of 127.0.0.1)", {0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0}},
          # Teredo: server 93.184.216.34, client 10.0.0.1 inverted to f5ff:fffe
          {"Teredo with a private client", {0x2001, 0, 0x5DB8, 0xD822, 0, 0, 0xF5FF, 0xFFFE}},
          # Teredo: server 10.0.0.1, client 93.184.216.34 inverted to a247:27dd
          {"Teredo with a private server", {0x2001, 0, 0x0A00, 0x0001, 0, 0, 0xA247, 0x27DD}}
        ] do
      assert :error = fetch_resolving_to(persistence, ip), "#{label} was not refused"
    end
  end

  test "an address that embeds a public IPv4 address stays reachable", %{
    persistence: persistence
  } do
    for {label, ip} <- [
          {"64:ff9b::93.184.216.34 (NAT64)", {0x64, 0xFF9B, 0, 0, 0, 0, 0x5DB8, 0xD822}},
          {"2002:5db8:d822::1 (6to4)", {0x2002, 0x5DB8, 0xD822, 0, 0, 0, 0, 1}},
          # Teredo: server 93.184.216.34, client 8.8.8.8 inverted to f7f7:f7f7.
          # Read without the inversion the client would be 247.247.247.247,
          # inside 240.0.0.0/4, and this would be refused.
          {"Teredo, public both ends", {0x2001, 0, 0x5DB8, 0xD822, 0, 0, 0xF7F7, 0xF7F7}}
        ] do
      assert {:ok, _doc} = fetch_resolving_to(persistence, ip), "#{label} was refused"
    end
  end

  test "the NAT64 local-use prefix is refused even around a public address", %{
    persistence: persistence
  } do
    # Where the IPv4 address sits in 64:ff9b:1::/48 depends on a prefix length
    # the address does not carry, so there is no address to check.
    assert :error =
             fetch_resolving_to(persistence, {0x64, 0xFF9B, 1, 0, 0, 0, 0x5DB8, 0xD822})
  end

  test "an IPv4-mapped IPv6 address is unfolded before the ranges are checked", %{
    persistence: persistence
  } do
    # ::ffff:127.0.0.1 arrives as an eight-element tuple matching neither the
    # IPv6 loopback clause nor fc00::/7, and used to fall through to "public".
    for {label, ip} <- [
          {"::ffff:127.0.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}},
          {"::ffff:10.0.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}},
          {"::ffff:169.254.169.254", {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}},
          {"::ffff:192.168.1.1", {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101}},
          {"::ffff:172.16.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0xAC10, 0x0001}},
          {"::ffff:100.64.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0x6440, 0x0001}},
          {"::ffff:0.0.0.0", {0, 0, 0, 0, 0, 0xFFFF, 0x0000, 0x0000}},
          {"::ffff:198.18.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0xC612, 0x0001}},
          {"::ffff:224.0.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0xE000, 0x0001}},
          {"::ffff:255.255.255.255", {0, 0, 0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF}}
        ] do
      assert :error = fetch_resolving_to(persistence, ip), "#{label} was not refused"
    end
  end

  test "an IPv4-mapped public address stays reachable", %{persistence: persistence} do
    # 93.184.216.34 mapped: the unfolding must not refuse everything it touches.
    assert {:ok, _doc} = fetch_resolving_to(persistence, {0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
  end

  test "an IPv4-compatible IPv6 address is unfolded before the ranges are checked", %{
    persistence: persistence
  } do
    # ::127.0.0.1 is the deprecated IPv4-compatible form: no 0xffff in the sixth
    # group, so the mapped clause does not catch it, and it is neither :: nor ::1.
    for {label, ip} <- [
          {"::127.0.0.1", {0, 0, 0, 0, 0, 0, 0x7F00, 0x0001}},
          {"::10.0.0.1", {0, 0, 0, 0, 0, 0, 0x0A00, 0x0001}},
          {"::169.254.169.254", {0, 0, 0, 0, 0, 0, 0xA9FE, 0xA9FE}},
          {"::192.168.1.1", {0, 0, 0, 0, 0, 0, 0xC0A8, 0x0101}},
          {"::172.16.0.1", {0, 0, 0, 0, 0, 0, 0xAC10, 0x0001}},
          {"::100.64.0.1", {0, 0, 0, 0, 0, 0, 0x6440, 0x0001}},
          {"::198.18.0.1", {0, 0, 0, 0, 0, 0, 0xC612, 0x0001}},
          {"::224.0.0.1", {0, 0, 0, 0, 0, 0, 0xE000, 0x0001}},
          {"::255.255.255.255", {0, 0, 0, 0, 0, 0, 0xFFFF, 0xFFFF}}
        ] do
      assert :error = fetch_resolving_to(persistence, ip), "#{label} was not refused"
    end
  end

  test "an IPv4-compatible public address stays reachable", %{persistence: persistence} do
    # 93.184.216.34 in the compatible form, for the same reason as the mapped one.
    assert {:ok, _doc} = fetch_resolving_to(persistence, {0, 0, 0, 0, 0, 0, 0x5DB8, 0xD822})
  end

  ## The response

  test "a non-200 response is refused", %{persistence: persistence} do
    assert :error = Cimd.fetch(persistence, @url, @now, net(responses: [:error]))
    assert_received {:request, @url, @public}
  end

  test "a body over the size cap is refused even when the request hands one back", %{
    persistence: persistence
  } do
    # The cap belongs to the fetch, not to one implementation of the request:
    # `net.request` is a seam, and nothing behind it may return an unbounded
    # body. `read_capped/2` enforces the same bound during the read.
    oversized = document(%{"client_name" => String.duplicate("a", 65_537)})
    assert :error = Cimd.fetch(persistence, @url, @now, net(body: oversized))
  end

  test "a body that is not JSON is refused", %{persistence: persistence} do
    assert :error = Cimd.fetch(persistence, @url, @now, net(body: "not json"))
  end

  ## Document validation

  test "a document whose client_id is not the URL it came from is refused", %{
    persistence: persistence
  } do
    net = net(body: document(%{"client_id" => "https://other.example.org/metadata.json"}))
    assert :error = Cimd.fetch(persistence, @url, @now, net)
  end

  test "a document without a client_id is refused", %{persistence: persistence} do
    body = ~s({"client_name": "Example", "redirect_uris": ["https://client.example.org/cb"]})
    assert :error = Cimd.fetch(persistence, @url, @now, net(body: body))
  end

  test "a document whose client_name is not a string is refused", %{persistence: persistence} do
    assert :error =
             Cimd.fetch(persistence, @url, @now, net(body: document(%{"client_name" => 42})))
  end

  test "a document whose redirect_uris is not a list is refused", %{persistence: persistence} do
    net = net(body: document(%{"redirect_uris" => "https://client.example.org/cb"}))
    assert :error = Cimd.fetch(persistence, @url, @now, net)
  end

  test "a document whose redirect_uris is empty is refused", %{persistence: persistence} do
    assert :error =
             Cimd.fetch(
               persistence,
               @url,
               @now,
               net(body: document(%{"redirect_uris" => []}))
             )
  end

  test "a document with a redirect_uri that registration would refuse is refused", %{
    persistence: persistence
  } do
    net = net(body: document(%{"redirect_uris" => ["http://evil.example.org/cb"]}))
    assert :error = Cimd.fetch(persistence, @url, @now, net)
  end

  # The document is JSON from an address the client chose, so a redirect URI
  # can be anything JSON can say. What is not a string is invalid metadata,
  # refused like the rest, never a crash on the way to a consent page.
  test "a document with a redirect_uri that is not a string is refused", %{
    persistence: persistence
  } do
    for uri <- [42, nil, %{"uri" => "https://client.example.org/cb"}, ["x"]] do
      net = net(body: document(%{"redirect_uris" => ["https://client.example.org/cb", uri]}))
      assert :error = Cimd.fetch(persistence, @url, @now, net)
    end
  end

  test "a loopback redirect_uri is accepted, as it is at registration", %{
    persistence: persistence
  } do
    net = net(body: document(%{"redirect_uris" => ["http://127.0.0.1/cb"]}))

    assert {:ok, %{redirect_uris: ["http://127.0.0.1/cb"]}} =
             Cimd.fetch(persistence, @url, @now, net)
  end

  ## The cache

  test "a second fetch inside the hour is answered from the cache without requesting", %{
    persistence: persistence
  } do
    assert {:ok, doc} = Cimd.fetch(persistence, @url, @now, net([]))
    assert_received {:resolve, _, _}
    assert_received {:request, @url, @public}

    assert {:ok, ^doc} = Cimd.fetch(persistence, @url, @now + 3599, net([]))
    refute_received {:request, _, _}
    refute_received {:resolve, _, _}
  end

  test "a fetch after the hour has elapsed requests again", %{persistence: persistence} do
    assert {:ok, _doc} = Cimd.fetch(persistence, @url, @now, net([]))
    assert_received {:request, @url, @public}

    assert {:ok, _doc} = Cimd.fetch(persistence, @url, @now + 3601, net([]))
    assert_received {:request, @url, @public}
  end

  test "a refused document is not cached", %{persistence: persistence} do
    assert :error = Cimd.fetch(persistence, @url, @now, net(responses: [:error]))
    assert {:ok, _doc} = Cimd.fetch(persistence, @url, @now, net([]))
    assert_received {:request, @url, @public}
    assert_received {:request, @url, @public}
  end

  ## The capped read

  describe "read_capped/2" do
    defp cancel_to_test do
      test = self()
      fn ref -> send(test, {:cancelled, ref}) end
    end

    # `:httpc` delivers a streamed response as {:http, {ref, tag, payload}}.
    defp stream(ref, messages) do
      for {tag, payload} <- messages, do: send(self(), {:http, {ref, tag, payload}})
    end

    test "a body under the cap is returned whole" do
      ref = make_ref()
      stream(ref, [{:stream_start, []}, {:stream, "abc"}, {:stream, "def"}, {:stream_end, []}])

      assert {:ok, "abcdef"} = Cimd.read_capped(ref, cancel_to_test())
      refute_received {:cancelled, _}
    end

    test "a declared content-length over the cap is refused before a byte of body is read" do
      ref = make_ref()
      headers = [{~c"content-length", ~c"65537"}]

      # The body that follows is *under* the cap. An implementation that read
      # it and then measured would answer {:ok, "small"}; refusing on the
      # declared length is the only way to reach :error here.
      stream(ref, [{:stream_start, headers}, {:stream, "small"}, {:stream_end, []}])

      assert :error = Cimd.read_capped(ref, cancel_to_test())
      assert_received {:cancelled, ^ref}
    end

    test "a refusal leaves no :httpc messages behind in the mailbox" do
      ref = make_ref()
      chunk = String.duplicate("a", 32_768)

      stream(ref, [
        {:stream_start, []},
        {:stream, chunk},
        {:stream, chunk},
        {:stream, chunk},
        {:stream_end, []}
      ])

      assert :error = Cimd.read_capped(ref, cancel_to_test())

      # cancel_request/1 is asynchronous, so what was already in flight still
      # arrives. Left queued it would accumulate in a connection process that
      # serves more than one request.
      refute_received {:http, {^ref, _}}
      refute_received {:http, {^ref, _, _}}
    end

    test "a declared content-length at the cap is read" do
      ref = make_ref()
      body = String.duplicate("a", 65_536)
      headers = [{~c"content-length", ~c"65536"}]
      stream(ref, [{:stream_start, headers}, {:stream, body}, {:stream_end, []}])

      assert {:ok, ^body} = Cimd.read_capped(ref, cancel_to_test())
    end

    test "a body that crosses the cap mid-stream is refused and the request cancelled" do
      ref = make_ref()
      chunk = String.duplicate("a", 32_768)

      # No content-length: the server never declared a size, so the cap can
      # only be enforced by counting what arrives.
      stream(ref, [
        {:stream_start, []},
        {:stream, chunk},
        {:stream, chunk},
        {:stream, chunk},
        {:stream_end, []}
      ])

      assert :error = Cimd.read_capped(ref, cancel_to_test())

      # `cancel` is only reached from the size check inside the read loop:
      # arriving at stream_end returns {:ok, body} whatever the size. So a
      # cancellation here is proof the cap was enforced during the read rather
      # than measured after it.
      assert_received {:cancelled, ^ref}
    end

    test "a 206 is refused: the fetch asked for no range" do
      ref = make_ref()
      headers = [{~c"content-range", ~c"bytes 0-99/100000"}]
      stream(ref, [{:stream_start, headers}, {:stream, "partial"}, {:stream_end, []}])

      assert :error = Cimd.read_capped(ref, cancel_to_test())
      assert_received {:cancelled, ^ref}
    end

    test "a non-200 response is refused" do
      ref = make_ref()
      send(self(), {:http, {ref, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], "nope"}}})

      assert :error = Cimd.read_capped(ref, cancel_to_test())
    end

    test "a transport error is refused" do
      ref = make_ref()
      send(self(), {:http, {ref, {:error, :socket_closed_remotely}}})

      assert :error = Cimd.read_capped(ref, cancel_to_test())
    end
  end

  ## The pinned connection

  describe "request_for/2" do
    # Every `fetch` test above swaps in a fake request, so those only prove the
    # guard *hands the address on*. This is the other half: what the production
    # request actually does with it.

    defp request_for(url, ip) do
      {connect_url, headers} = Cimd.request_for(URI.parse(url), ip)

      {List.to_string(connect_url),
       Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)}
    end

    test "the URL names the checked address and never the host" do
      {url, _headers} = request_for(@url, @public)

      assert url == "https://93.184.216.34:443/metadata.json"
      refute url =~ "client.example.org"
    end

    test "the host travels as the Host header instead" do
      {_url, headers} = request_for(@url, @public)

      assert {"host", "client.example.org"} in headers
    end

    test "an IPv6 address is bracketed before it can carry a port" do
      {url, _headers} = request_for(@url, {0x2606, 0x2800, 0, 0, 0, 0, 0, 1})

      assert url == "https://[2606:2800::1]:443/metadata.json"
    end

    test "the path and the query survive the rewrite" do
      {url, _headers} = request_for("https://client.example.org/a/b.json?x=1&y=2", @public)

      assert url == "https://93.184.216.34:443/a/b.json?x=1&y=2"
    end

    test "a URL with no path still names one" do
      {url, _headers} = request_for("https://client.example.org", @public)

      assert url == "https://93.184.216.34:443/"
    end

    test "a non-default port is kept, and joins the Host header" do
      {url, headers} = request_for("https://client.example.org:8443/m", @public)

      assert url == "https://93.184.216.34:8443/m"
      assert {"host", "client.example.org:8443"} in headers
    end
  end

  ## The request options

  describe "http_options/1" do
    test "redirects stay refused" do
      assert Keyword.fetch!(Cimd.http_options("client.example.org"), :autoredirect) == false
    end

    test "TLS is verified against the system trust store with a hostname check" do
      ssl = Keyword.fetch!(Cimd.http_options("client.example.org"), :ssl)

      assert ssl[:verify] == :verify_peer
      assert ssl[:depth] == 4
      assert is_list(ssl[:cacerts]) and ssl[:cacerts] != []
      assert Keyword.has_key?(ssl[:customize_hostname_check], :match_fun)
    end

    test "the hostname, not the pinned address, is what TLS verifies against" do
      # The socket is opened against an IP literal, so the host reaches TLS
      # only through server_name_indication — which is both the SNI value and
      # the reference identity OTP's ssl runs the hostname check against.
      ssl = Keyword.fetch!(Cimd.http_options("client.example.org"), :ssl)
      assert ssl[:server_name_indication] == ~c"client.example.org"
    end
  end

  ## The production seam

  test "net/0 hands out the production implementations" do
    net = Cimd.net()
    assert is_function(net.request, 2)
    assert net.resolve == (&:inet.getaddr/2)
  end
end
