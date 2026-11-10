defmodule Networth.IsolationTest do
  @moduledoc "Data of one workspace must never be reachable from another."
  use Networth.DataCase

  setup do
    alice = register!()
    bob = register!()
    {:ok, family} = Workspaces.create(alice.user.id, %{"name" => "Family"})
    {:ok, family_scope} = Workspaces.authorize(alice.user.id, family.id)

    alice_cash = account!(alice.scope, %{"opening_balance" => "100"})
    bob_cash = account!(bob.scope, %{"opening_balance" => "100"})
    {:ok, bob_tag} = Tags.create(bob.scope, %{"name" => "Private"})

    bob_tx =
      post!(bob.scope, %{"type" => "expense", "account_id" => bob_cash.id, "amount" => "1"})

    %{
      alice: alice,
      bob: bob,
      family_scope: family_scope,
      alice_cash: alice_cash,
      bob_cash: bob_cash,
      bob_tag: bob_tag,
      bob_tx: bob_tx
    }
  end

  test "reads are limited to the scope's workspace", ctx do
    assert Accounts.get(ctx.alice.scope, ctx.bob_cash.id) == {:error, :not_found}
    assert Ledger.get(ctx.alice.scope, ctx.bob_tx.id) == {:error, :not_found}
    assert Tags.get(ctx.alice.scope, ctx.bob_tag.id) == {:error, :not_found}
    assert Enum.map(Accounts.list(ctx.alice.scope), & &1.id) == [ctx.alice_cash.id]
    assert {:ok, %{transactions: [_opening]}} = Ledger.list(ctx.alice.scope)

    assert {:ok, %{transactions: []}} =
             Ledger.list(ctx.alice.scope, %{"account_id" => ctx.bob_cash.id})
  end

  test "personal and family workspaces of the same user are independent", ctx do
    assert Accounts.list(ctx.family_scope) == []
    assert Accounts.get(ctx.family_scope, ctx.alice_cash.id) == {:error, :not_found}
    assert {:ok, %{transactions: []}} = Ledger.list(ctx.family_scope)

    family_food = category_id(ctx.family_scope, "Food")
    personal_food = category_id(ctx.alice.scope, "Food")
    refute family_food == personal_food
  end

  test "writes cannot reference another workspace's data", ctx do
    s = ctx.alice.scope

    assert {:error, {:invalid, %{"account_id" => "does not exist"}}} =
             Ledger.post(s, %{
               "type" => "expense",
               "account_id" => ctx.bob_cash.id,
               "amount" => "1"
             })

    assert {:error, {:invalid, %{"to_account_id" => "does not exist"}}} =
             Ledger.post(s, %{
               "type" => "transfer",
               "from_account_id" => ctx.alice_cash.id,
               "to_account_id" => ctx.bob_cash.id,
               "amount" => "1"
             })

    assert {:error, {:invalid, %{"category_id" => "does not exist"}}} =
             Ledger.post(s, %{
               "type" => "expense",
               "account_id" => ctx.alice_cash.id,
               "amount" => "1",
               "category_id" => category_id(ctx.bob.scope, "Food")
             })

    assert {:error, {:invalid, %{"tag_ids" => _}}} =
             Ledger.post(s, %{
               "type" => "expense",
               "account_id" => ctx.alice_cash.id,
               "amount" => "1",
               "tag_ids" => [ctx.bob_tag.id]
             })

    assert Ledger.reverse(s, ctx.bob_tx.id) == {:error, :not_found}
    assert Ledger.set_tags(s, ctx.bob_tx.id, %{"tag_ids" => []}) == {:error, :not_found}
    assert Accounts.update(s, ctx.bob_cash.id, %{"name" => "Mine"}) == {:error, :not_found}
    assert Tags.delete(s, ctx.bob_tag.id) == {:error, :not_found}

    assert {:error, {:invalid, %{"parent_id" => "does not exist"}}} =
             Categories.create(s, %{
               "name" => "X",
               "parent_id" => category_id(ctx.bob.scope, "Food")
             })

    assert balance(ctx.bob.scope, ctx.bob_cash.id) == 9900
  end

  test "the database rejects cross-workspace references", ctx do
    s = ctx.alice.scope

    {:ok, %{transactions: own_tx}} = Ledger.list(s)
    own_tx = hd(own_tx)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             DB.query(
               "INSERT INTO ledger_entries (workspace_id, transaction_id, account_id, currency, account_kind, amount) VALUES ($1, $2, $3, 'USD', 'asset', 1)",
               [s.workspace_id, own_tx.id, ctx.bob_cash.id]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             DB.query(
               "INSERT INTO transaction_tags (workspace_id, transaction_id, tag_id) VALUES ($1, $2, $3)",
               [
                 s.workspace_id,
                 own_tx.id,
                 ctx.bob_tag.id
               ]
             )
  end
end
