defmodule Vigil.Origin do
  @moduledoc """
  Which browser origins may talk to this server (`docs/design.md`, "Security
  model").

  The Streamable HTTP transport says a server MUST validate `Origin` and answer
  403 when it is present and invalid: a page on some other site that gets a
  browser to send a request to vigil — through DNS rebinding onto a loopback
  bind, most of all — carries that site's origin, and nothing the page can do
  changes it.

  Three cases pass, and nothing else does:

    * no `Origin` at all — a program, not a browser, and nothing to rebind;
    * the issuer's own origin — the consent form posting back to where it was
      served from;
    * an origin in `VIGIL_ALLOWED_ORIGINS`, for a browser-based client an
      operator has chosen to let in.

  An origin is compared in its serialized form (RFC 6454 §6.2): lowercase
  scheme and host, and the port only when it is not the scheme's default. So
  `https://Vault.Example.org:443` and `https://vault.example.org` are one
  origin, and `"null"` — what a sandboxed page or a `file:` URL sends — is
  none.
  """

  @typedoc "The serialized origins a request may come from."
  @type allowed :: MapSet.t(String.t())

  @doc """
  The origins a request may come from: the issuer's, and every listed one. A
  listed value that is not an origin has already stopped boot in
  `Vigil.Settings.Check`, so it is left out here rather than raised on.
  """
  @spec allowed(String.t(), [String.t()]) :: allowed
  def allowed(issuer, listed) do
    issuer_origin =
      case URI.new(issuer) do
        {:ok, uri} -> serialize(uri)
        {:error, _} -> :error
      end

    for {:ok, origin} <- [issuer_origin | Enum.map(listed, &parse/1)],
        into: MapSet.new(),
        do: origin
  end

  @doc """
  Whether `conn` may be answered: it carries no `Origin`, or exactly one that
  is allowed.
  """
  @spec allowed?(Plug.Conn.t(), allowed) :: boolean
  def allowed?(conn, allowed) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> true
      [value] -> parse(value) |> member?(allowed)
      _ -> false
    end
  end

  defp member?({:ok, origin}, allowed), do: MapSet.member?(allowed, origin)
  defp member?(:error, _allowed), do: false

  @doc """
  `value` in its serialized form, or `:error` when it is not an origin: an
  `http` or `https` scheme, a host, and nothing after them but an optional `/`.
  """
  @spec parse(term) :: {:ok, String.t()} | :error
  def parse(value) when is_binary(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{path: path, query: nil, fragment: nil, userinfo: nil} = uri}
      when path in [nil, "/"] ->
        serialize(uri)

      _ ->
        :error
    end
  end

  def parse(_value), do: :error

  defp serialize(%URI{scheme: scheme, host: host, port: port})
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    {:ok, URI.to_string(%URI{scheme: scheme, host: String.downcase(host), port: port})}
  end

  defp serialize(_uri), do: :error
end
