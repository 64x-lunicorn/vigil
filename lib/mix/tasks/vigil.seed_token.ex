defmodule Mix.Tasks.Vigil.SeedToken do
  @shortdoc "Seeds a long-lived OAuth access token directly into the dets store"
  @moduledoc """
  For first access and for `verify()` during a rebuild: writes an access token
  straight into `oauth_tokens.dets` without going through the interactive
  authorization-code flow. Starts `Vigil.OAuth.Store` on its own for this (no
  `Application.start`, no Bandit, no port conflict with a running service).

  Prints **only the token, on stdout** — no `Logger`, so it never reaches
  journald. The caller is responsible for not logging the output either.

      mix vigil.seed_token --state-dir /var/lib/vigil --resource https://vault.example.org/mcp --scope vault
      mix vigil.seed_token --state-dir /var/lib/vigil --resource https://vault.example.org/mcp --scope vault:read --ttl-days 3650
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile", ["--no-deps-check"])

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [state_dir: :string, resource: :string, scope: :string, ttl_days: :integer]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    state_dir = Keyword.fetch!(opts, :state_dir)
    resource = Keyword.fetch!(opts, :resource)
    scope = Keyword.get(opts, :scope, "vault")
    ttl_days = Keyword.get(opts, :ttl_days, 3650)

    unless scope in ["vault", "vault:read"] do
      Mix.raise("Invalid --scope: #{scope} (allowed: vault, vault:read)")
    end

    {:ok, pid} = Vigil.OAuth.Store.start_link(state_dir: state_dir)

    token = Vigil.OAuth.Token.random()
    now = System.system_time(:second)

    Vigil.OAuth.Store.put_token(token, %{
      aud: resource,
      scope: scope,
      expires_at: now + ttl_days * 86_400
    })

    GenServer.stop(pid)

    # Deliberately IO.puts rather than Mix.shell().info — the latter can, in
    # some Mix configurations, be interleaved with other output or truncated.
    # The token is the only line this task prints.
    IO.puts(token)
  end
end
