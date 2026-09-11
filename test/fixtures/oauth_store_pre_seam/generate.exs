# Writes the .dets files beside this script, using the code of whatever
# revision it is run from. It produced this fixture at ccc42a6 — the commit
# before the OAuth persistence seam was drawn (#135) — and is kept so the
# fixture can be regenerated, or a newer "previous version" frozen.
#
#     git worktree add --detach /tmp/old <revision>
#     cp test/fixtures/oauth_store_pre_seam/generate.exs /tmp/old/
#     cd /tmp/old && mix deps.get && mix run --no-start generate.exs /tmp/store
#
# --no-start matters: booting the application refuses to start without a real
# VIGIL_AUTH_PASSWORD, and this needs the Store and nothing else.
#
# IT IS WRITTEN AGAINST THE PRE-SEAM API AND WILL NOT RUN AT #135 OR LATER.
# Token.issue_out_of_band/4, Token.issue_pair/2, Client.register/3 and
# Store.put_*/get_* all take a persistence value as their first argument since
# the seam, and this script calls the older arities. Re-freezing against a
# newer revision means porting those calls to that revision's API — which is
# the point of keeping the script rather than only the .dets files: the records
# it makes, and the order it makes them in, are what has to be reproduced.
#
# The identifiers it prints are not recorded anywhere. The test discovers them
# from the tables, which keeps a long-lived bearer token out of the repository.
[state_dir] = System.argv()

Application.put_env(:vigil, :issuer, "https://vault.factory-lab.org")
Application.put_env(:vigil, :resource, "https://vault.factory-lab.org/mcp")
Application.put_env(:vigil, :auth_password, "correct-horse-battery-staple")

{:ok, _} = Vigil.OAuth.Store.start_link(state_dir: state_dir)

now = 1_767_225_600
resource = "https://vault.factory-lab.org/mcp"
redirect = "https://claude.ai/api/mcp/auth_callback"

client = Vigil.OAuth.Client.register("Frozen fixture client", [redirect], now)

ctx = %{
  client: client,
  redirect_uri: redirect,
  code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
  scope: "vault"
}

# One code left unredeemed, so the codes table is not empty and a code record's
# shape is frozen too.
_pending = Vigil.OAuth.Code.issue(ctx, now)

# A second one, redeemed the way the flow redeems it, so the fixture carries a
# real access/refresh pair — the records an already-connected client rotates
# with, and the ones an out-of-band token cannot stand in for.
redeemed = Vigil.OAuth.Code.issue(ctx, now)
{:ok, record} = Vigil.OAuth.Store.take_code(redeemed)
_pair = Vigil.OAuth.Token.issue_pair(record, now)

# And the two long-lived tokens verify() and first access are handed.
Vigil.OAuth.Token.issue_out_of_band(resource, "vault", 3650 * 86400, now)
Vigil.OAuth.Token.issue_out_of_band(resource, "vault:read", 3650 * 86400, now)

:ok = GenServer.stop(Vigil.OAuth.Store)

IO.puts("wrote #{state_dir}")
