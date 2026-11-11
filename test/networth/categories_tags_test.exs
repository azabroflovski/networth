defmodule Networth.CategoriesTagsTest do
  use Networth.DataCase

  setup do: register!()

  describe "categories" do
    test "create a category and a subcategory that inherits its kind", %{scope: scope} do
      assert {:ok, parent} = Categories.create(scope, %{"name" => "Pets", "kind" => "expense"})
      assert {:ok, child} = Categories.create(scope, %{"name" => "Vet", "parent_id" => parent.id})

      assert child.kind == "expense"
      assert child.parent_id == parent.id
      refute child.system
    end

    test "subcategories are one level deep and share the parent's kind", %{scope: scope} do
      {:ok, parent} = Categories.create(scope, %{"name" => "Pets", "kind" => "expense"})
      {:ok, child} = Categories.create(scope, %{"name" => "Vet", "parent_id" => parent.id})

      assert {:error, {:invalid, %{"parent_id" => %{code: :not_top_level}}}} =
               Categories.create(scope, %{"name" => "Deeper", "parent_id" => child.id})

      assert {:error, {:invalid, %{"kind" => _}}} =
               Categories.create(scope, %{
                 "name" => "Odd",
                 "parent_id" => parent.id,
                 "kind" => "income"
               })
    end

    test "the database enforces depth and kind as well", %{scope: scope} do
      {:ok, parent} = Categories.create(scope, %{"name" => "Pets", "kind" => "expense"})
      {:ok, child} = Categories.create(scope, %{"name" => "Vet", "parent_id" => parent.id})

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               DB.query(
                 "INSERT INTO categories (workspace_id, parent_id, kind, name) VALUES ($1, $2, 'expense', 'X')",
                 [
                   scope.workspace_id,
                   child.id
                 ]
               )

      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               DB.query(
                 "INSERT INTO categories (workspace_id, parent_id, kind, name) VALUES ($1, $2, 'income', 'X')",
                 [
                   scope.workspace_id,
                   parent.id
                 ]
               )
    end

    test "names are unique per parent and kind, case-insensitively", %{scope: scope} do
      assert {:error, {:invalid, %{"name" => %{code: :already_exists}}}} =
               Categories.create(scope, %{"name" => "food", "kind" => "expense"})

      assert {:ok, _} = Categories.create(scope, %{"name" => "Food", "kind" => "income"})
      {:ok, travel} = Categories.create(scope, %{"name" => "Trips", "kind" => "expense"})
      assert {:ok, _} = Categories.create(scope, %{"name" => "Food", "parent_id" => travel.id})
    end

    test "archived categories cannot be used for new transactions", %{scope: scope} do
      cash = account!(scope)
      food = category_id(scope, "Food")

      assert {:ok, %{archived_at: %DateTime{}}} =
               Categories.update(scope, food, %{"archived" => true})

      assert {:error, {:invalid, %{"category_id" => %{code: :archived}}}} =
               Ledger.post(scope, %{
                 "type" => "expense",
                 "account_id" => cash.id,
                 "amount" => "1",
                 "category_id" => food
               })
    end

    test "the database allows categories only on entries of a matching income/expense account",
         %{scope: scope} do
      cash = account!(scope)
      tx = post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "1"})
      expense = Accounts.system_account(scope.workspace_id, "expense", "USD")

      insert = fn account, kind, category ->
        DB.query(
          """
          INSERT INTO ledger_entries (workspace_id, transaction_id, account_id, currency, account_kind, amount, category_id)
          VALUES ($1, $2, $3, 'USD', $4, 1, $5)
          """,
          [scope.workspace_id, tx.id, account.id, kind, category]
        )
      end

      # income category on an expense account
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               insert.(expense, "expense", category_id(scope, "Salary"))

      # any category on an asset account
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               insert.(cash, "asset", category_id(scope, "Food"))

      # account_kind that does not match the account
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               insert.(cash, "expense", category_id(scope, "Food"))
    end
  end

  describe "tags" do
    test "create, rename, recolor and delete", %{scope: scope} do
      assert {:ok, tag} = Tags.create(scope, %{"name" => "Vacation 2026", "color" => "#FF8800"})
      assert tag.color == "#ff8800"

      assert {:ok, %{name: "Trip", color: "#ff8800"}} =
               Tags.update(scope, tag.id, %{"name" => "Trip"})

      assert {:ok, %{color: nil}} = Tags.update(scope, tag.id, %{"color" => nil})
      assert Tags.delete(scope, tag.id) == :ok
      assert Tags.list(scope) == []
    end

    test "names are unique per workspace, case-insensitively", %{scope: scope} do
      {:ok, _} = Tags.create(scope, %{"name" => "Home"})

      assert {:error, {:invalid, %{"name" => %{code: :already_exists}}}} =
               Tags.create(scope, %{"name" => "home"})

      assert {:error, {:invalid, %{"color" => _}}} =
               Tags.create(scope, %{"name" => "X", "color" => "red"})
    end

    test "deleting a tag removes it from transactions but not the transactions", %{scope: scope} do
      cash = account!(scope)
      {:ok, tag} = Tags.create(scope, %{"name" => "Friends"})

      tx =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "1",
          "tag_ids" => [tag.id]
        })

      :ok = Tags.delete(scope, tag.id)
      assert {:ok, %{tag_ids: []}} = Ledger.get(scope, tx.id)
    end
  end
end
