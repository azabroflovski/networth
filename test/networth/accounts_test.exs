defmodule Networth.AccountsTest do
  use Networth.DataCase

  setup do: register!()

  test "creates an account with a zero balance", %{scope: scope} do
    assert {:ok, account} =
             Accounts.create(scope, %{"name" => "Wallet", "type" => "cash", "currency" => "uzs"})

    assert %{name: "Wallet", type: "cash", kind: "asset", currency: "UZS", balance: 0} = account
    assert [%{id: id}] = Accounts.list(scope)
    assert id == account.id
  end

  test "an opening balance is posted through the ledger", %{scope: scope} do
    account = account!(scope, %{"opening_balance" => "150.25", "opened_on" => "2026-01-01"})
    assert account.balance == 15_025

    assert {:ok, [opening]} = Ledger.list(scope, %{"account_id" => account.id})
    assert opening.type == "opening_balance"
    assert opening.occurred_on == ~D[2026-01-01]
    assert ledger_totals(scope) == [%{currency: "USD", total: 0}]
  end

  test "a liability opening balance is the amount owed", %{scope: scope} do
    card = account!(scope, %{"type" => "credit_card", "opening_balance" => "300"})

    assert card.kind == "liability"
    assert card.balance == 30_000
    assert ledger_totals(scope) == [%{currency: "USD", total: 0}]
  end

  test "validates type, currency and amount precision", %{scope: scope} do
    assert {:error, {:invalid, %{"type" => _}}} =
             Accounts.create(scope, %{"name" => "X", "type" => "income", "currency" => "USD"})

    assert {:error, {:invalid, %{"currency" => "is not supported"}}} =
             Accounts.create(scope, %{"name" => "X", "type" => "cash", "currency" => "XXX"})

    assert {:error, {:invalid, %{"opening_balance" => "JPY allows at most 0 decimal places"}}} =
             Accounts.create(scope, %{
               "name" => "X",
               "type" => "cash",
               "currency" => "JPY",
               "opening_balance" => "1.5"
             })

    assert {:error, {:invalid, %{"opening_balance" => _}}} =
             Accounts.create(scope, %{
               "name" => "X",
               "type" => "cash",
               "currency" => "USD",
               "opening_balance" => 10.5
             })

    assert Accounts.list(scope) == []
  end

  test "names are unique among active accounts", %{scope: scope} do
    account = account!(scope, %{"name" => "Cash"})

    assert {:error, {:invalid, %{"name" => "already exists"}}} =
             Accounts.create(scope, %{"name" => "cash", "type" => "cash", "currency" => "EUR"})

    {:ok, _} = Accounts.update(scope, account.id, %{"archived" => true})

    assert {:ok, _} =
             Accounts.create(scope, %{"name" => "Cash", "type" => "cash", "currency" => "EUR"})
  end

  test "rename and archive; archived accounts reject new postings", %{scope: scope} do
    account = account!(scope)

    assert {:ok, %{name: "Renamed", archived_at: nil}} =
             Accounts.update(scope, account.id, %{"name" => "Renamed"})

    assert {:ok, %{archived_at: %DateTime{}}} =
             Accounts.update(scope, account.id, %{"archived" => true})

    assert {:error, {:invalid, %{"account_id" => "is archived"}}} =
             Ledger.post(scope, %{"type" => "income", "account_id" => account.id, "amount" => "1"})

    assert {:ok, %{archived_at: nil}} = Accounts.update(scope, account.id, %{"archived" => false})
  end

  test "currency and type cannot change once created", %{scope: scope} do
    account = account!(scope)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             DB.query("UPDATE accounts SET currency = 'EUR' WHERE id = $1", [account.id])
  end
end
