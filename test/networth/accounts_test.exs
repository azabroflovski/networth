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

    assert {:ok, %{transactions: [opening]}} = Ledger.list(scope, %{"account_id" => account.id})
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

  describe "idempotency" do
    setup do
      %{
        params: %{
          "name" => "Card",
          "type" => "card",
          "currency" => "UZS",
          "opening_balance" => "5000000",
          "idempotency_key" => "create-card"
        }
      }
    end

    test "a retried request returns the account and posts the opening balance once",
         %{scope: scope, params: params} do
      {:ok, first} = Accounts.create(scope, params)
      {:ok, second} = Accounts.create(scope, params)

      assert first == second
      assert [%{balance: 500_000_000}] = Accounts.list(scope)
      assert {:ok, %{transactions: [_opening]}} = Ledger.list(scope, %{"account_id" => first.id})
    end

    test "the same key with other params is rejected", %{scope: scope, params: params} do
      {:ok, _} = Accounts.create(scope, params)

      assert Accounts.create(scope, %{params | "opening_balance" => "1"}) ==
               {:error, :idempotency_key_reused}
    end

    test "concurrent requests with the same key create one account", %{
      scope: scope,
      params: params
    } do
      results =
        1..6
        |> Enum.map(fn _ -> Task.async(fn -> Accounts.create(scope, params) end) end)
        |> Enum.map(&Task.await/1)

      assert [{:ok, _}] = Enum.uniq(results)
      assert [%{balance: 500_000_000}] = Accounts.list(scope)
    end
  end

  describe "debts" do
    setup %{scope: scope} do
      %{
        cash:
          account!(scope, %{"name" => "Cash", "currency" => "USD", "opening_balance" => "1000"})
      }
    end

    test "money lent is an asset that shrinks as it is repaid or forgiven", %{
      scope: scope,
      cash: cash
    } do
      sasha = account!(scope, %{"name" => "Sasha", "type" => "receivable", "currency" => "USD"})
      assert sasha.kind == "asset"

      post!(scope, %{
        "type" => "transfer",
        "from_account_id" => cash.id,
        "to_account_id" => sasha.id,
        "amount" => "100"
      })

      post!(scope, %{
        "type" => "transfer",
        "from_account_id" => sasha.id,
        "to_account_id" => cash.id,
        "amount" => "60"
      })

      assert balance(scope, sasha.id) == 4000

      {:ok, written_off} =
        Categories.create(scope, %{"name" => "Written-off debts", "kind" => "expense"})

      post!(scope, %{
        "type" => "expense",
        "account_id" => sasha.id,
        "amount" => "40",
        "category_id" => written_off.id
      })

      assert balance(scope, sasha.id) == 0
      assert balance(scope, cash.id) == 96_000
    end

    test "money borrowed is a liability that grows and is paid back", %{scope: scope, cash: cash} do
      mom = account!(scope, %{"name" => "Mom", "type" => "payable", "currency" => "USD"})
      assert mom.kind == "liability"

      post!(scope, %{
        "type" => "transfer",
        "from_account_id" => mom.id,
        "to_account_id" => cash.id,
        "amount" => "500"
      })

      assert balance(scope, mom.id) == 50_000
      assert balance(scope, cash.id) == 150_000

      post!(scope, %{
        "type" => "transfer",
        "from_account_id" => cash.id,
        "to_account_id" => mom.id,
        "amount" => "200"
      })

      assert balance(scope, mom.id) == 30_000
    end

    test "an existing debt can be entered as an opening balance", %{scope: scope} do
      bank =
        account!(scope, %{
          "name" => "Friend",
          "type" => "payable",
          "currency" => "USD",
          "opening_balance" => "250"
        })

      assert bank.balance == 25_000
      assert ledger_totals(scope) == [%{currency: "USD", total: 0}]
    end

    test "debts count in net worth", %{scope: scope, cash: cash} do
      sasha = account!(scope, %{"name" => "Sasha", "type" => "receivable", "currency" => "USD"})
      mom = account!(scope, %{"name" => "Mom", "type" => "payable", "currency" => "USD"})

      post!(scope, %{
        "type" => "transfer",
        "from_account_id" => cash.id,
        "to_account_id" => sasha.id,
        "amount" => "100"
      })

      post!(scope, %{
        "type" => "transfer",
        "from_account_id" => mom.id,
        "to_account_id" => cash.id,
        "amount" => "300"
      })

      {:ok, %{currencies: [usd]}} = Networth.Reports.net_worth(scope, %{})

      # Lending moves money between assets; borrowing adds cash and an equal debt.
      assert usd == %{currency: "USD", assets: 130_000, liabilities: 30_000, net: 100_000}
    end
  end
end
