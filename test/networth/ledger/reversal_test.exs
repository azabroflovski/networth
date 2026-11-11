defmodule Networth.Ledger.ReversalTest do
  use Networth.DataCase

  setup :ledger_setup

  describe "reversal" do
    test "reverses every entry and restores balances", %{scope: scope, usd: usd, card: card} do
      tx =
        post!(scope, %{
          "type" => "exchange",
          "from_account_id" => usd.id,
          "from_amount" => "100",
          "to_account_id" => card.id,
          "to_amount" => "1270000"
        })

      assert {:ok, reversal} = Ledger.reverse(scope, tx.id, %{"description" => "wrong amount"})

      assert reversal.type == "reversal"
      assert reversal.reverses_id == tx.id
      assert Enum.map(reversal.entries, & &1.amount) == Enum.map(tx.entries, &(-&1.amount))
      assert {:ok, %{reversed_by_id: reversed_by}} = Ledger.get(scope, tx.id)
      assert reversed_by == reversal.id
      assert balance(scope, usd.id) == 50_000
      assert balance(scope, card.id) == 0
      assert ledger_totals(scope) == [%{currency: "USD", total: 0}, %{currency: "UZS", total: 0}]
    end

    test "a reversal is dated like the original unless a date is given", %{
      scope: scope,
      cash: cash
    } do
      a =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "1",
          "occurred_on" => "2026-03-15"
        })

      b =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "1",
          "occurred_on" => "2026-03-15"
        })

      assert {:ok, %{occurred_on: ~D[2026-03-15]}} = Ledger.reverse(scope, a.id)

      assert {:ok, %{occurred_on: ~D[2026-11-01]}} =
               Ledger.reverse(scope, b.id, %{"occurred_on" => "2026-11-01"})
    end

    test "correction is a reversal plus a new transaction; history is preserved", %{
      scope: scope,
      cash: cash
    } do
      wrong = post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "500"})
      {:ok, _} = Ledger.reverse(scope, wrong.id)
      post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "50"})

      assert balance(scope, cash.id) == 99_995_000

      list = fn params ->
        {:ok, %{transactions: txs}} = Ledger.list(scope, Map.put(params, "account_id", cash.id))
        Enum.map(txs, & &1.type)
      end

      assert list.(%{"include_reversed" => "true"}) ==
               ~w(expense reversal expense opening_balance)

      assert list.(%{}) == ~w(expense opening_balance)
    end

    test "a transaction is reversed once; repeating returns the same reversal", %{
      scope: scope,
      cash: cash
    } do
      tx = post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "1"})
      {:ok, reversal} = Ledger.reverse(scope, tx.id)

      assert Ledger.reverse(scope, tx.id) == {:ok, reversal}
      assert balance(scope, cash.id) == 100_000_000
      assert {:error, {:invalid, _}} = Ledger.reverse(scope, reversal.id)
      assert Ledger.reverse(scope, missing_id()) == {:error, :not_found}
    end

    test "concurrent reversals of the same transaction post one reversal", %{
      scope: scope,
      cash: cash
    } do
      tx = post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "1"})

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> Ledger.reverse(scope, tx.id) end) end)
        |> Enum.map(&Task.await/1)

      assert [{:ok, reversal}] = Enum.uniq(results)
      assert reversal.reverses_id == tx.id
      assert balance(scope, cash.id) == 100_000_000
    end

    test "reversal is allowed on archived accounts", %{scope: scope, card: card} do
      tx = post!(scope, %{"type" => "income", "account_id" => card.id, "amount" => "1"})
      {:ok, _} = Accounts.update(scope, card.id, %{"archived" => true})

      assert {:ok, _} = Ledger.reverse(scope, tx.id)
      assert balance(scope, card.id) == 0
    end
  end
end
