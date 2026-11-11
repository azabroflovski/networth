defmodule Networth.Ledger.EditingTest do
  use Networth.DataCase

  setup :ledger_setup

  describe "editing" do
    # Description edits of a transaction from the activity log, oldest first.
    defp description_edits(scope, tx_id) do
      {:ok, %{events: events}} = Networth.Activity.list(scope, %{"subject_id" => tx_id})

      for %{action: "transaction.description_changed"} = e <- Enum.reverse(events) do
        [old, new] = e.changes["description"]
        %{old: old, new: new, actor_id: e.actor_id, actor_name: e.actor_name}
      end
    end

    setup %{scope: scope, cash: cash} do
      %{
        tx:
          post!(scope, %{
            "type" => "expense",
            "account_id" => cash.id,
            "amount" => "10",
            "description" => "Prodcuts"
          })
      }
    end

    test "the description can be changed and every change is recorded", %{
      scope: scope,
      user: user,
      tx: tx
    } do
      assert {:ok, %{description: "Products"}} =
               Ledger.update(scope, tx.id, %{"description" => "Products"})

      assert {:ok, %{description: nil}} = Ledger.update(scope, tx.id, %{"description" => nil})

      assert [first, second] = description_edits(scope, tx.id)

      assert {first.old, first.new} == {"Prodcuts", "Products"}

      assert {second.old, second.new} == {"Products", nil}
      assert first.actor_id == user.id
      assert first.actor_name == "Test User"
    end

    test "an unchanged description writes nothing", %{scope: scope, tx: tx} do
      assert {:ok, ^tx} = Ledger.update(scope, tx.id, %{"description" => "Prodcuts"})
      assert description_edits(scope, tx.id) == []
    end

    test "money, accounts, categories and dates cannot be edited", %{scope: scope, tx: tx} do
      for field <- ~w(amount account_id category_id occurred_on lines type) do
        assert {:error, {:invalid, %{^field => %{code: :immutable}}}} =
                 Ledger.update(scope, tx.id, %{field => "x", "description" => "y"})
      end

      assert {:error, {:invalid, %{"description" => %{code: :required}}}} =
               Ledger.update(scope, tx.id, %{})

      assert {:ok, %{description: "Prodcuts", entries: entries}} = Ledger.get(scope, tx.id)
      assert entries == tx.entries
    end

    test "any member can edit; the change names them", %{scope: scope, tx: tx} do
      member = register!("member@example.com")
      {:ok, invitation} = Workspaces.invite(scope, %{"email" => "member@example.com"})
      {:ok, _} = Workspaces.accept_invitation(member.user, invitation.id)
      {:ok, member_scope} = Workspaces.authorize(member.user.id, scope.workspace_id)

      assert {:ok, _} = Ledger.update(member_scope, tx.id, %{"description" => "Groceries"})
      assert [%{actor_id: by}] = description_edits(scope, tx.id)
      assert by == member.user.id
    end

    test "other workspaces cannot edit or read the history", %{tx: tx} do
      %{scope: other} = register!()

      assert Ledger.update(other, tx.id, %{"description" => "x"}) == {:error, :not_found}
      assert description_edits(other, tx.id) == []
    end

    test "concurrent edits form an unbroken history", %{scope: scope, tx: tx} do
      1..6
      |> Enum.map(fn i ->
        Task.async(fn -> Ledger.update(scope, tx.id, %{"description" => "v#{i}"}) end)
      end)
      |> Enum.each(&Task.await/1)

      changes = description_edits(scope, tx.id)
      {:ok, %{description: final}} = Ledger.get(scope, tx.id)

      assert length(changes) == 6
      assert hd(changes).old == "Prodcuts"
      assert List.last(changes).new == final

      for [a, b] <- Enum.chunk_every(changes, 2, 1, :discard),
          do: assert(b.old == a.new)
    end

    test "the database refuses an edit without an author and keeps the history append-only",
         %{scope: scope, tx: tx} do
      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               DB.query("UPDATE transactions SET description = 'sneaky' WHERE id = $1", [tx.id])

      assert message =~ "requires networth.user_id"

      {:ok, _} = Ledger.update(scope, tx.id, %{"description" => "Products"})

      for sql <- [
            "UPDATE activity_log SET data = '{}' WHERE subject_id = $1",
            "DELETE FROM activity_log WHERE subject_id = $1"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} = DB.query(sql, [tx.id])
        assert message =~ "append-only"
      end
    end
  end
end
