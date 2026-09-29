defmodule Mix.Tasks.Vigil.SeedToken do
  @shortdoc "Seeds an OAuth access token (90 days by default) directly into the dets store"
  @moduledoc """
  For first access and for `verify()` during a rebuild: mints an access token
  through `Vigil.OAuth.Token` straight into `oauth_tokens.dets`, without going
  through the interactive authorization-code flow. Starts `Vigil.OAuth.Store`
  on its own for this (no `Application.start`, no Bandit, no port conflict with
  a running service).

  The token lives 90 days unless `--ttl-days` or `--ttl-seconds` says
  otherwise. It is a bearer credential nobody rotates, so its lifetime is
  what bounds it; it can also be revoked early like any grant
  (`docs/guide.md`, "Revoking access").

  Prints **only the token, on stdout** — no `Logger`, so it never reaches
  journald. The caller is responsible for not logging the output either.

      mix vigil.seed_token --state-dir /var/lib/vigil --resource https://vault.example.org/mcp --scope vault
      mix vigil.seed_token --state-dir /var/lib/vigil --resource https://vault.example.org/mcp --scope vault:read --ttl-days 30
      mix vigil.seed_token --state-dir /var/lib/vigil --resource https://vault.example.org/mcp --scope vault --ttl-seconds 900
  """
  use Mix.Task

  # Short on purpose: it used to be ten years, which made a seeded token the
  # one credential nothing but deleting the state dir ever took back.
  @default_ttl_days 90

  @impl true
  def run(args) do
    Mix.Task.run("compile", ["--no-deps-check"])

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          state_dir: :string,
          resource: :string,
          scope: :string,
          ttl_days: :integer,
          ttl_seconds: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    state_dir = Keyword.fetch!(opts, :state_dir)
    resource = Keyword.fetch!(opts, :resource)
    scope = Keyword.get(opts, :scope, "vault")
    ttl_seconds = ttl_seconds(opts)

    # The scopes are `Vigil.OAuth`'s, the same list its metadata publishes: a
    # scope the flow issues is one this task can seed, and no other.
    allowed = Vigil.OAuth.scopes()

    unless scope in allowed do
      Mix.raise("Invalid --scope: #{scope} (allowed: #{Enum.join(allowed, ", ")})")
    end

    {:ok, pid} = Vigil.OAuth.Store.start_link(state_dir: state_dir)

    now = System.system_time(:second)

    # The record is `Vigil.OAuth.Token`'s to write, out of band or not: this
    # task used to hand-write a variant of it, which is how it came to be the
    # one shape carrying no grant.
    token =
      Vigil.OAuth.Token.issue_out_of_band(
        Vigil.OAuth.Store.over_tables(),
        resource,
        scope,
        ttl_seconds,
        now
      )

    GenServer.stop(pid)

    # Deliberately IO.puts rather than Mix.shell().info — the latter can, in
    # some Mix configurations, be interleaved with other output or truncated.
    # The token is the only line this task prints.
    IO.puts(token)
  end

  @doc """
  The lifetime the parsed options ask for, in seconds: `--ttl-seconds`, else
  `--ttl-days`, else #{@default_ttl_days} days. `--ttl-seconds` wins because
  the short-lived tokens for verify() are counted in minutes, not days.
  """
  @spec ttl_seconds(keyword()) :: pos_integer()
  def ttl_seconds(opts),
    do: Keyword.get(opts, :ttl_seconds, Keyword.get(opts, :ttl_days, @default_ttl_days) * 86_400)
end
