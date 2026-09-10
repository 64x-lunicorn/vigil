defmodule Vigil.OAuth.CimdTest do
  @moduledoc """
  The CIMD fetch is the only place vigil makes an outbound request to an
  address an untrusted party chooses. Every test here drives it through a
  fake `net`, so the suite exercises the guard rather than the internet.
  """

  use ExUnit.Case, async: false

  alias Vigil.OAuth.Cimd

  @url "https://client.example.org/metadata.json"
  @public {93, 184, 216, 34}
  @loopback {127, 0, 0, 1}
  @now 1_700_000_000

  setup do
    Vigil.OAuthCase.setup!()
    :ok
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
  defp fetch_resolving_to(ip) do
    Cimd.fetch(@url, @now, net(addresses: [{:ok, ip}]))
  end

  ## The happy path

  test "a valid document becomes a client, and the fetch resolves before it requests" do
    assert {:ok, doc} = Cimd.fetch(@url, @now, net([]))

    assert doc == %{
             client_id: @url,
             name: "Example",
             redirect_uris: ["https://client.example.org/cb"]
           }

    assert_received {:resolve, "client.example.org", :inet}
    assert_received {:request, @url, @public}
  end

  test "a document without client_name is refused rather than defaulted to the URL" do
    # `fetch` reads client_name with a default, but validation requires it, so
    # the default is unreachable. Pinned here so removing either is visible.
    assert :error = Cimd.fetch(@url, @now, net(body: document(%{"client_name" => nil})))
  end

  ## The URL

  test "a non-https client_id is refused without resolving or requesting" do
    assert :error = Cimd.fetch("http://client.example.org/metadata.json", @now, net([]))
    refute_received {:resolve, _, _}
    refute_received {:request, _, _}
  end

  test "an https URL without a host is refused" do
    assert :error = Cimd.fetch("https:///metadata.json", @now, net([]))
    refute_received {:request, _, _}
  end

  ## One resolution, not two

  test "the address the guard checked is the address the request is given" do
    assert {:ok, _doc} = Cimd.fetch(@url, @now, net([]))
    assert_received {:request, @url, @public}
  end

  test "a host answering public and then loopback never reaches the loopback address" do
    # DNS rebinding: the attacker controls the host's DNS and answers the
    # guard's lookup with a public address and the connection's lookup with
    # 127.0.0.1. There is only one lookup now, so the second answer is never
    # asked for — and the request carries the address that was checked.
    net = net(addresses: [{:ok, @public}, {:ok, @loopback}])

    assert {:ok, _doc} = Cimd.fetch(@url, @now, net)

    assert_received {:resolve, "client.example.org", :inet}
    refute_received {:resolve, _, _}

    assert_received {:request, @url, @public}
    refute_received {:request, _, @loopback}
  end

  ## The SSRF guard

  test "a host resolving to a private address is refused without requesting" do
    assert :error = fetch_resolving_to(@loopback)
    assert_received {:resolve, "client.example.org", :inet}
    refute_received {:request, _, _}
  end

  test "a host with no A record is retried as AAAA" do
    net = net(addresses: [{:error, :nxdomain}, {:ok, {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}}])
    assert {:ok, _doc} = Cimd.fetch(@url, @now, net)

    assert_received {:resolve, "client.example.org", :inet}
    assert_received {:resolve, "client.example.org", :inet6}
  end

  test "a host that resolves in neither family is refused" do
    assert :error = Cimd.fetch(@url, @now, net(addresses: [{:error, :nxdomain}]))
    refute_received {:request, _, _}
  end

  ## The ranges the guard refuses

  test "the IPv4 ranges that must not be reachable are refused, one per range" do
    for {label, ip} <- [
          {"0.0.0.0/8 (this network)", {0, 0, 0, 0}},
          {"10.0.0.0/8 (private)", {10, 1, 2, 3}},
          {"100.64.0.0/10 (carrier-grade NAT)", {100, 64, 0, 1}},
          {"100.64.0.0/10 upper edge", {100, 127, 255, 254}},
          {"127.0.0.0/8 (loopback)", {127, 0, 0, 1}},
          {"169.254.0.0/16 (link-local)", {169, 254, 169, 254}},
          {"172.16.0.0/12 (private)", {172, 16, 0, 1}},
          {"192.168.0.0/16 (private)", {192, 168, 1, 1}},
          {"198.18.0.0/15 (benchmarking)", {198, 18, 0, 1}},
          {"198.18.0.0/15 upper half", {198, 19, 255, 254}}
        ] do
      assert :error = fetch_resolving_to(ip), "#{label} was not refused"
    end
  end

  test "an address just outside each added range stays reachable" do
    for {label, ip} <- [
          {"1.0.0.0 is not 0.0.0.0/8", {1, 0, 0, 1}},
          {"100.63.x is below the CGNAT range", {100, 63, 255, 254}},
          {"100.128.x is above the CGNAT range", {100, 128, 0, 1}},
          {"198.17.x is below the benchmarking range", {198, 17, 255, 254}},
          {"198.20.x is above the benchmarking range", {198, 20, 0, 1}}
        ] do
      assert {:ok, _doc} = fetch_resolving_to(ip), "#{label} was refused"
    end
  end

  test "the IPv6 ranges that must not be reachable are refused, one per range" do
    for {label, ip} <- [
          {":: (unspecified)", {0, 0, 0, 0, 0, 0, 0, 0}},
          {"::1 (loopback)", {0, 0, 0, 0, 0, 0, 0, 1}},
          {"fc00::/7 (unique local)", {0xFC00, 0, 0, 0, 0, 0, 0, 1}},
          {"fd00::/8 (unique local)", {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1}},
          {"fe80::/10 (link-local)", {0xFE80, 0, 0, 0, 0, 0, 0, 1}},
          {"febf::/10 upper edge", {0xFEBF, 0, 0, 0, 0, 0, 0, 1}}
        ] do
      assert :error = fetch_resolving_to(ip), "#{label} was not refused"
    end
  end

  test "an IPv4-mapped IPv6 address is unfolded before the ranges are checked" do
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
          {"::ffff:198.18.0.1", {0, 0, 0, 0, 0, 0xFFFF, 0xC612, 0x0001}}
        ] do
      assert :error = fetch_resolving_to(ip), "#{label} was not refused"
    end
  end

  test "an IPv4-mapped public address stays reachable" do
    # 93.184.216.34 mapped: the unfolding must not refuse everything it touches.
    assert {:ok, _doc} = fetch_resolving_to({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
  end

  ## The response

  test "a non-200 response is refused" do
    assert :error = Cimd.fetch(@url, @now, net(responses: [:error]))
    assert_received {:request, @url, @public}
  end

  test "a body over the size cap is refused even when the request hands one back" do
    # The cap belongs to the fetch, not to one implementation of the request:
    # `net.request` is a seam, and nothing behind it may return an unbounded
    # body. `read_capped/2` enforces the same bound during the read.
    oversized = document(%{"client_name" => String.duplicate("a", 65_537)})
    assert :error = Cimd.fetch(@url, @now, net(body: oversized))
  end

  test "a body that is not JSON is refused" do
    assert :error = Cimd.fetch(@url, @now, net(body: "not json"))
  end

  ## Document validation

  test "a document whose client_id is not the URL it came from is refused" do
    net = net(body: document(%{"client_id" => "https://other.example.org/metadata.json"}))
    assert :error = Cimd.fetch(@url, @now, net)
  end

  test "a document without a client_id is refused" do
    body = ~s({"client_name": "Example", "redirect_uris": ["https://client.example.org/cb"]})
    assert :error = Cimd.fetch(@url, @now, net(body: body))
  end

  test "a document whose client_name is not a string is refused" do
    assert :error = Cimd.fetch(@url, @now, net(body: document(%{"client_name" => 42})))
  end

  test "a document whose redirect_uris is not a list is refused" do
    net = net(body: document(%{"redirect_uris" => "https://client.example.org/cb"}))
    assert :error = Cimd.fetch(@url, @now, net)
  end

  test "a document whose redirect_uris is empty is refused" do
    assert :error = Cimd.fetch(@url, @now, net(body: document(%{"redirect_uris" => []})))
  end

  test "a document with a redirect_uri that registration would refuse is refused" do
    net = net(body: document(%{"redirect_uris" => ["http://evil.example.org/cb"]}))
    assert :error = Cimd.fetch(@url, @now, net)
  end

  test "a loopback redirect_uri is accepted, as it is at registration" do
    net = net(body: document(%{"redirect_uris" => ["http://127.0.0.1/cb"]}))
    assert {:ok, %{redirect_uris: ["http://127.0.0.1/cb"]}} = Cimd.fetch(@url, @now, net)
  end

  ## The cache

  test "a second fetch inside the hour is answered from the cache without requesting" do
    assert {:ok, doc} = Cimd.fetch(@url, @now, net([]))
    assert_received {:resolve, _, _}
    assert_received {:request, @url, @public}

    assert {:ok, ^doc} = Cimd.fetch(@url, @now + 3599, net([]))
    refute_received {:request, _, _}
    refute_received {:resolve, _, _}
  end

  test "a fetch after the hour has elapsed requests again" do
    assert {:ok, _doc} = Cimd.fetch(@url, @now, net([]))
    assert_received {:request, @url, @public}

    assert {:ok, _doc} = Cimd.fetch(@url, @now + 3601, net([]))
    assert_received {:request, @url, @public}
  end

  test "a refused document is not cached" do
    assert :error = Cimd.fetch(@url, @now, net(responses: [:error]))
    assert {:ok, _doc} = Cimd.fetch(@url, @now, net([]))
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
