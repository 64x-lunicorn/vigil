defmodule Vigil.Settings.Check do
  @moduledoc """
  Every setting checked once at boot, and a bad one named
  (`docs/design.md`, "The deployment is resolved once").

  `config/runtime.exs` reads the environment and parses nothing it could fail
  on: a variable that reads as an integer arrives as one, anything else
  arrives as written. This module is where what arrived is judged, in one
  table with one entry per setting — the application key, the variable an
  operator set, and the check that either accepts the value or says what was
  expected. `Vigil.Application` runs it before any child starts, so a
  malformed setting stops boot with a message naming the variable instead of
  an `ArgumentError` from integer parsing, or a server that boots and then
  fails every write.

  Every entry is checked and every failure is reported at once: an operator
  fixing `/etc/vigil/env` should not have to restart once per typo.

  A new setting is one more entry in `@settings`. A check gets the value and
  the whole configuration (for the entries that depend on another one, such
  as the resource on the issuer) and returns `{:ok, value}` — the value the
  composition root should use, parsed if that is what checking it took — or
  `{:error, expected}`, which is appended to the variable's name. A check that
  wants the offending value in the message puts it there itself, which is how
  a secret stays out of the journal.
  """

  @settings [
    {:vault_path, "VIGIL_VAULT_PATH", :required},
    {:state_dir, "VIGIL_STATE_DIR", :required},
    {:port, "VIGIL_PORT", :port},
    {:bind, "VIGIL_BIND", :ip_address},
    {:tz, "VIGIL_TZ", :time_zone},
    {:issuer, "VIGIL_ISSUER", :issuer},
    {:resource, "VIGIL_RESOURCE", :resource},
    {:auth_password, "VIGIL_AUTH_PASSWORD", :password},
    {:skillkey_ttl_seconds, "VIGIL_SKILLKEY_TTL", :positive_integer},
    {:rate_limit_rpm, "VIGIL_RATE_LIMIT_RPM", :positive_integer},
    {:oauth_rate_limit_rpm, "VIGIL_OAUTH_RATE_LIMIT_RPM", :positive_integer},
    {:oauth_register_rate_limit_rpm, "VIGIL_OAUTH_REGISTER_RATE_LIMIT_RPM", :positive_integer}
  ]

  @min_password_length 12

  @doc """
  The application's configuration, checked; raises naming every setting that
  failed. Returns the checked values by key.
  """
  @spec check!(keyword) :: %{atom => term}
  def check!(config \\ Application.get_all_env(:vigil)) do
    case check(config) do
      {:ok, checked} ->
        checked

      {:error, messages} ->
        raise """
        vigil refuses to start: #{Enum.join(messages, "; ")}.
        Check /etc/vigil/env (see deploy/vigil.env.example).
        """
    end
  end

  @doc """
  `{:ok, checked}` with every setting's checked value by key, or
  `{:error, messages}` with one message per setting that failed, each naming
  its variable.
  """
  @spec check(keyword) :: {:ok, %{atom => term}} | {:error, [String.t()]}
  def check(config) do
    {checked, errors} =
      Enum.reduce(@settings, {%{}, []}, fn {key, var, check}, {checked, errors} ->
        case check_value(check, Keyword.get(config, key), config) do
          {:ok, value} -> {Map.put(checked, key, value), errors}
          {:error, :unset} -> {checked, ["#{var} is not set" | errors]}
          {:error, expected} -> {checked, ["#{var} must be #{expected}" | errors]}
        end
      end)

    if errors == [], do: {:ok, checked}, else: {:error, Enum.reverse(errors)}
  end

  # The setting's own checks. Every one refuses an unset value first: in :prod
  # `config/runtime.exs` leaves the required ones nil when their variable is
  # unset, and every other one has a default there.
  defp check_value(_check, value, _config) when value in [nil, ""], do: {:error, :unset}

  defp check_value(:required, value, _config), do: {:ok, value}

  defp check_value(:positive_integer, value, _config) do
    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, "a positive integer, got #{inspect(value)}"}
  end

  defp check_value(:port, value, _config) do
    if is_integer(value) and value in 1..65_535,
      do: {:ok, value},
      else: {:error, "a positive integer no greater than 65535, got #{inspect(value)}"}
  end

  defp check_value(:ip_address, value, _config) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "an IP address, got #{inspect(value)}"}
    end
  end

  # Refused rather than falling back to UTC: every response and every write is
  # stamped in this zone, and a stamp an hour off is not something an operator
  # would ever notice in a warning.
  defp check_value(:time_zone, value, _config) do
    case DateTime.now(value) do
      {:ok, _} -> {:ok, value}
      {:error, _} -> {:error, "a timezone name such as Europe/Berlin, got #{inspect(value)}"}
    end
  end

  defp check_value(:issuer, value, config) do
    with {:ok, _uri} <- url(value, config), do: {:ok, value}
  end

  # The resource is protected by this issuer, so it lives on the issuer's
  # origin: a client that finds the one by the other's metadata must be able
  # to trust it is talking to the same server.
  defp check_value(:resource, value, config) do
    with {:ok, uri} <- url(value, config),
         :ok <- same_origin(uri, Keyword.get(config, :issuer), config) do
      {:ok, value}
    end
  end

  # Named, never echoed: the consent password is also the SkillKey secret.
  defp check_value(:password, value, _config) do
    if is_binary(value) and String.length(value) >= @min_password_length,
      do: {:ok, value},
      else:
        {:error,
         "at least #{@min_password_length} characters: a publicly reachable " <>
           "authorization server without a strong password is an open door to the vault"}
  end

  defp url(value, config) do
    https? = Keyword.get(config, :https_required, false)

    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host} = uri} when host not in [nil, ""] ->
        {:ok, uri}

      {:ok, %URI{scheme: "http", host: host} = uri} when host not in [nil, ""] and not https? ->
        {:ok, uri}

      _ when https? ->
        {:error, "an https URL, got #{inspect(value)}"}

      _ ->
        {:error, "an http or https URL, got #{inspect(value)}"}
    end
  end

  # Only in :prod, like https. An issuer that is unset or no URL is reported
  # on its own entry and not a second time here.
  defp same_origin(uri, issuer, config) do
    with true <- Keyword.get(config, :https_required, false),
         true <- is_binary(issuer),
         {:ok, %URI{host: host} = issuer_uri} when host not in [nil, ""] <- URI.new(issuer),
         false <- origin(uri) == origin(issuer_uri) do
      {:error, "on the issuer's origin #{origin(issuer_uri)}, got #{inspect(URI.to_string(uri))}"}
    else
      _ -> :ok
    end
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}),
    do: URI.to_string(%URI{scheme: scheme, host: host, port: port})
end
