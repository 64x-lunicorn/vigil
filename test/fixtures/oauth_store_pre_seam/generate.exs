# Writes the .dets files beside this script, using the code of whatever
# revision it is run from. It produced this fixture at ccc42a6 — the commit
# before the OAuth persistence seam was drawn (#135) — and it is kept so the
# fixture can be regenerated, or a newer "previous version" frozen, without
# reconstructing how these records were made.
#
#     git worktree add --detach /tmp/old <revision>
#     cp test/fixtures/oauth_store_pre_seam/generate.exs /tmp/old/
#     cd /tmp/old && mix deps.get && mix run --no-start generate.exs /tmp/store
#
# --no-start matters: booting the application refuses to start without a real
# VIGIL_AUTH_PASSWORD, and this needs the Store and nothing else.
#
# The identifiers it prints are not recorded anywhere. The test discovers them
# from the tables, which is what keeps a long-lived bearer token out of the
# repository.
[state_dir] = System.argv()

Application.put_env(:vigil, :issuer, "https://vault.factory-lab.org")
Application.put_env(:vigil, :resource, "https://vault.factory-lab.org/mcp")
Application.put_env(:vigil, :auth_password, "correct-horse-battery-staple")

{:ok, _} = Vigil.OAuth.Store.start_link(state_dir: state_dir)

now = 1_767_225_600

client =
  Vigil.OAuth.Client.register(
    "Frozen fixture client",
    ["https://claude.ai/api/mcp/auth_callback"],
    now
  )

token =
  Vigil.OAuth.Token.issue_out_of_band(
    "https://vault.factory-lab.org/mcp",
    "vault",
    3650 * 86400,
    now
  )

readonly =
  Vigil.OAuth.Token.issue_out_of_band(
    "https://vault.factory-lab.org/mcp",
    "vault:read",
    3650 * 86400,
    now
  )

:ok = GenServer.stop(Vigil.OAuth.Store)

IO.puts(
  Jason.encode!(%{
    client_id: client.client_id,
    client_name: "Frozen fixture client",
    access_token: token,
    readonly_token: readonly,
    issued_at: now
  })
)
