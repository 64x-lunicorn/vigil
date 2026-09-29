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

  Two entries are checked against the vault clone rather than on their own:
  the remote and the branch every pull and push names — which has to be the
  branch checked out, since every commit lands on HEAD. What the clone has is
  asked once, through the `Vigil.Git` value `check/2` is handed — its
  `tracking` question — and put beside the configuration as
  `:vault_clone`, so those two checks read it the way the resource reads the
  issuer. A vault path that is no git clone is refused on its own entry, and
  the two that depend on it then say nothing more.
  """

  alias Vigil.{Cidr, Git}

  @settings [
    {:vault_path, "VIGIL_VAULT_PATH", :git_clone},
    {:git_remote, "VIGIL_GIT_REMOTE", :git_remote},
    {:git_branch, "VIGIL_GIT_BRANCH", :git_branch},
    {:state_dir, "VIGIL_STATE_DIR", :required},
    {:port, "VIGIL_PORT", :port},
    {:bind, "VIGIL_BIND", :ip_address},
    {:tz, "VIGIL_TZ", :time_zone},
    {:issuer, "VIGIL_ISSUER", :issuer},
    {:resource, "VIGIL_RESOURCE", :resource},
    {:auth_password, "VIGIL_AUTH_PASSWORD", :password},
    {:consent_failures_per_hour, "VIGIL_CONSENT_FAILURES_PER_HOUR", :positive_integer},
    {:allowed_origins, "VIGIL_ALLOWED_ORIGINS", :origins},
    {:skillkey_secret, "VIGIL_SKILLKEY_SECRET", :skillkey_secret},
    {:skillkey_ttl_seconds, "VIGIL_SKILLKEY_TTL", :positive_integer},
    {:rate_limit_rpm, "VIGIL_RATE_LIMIT_RPM", :positive_integer},
    {:reload_rate_limit_rpm, "VIGIL_RELOAD_RATE_LIMIT_RPM", :positive_integer},
    {:oauth_rate_limit_rpm, "VIGIL_OAUTH_RATE_LIMIT_RPM", :positive_integer},
    {:oauth_register_rate_limit_rpm, "VIGIL_OAUTH_REGISTER_RATE_LIMIT_RPM", :positive_integer},
    {:read_fetch_interval, "VIGIL_READ_FETCH_INTERVAL", :non_negative_integer},
    {:trusted_proxy_header, "VIGIL_TRUSTED_PROXY_HEADER", :proxy_header},
    {:trusted_proxies, "VIGIL_TRUSTED_PROXIES", :proxies},
    {:exclude, "VIGIL_EXCLUDE", :directory_names},
    {:vault_owner, "VIGIL_VAULT_OWNER", :required},
    {:vault_language, "VIGIL_VAULT_LANGUAGE", :required}
  ]

  @min_password_length 12

  # Bytes of randomness the SkillKey secret must decode to, and the command
  # that prints one — `scripts/init.sh` runs exactly this.
  @min_secret_bytes 32
  @generate_secret "generate one with `openssl rand -base64 48`"

  # The branch a vault is on when VIGIL_GIT_BRANCH does not say and the clone's
  # checked-out branch tracks nothing: what `git init` names it on a host
  # whose init.defaultBranch is what scripts/init.sh sets.
  @default_branch "main"

  @doc """
  The application's configuration, checked against the vault clone `git`
  reads; raises naming every setting that failed. Returns the checked values
  by key.
  """
  @spec check!(keyword, Git.t()) :: %{atom => term}
  def check!(config \\ Application.get_all_env(:vigil), git \\ Git.over_repository()) do
    case check(config, git) do
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
  its variable. `git` is what the vault clone is asked about its remotes and
  branches.

  The checked branch is the one to use: `VIGIL_GIT_BRANCH` when it is set,
  and otherwise the clone's checked-out branch when that tracks a branch on
  the remote, or `"#{@default_branch}"`.
  """
  @spec check(keyword, Git.t()) :: {:ok, %{atom => term}} | {:error, [String.t()]}
  def check(config, %Git{} = git) do
    config = Keyword.put(config, :vault_clone, vault_clone(Keyword.get(config, :vault_path), git))

    {checked, errors} =
      Enum.reduce(@settings, {%{}, []}, fn {key, var, check}, {checked, errors} ->
        case check_value(check, Keyword.get(config, key), config) do
          {:ok, value} -> {Map.put(checked, key, value), errors}
          {:error, :unset} -> {checked, ["#{var} is not set" | errors]}
          {:error, {:unset, hint}} -> {checked, ["#{var} is not set; #{hint}" | errors]}
          {:error, expected} -> {checked, ["#{var} must be #{expected}" | errors]}
        end
      end)

    if errors == [], do: {:ok, checked}, else: {:error, Enum.reverse(errors)}
  end

  # The clone's remotes and branches, or why there are none to read. Not asked
  # for a path that is unset: that is reported on its own entry already.
  defp vault_clone(path, git) when is_binary(path) and path != "", do: git.tracking.(path)
  defp vault_clone(_path, _git), do: {:error, :unset}

  # Unset is not an error for the branch: it has a default, and the default
  # is the clone's to say. Ahead of the clause refusing an unset value.
  defp check_value(:git_branch, value, config) when value in [nil, ""] do
    case check_value(:git_branch, default_branch(config), config) do
      {:ok, branch} -> {:ok, branch}
      {:error, expected} -> {:error, expected <> ", the default while it is unset"}
    end
  end

  # Unset is the safe setting for the proxy header, and the default: no
  # forwarded header is believed. It is refused only beside a list of trusted
  # peers, which names whose header to believe without saying which one.
  defp check_value(:proxy_header, value, config) when value in [nil, ""] do
    if Keyword.get(config, :trusted_proxies) in [nil, []],
      do: {:ok, nil},
      else:
        {:error,
         {:unset,
          "VIGIL_TRUSTED_PROXIES lists the peers whose header is believed, " <>
            "and this names the header: set both or neither"}}
  end

  # The setting's own checks. Every one refuses an unset value first: in :prod
  # `config/runtime.exs` leaves the required ones nil when their variable is
  # unset, and every other one has a default there. The SkillKey secret says
  # how to make one: a host set up before it existed has none, and its
  # operator meets this message on the first boot after the update.
  defp check_value(:skillkey_secret, value, _config) when value in [nil, ""],
    do: {:error, {:unset, @generate_secret}}

  defp check_value(_check, value, _config) when value in [nil, ""], do: {:error, :unset}

  defp check_value(:git_clone, value, config) do
    case Keyword.fetch!(config, :vault_clone) do
      {:ok, _clone} -> {:ok, value}
      {:error, _} -> {:error, "a git clone, got #{inspect(value)}"}
    end
  end

  # Checked against the clone, and only a clone that could be read: a vault
  # path that is none is reported on its own entry.
  defp check_value(:git_remote, value, config) do
    case Keyword.fetch!(config, :vault_clone) do
      {:ok, %{remotes: remotes}} ->
        if value in remotes,
          do: {:ok, value},
          else: {:error, "a remote of the vault clone (#{names(remotes)}), got #{inspect(value)}"}

      {:error, _} ->
        {:ok, value}
    end
  end

  # The branch exists in the clone, tracks its namesake on the remote, and is
  # the one checked out. Every pull and every push names the branch, so an
  # upstream anywhere else would be a branch pulled from one place and pushed
  # to another; and every commit, fast-forward and rebase acts on HEAD, so a
  # clone with another branch checked out — or none — would take every write
  # and push none of them. A remote that is not there is reported on its own
  # entry, not here as well.
  defp check_value(:git_branch, value, config) do
    remote = Keyword.get(config, :git_remote)

    case Keyword.fetch!(config, :vault_clone) do
      {:ok, %{branches: branches, remotes: remotes, head: head}} ->
        cond do
          not Map.has_key?(branches, value) ->
            {:error,
             "a branch of the vault clone (#{names(Map.keys(branches))}), got #{inspect(value)}"}

          remote in remotes and branches[value] != {remote, value} ->
            {:error,
             "a branch tracking #{remote}/#{value} (git branch --set-upstream-to=#{remote}/#{value} #{value}), " <>
               "got #{inspect(value)} #{upstream(branches[value])}"}

          head != value ->
            {:error,
             "the branch checked out in the vault clone " <>
               "(git -C #{Keyword.get(config, :vault_path)} switch #{value}), " <>
               "got #{inspect(value)} while #{checked_out(head)}"}

          true ->
            {:ok, value}
        end

      {:error, _} ->
        {:ok, value}
    end
  end

  defp check_value(:required, value, _config), do: {:ok, value}

  defp check_value(:positive_integer, value, _config) do
    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, "a positive integer, got #{inspect(value)}"}
  end

  # Seconds, and the one integer where 0 is a setting rather than a typo: it
  # turns fetching before reads off (docs/design.md, "Reads see what another
  # clone pushed").
  defp check_value(:non_negative_integer, value, _config) do
    if is_integer(value) and value >= 0,
      do: {:ok, value},
      else: {:error, "a non-negative integer, got #{inspect(value)}"}
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
    with {:ok, _uri} <- url(value, config),
         :ok <- same_origin(value, Keyword.get(config, :issuer), config) do
      {:ok, value}
    end
  end

  # Named, never echoed: a human types it on the consent page.
  defp check_value(:password, value, _config) do
    if is_binary(value) and String.length(value) >= @min_password_length,
      do: {:ok, value},
      else:
        {:error,
         "at least #{@min_password_length} characters: a publicly reachable " <>
           "authorization server without a strong password is an open door to the vault"}
  end

  # A list, empty by default, so never unset. Every entry must be an origin and
  # nothing more: a path or a trailing typo would otherwise match no browser's
  # `Origin` and let nobody in without saying why.
  defp check_value(:origins, values, _config) when is_list(values) do
    case Enum.reject(values, &match?({:ok, _}, Vigil.Origin.parse(&1))) do
      [] ->
        {:ok, Enum.map(values, fn value -> elem(Vigil.Origin.parse(value), 1) end)}

      bad ->
        {:error,
         "a comma-separated list of origins such as http://localhost:6274 " <>
           "(scheme and host, no path), got #{Enum.map_join(bad, ", ", &inspect/1)}"}
    end
  end

  defp check_value(:origins, value, _config),
    do: {:error, "a comma-separated list of origins, got #{inspect(value)}"}

  # A header's name as HTTP spells one (RFC 9110 §5.1), lowercase as `Plug`
  # stores them, which is how `Vigil.OAuth.ClientAddr` asks for it.
  defp check_value(:proxy_header, value, _config) do
    if value =~ ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/,
      do: {:ok, String.downcase(value)},
      else: {:error, "a header name such as CF-Connecting-IP, got #{inspect(value)}"}
  end

  # Every entry an address or a block, parsed. An entry that is neither used to
  # be dropped with a warning, which left the list empty and every request
  # counted under the proxy's own address: one bucket for everyone, which the
  # first wrong password from anywhere spends for the owner as well. An empty
  # list is the default, and refused only beside a header, which it would leave
  # nobody to believe.
  defp check_value(:proxies, [], config) do
    if Keyword.get(config, :trusted_proxy_header) in [nil, ""],
      do: {:ok, []},
      else:
        {:error,
         {:unset,
          "VIGIL_TRUSTED_PROXY_HEADER names a header, and this lists the peers " <>
            "whose header is believed: set both or neither"}}
  end

  defp check_value(:proxies, entries, _config) when is_list(entries) do
    case Enum.reject(entries, &match?({:ok, _}, Cidr.parse(&1))) do
      [] ->
        {:ok, Enum.map(entries, fn entry -> elem(Cidr.parse(entry), 1) end)}

      bad ->
        {:error,
         "a comma-separated list of addresses or CIDR blocks such as 127.0.0.1/32,::1/128, " <>
           "got #{Enum.map_join(bad, ", ", &inspect/1)}"}
    end
  end

  defp check_value(:proxies, value, _config),
    do: {:error, "a comma-separated list of addresses or CIDR blocks, got #{inspect(value)}"}

  # Each entry is matched against every segment of a path
  # (`Vigil.Vault.Layout`), so an entry that is a path, or `.` or `..`,
  # matches none: it would hide nothing while reading as if it did.
  defp check_value(:directory_names, names, _config) when is_list(names) do
    case Enum.filter(names, &(String.contains?(&1, "/") or &1 in [".", ".."])) do
      [] ->
        {:ok, names}

      bad ->
        {:error,
         "a comma-separated list of directory names such as secret, " <>
           "each excluded at any depth and none a path, got #{Enum.map_join(bad, ", ", &inspect/1)}"}
    end
  end

  defp check_value(:directory_names, value, _config),
    do: {:error, "a comma-separated list of directory names, got #{inspect(value)}"}

  # Named, never echoed, and never chosen: every SkillKey is an HMAC under
  # this secret handed to the client, so it ends up in chat transcripts, and a
  # guessable secret can be tested against one offline. Random bytes are the
  # only thing that makes that pointless, so the value has to *be* them —
  # base64 or hex, decoding to at least 32 — rather than merely be long. The
  # consent password is refused here for the same reason: it is the one
  # secret in this file a human may have chosen.
  defp check_value(:skillkey_secret, value, config) do
    cond do
      value == Keyword.get(config, :auth_password) ->
        {:error, "a secret of its own, not VIGIL_AUTH_PASSWORD; #{@generate_secret}"}

      byte_size(decode_secret(value)) < @min_secret_bytes ->
        {:error,
         "at least #{@min_secret_bytes} random bytes, base64 or hex encoded; #{@generate_secret}"}

      # Decoding to 32 bytes is what random bytes do, and what 43 letters do
      # as well: a phrase without spaces is valid base64. What `openssl rand`
      # prints lacks a digit or a sign fewer than once in half a million
      # tries; a value of letters alone is a person's.
      value =~ ~r/\A[A-Za-z]+\z/ ->
        {:error,
         "random bytes, base64 or hex encoded, not a phrase of letters; #{@generate_secret}"}

      true ->
        {:ok, value}
    end
  end

  # What the secret decodes to, or nothing if it is neither hex nor base64.
  # Hex first: every hex string is also valid base64, and decoding it as that
  # would count half again the randomness it holds.
  defp decode_secret(value) do
    with :error <- Base.decode16(value, case: :mixed),
         :error <- Base.decode64(value, padding: false) do
      ""
    else
      {:ok, bytes} -> bytes
    end
  end

  # The checked-out branch, when it tracks a branch on the configured remote;
  # otherwise the one every other script defaults to as well.
  defp default_branch(config) do
    remote = Keyword.get(config, :git_remote)

    with {:ok, %{head: head, branches: branches}} when is_binary(head) <-
           Keyword.fetch!(config, :vault_clone),
         {^remote, _} <- branches[head] do
      head
    else
      _ -> @default_branch
    end
  end

  defp names([]), do: "it has none"
  defp names(names), do: "it has " <> (names |> Enum.sort() |> Enum.join(", "))

  defp checked_out(nil), do: "HEAD is detached"
  defp checked_out(head), do: "#{inspect(head)} is checked out"

  defp upstream(nil), do: "with no upstream"
  defp upstream({remote, branch}), do: "tracking #{remote}/#{branch}"

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
  # on its own entry and not a second time here. Compared as `Vigil.Origin`
  # compares a browser's: serialized, the host lowercase.
  defp same_origin(resource, issuer, config) do
    with true <- Keyword.get(config, :https_required, false),
         true <- is_binary(issuer),
         {:ok, issuer_origin} <- Vigil.Origin.of(issuer),
         false <- Vigil.Origin.of(resource) == {:ok, issuer_origin} do
      {:error, "on the issuer's origin #{issuer_origin}, got #{inspect(resource)}"}
    else
      _ -> :ok
    end
  end
end
