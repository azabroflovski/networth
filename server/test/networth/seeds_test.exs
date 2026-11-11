defmodule Networth.SeedsTest do
  # Keeps priv/seeds.exs working as the core API changes.
  use Networth.DataCase

  import ExUnit.CaptureIO

  test "seeds demo data through the core, and running again changes nothing" do
    assert capture_io(fn -> Code.eval_file("priv/seeds.exs") end) =~ "Seeded"

    {:ok, %{user: demo}} = Users.login("demo@networth.local", "demo-password", {127, 0, 0, 1})
    assert [%{name: "Personal"} = personal, %{name: "Семья"}] = Workspaces.list_for_user(demo.id)
    {:ok, scope} = Workspaces.authorize(demo.id, personal.id)

    assert length(Accounts.list(scope)) == 5
    assert ledger_totals(scope) == [%{currency: "USD", total: 0}, %{currency: "UZS", total: 0}]
    %{n: transactions} = DB.one("SELECT count(*) AS n FROM transactions")

    assert capture_io(fn -> Code.eval_file("priv/seeds.exs") end) =~ "already present"
    assert %{n: ^transactions} = DB.one("SELECT count(*) AS n FROM transactions")
  end
end
