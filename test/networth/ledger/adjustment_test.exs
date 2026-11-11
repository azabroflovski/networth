defmodule Networth.Ledger.AdjustmentTest do
  use Networth.DataCase

  setup :ledger_setup

  describe "adjust_balance/3" do
    test "posts the difference so the balance matches reality", %{scope: scope, cash: cash} do
      assert {:ok, adjustment} =
               Ledger.adjust_balance(scope, cash.id, %{"balance" => "999900.50"})

      assert adjustment.type == "adjustment"

      assert [%{account_id: id, amount: -9_950}, %{account_type: "adjustment", amount: 9_950}] =
               adjustment.entries

      assert id == cash.id
      assert balance(scope, cash.id) == 99_990_050
      assert ledger_totals(scope) == [%{currency: "USD", total: 0}, %{currency: "UZS", total: 0}]
    end

    test "repeating the same adjustment posts nothing", %{scope: scope, cash: cash} do
      {:ok, _} = Ledger.adjust_balance(scope, cash.id, %{"balance" => "1000100"})
      assert Ledger.adjust_balance(scope, cash.id, %{"balance" => "1000100"}) == {:ok, nil}
      assert balance(scope, cash.id) == 100_010_000
    end

    test "a liability is adjusted to the amount owed", %{scope: scope} do
      credit =
        account!(scope, %{
          "type" => "credit_card",
          "currency" => "UZS",
          "opening_balance" => "300"
        })

      {:ok, _} = Ledger.adjust_balance(scope, credit.id, %{"balance" => "320"})
      assert balance(scope, credit.id) == 32_000
    end

    test "adjusts as of a past date without touching later operations", %{
      scope: scope,
      card: card
    } do
      post!(scope, %{
        "type" => "income",
        "account_id" => card.id,
        "amount" => "100",
        "occurred_on" => "2026-10-01"
      })

      post!(scope, %{
        "type" => "income",
        "account_id" => card.id,
        "amount" => "5",
        "occurred_on" => "2026-10-20"
      })

      {:ok, adjustment} =
        Ledger.adjust_balance(scope, card.id, %{"balance" => "90", "occurred_on" => "2026-10-10"})

      assert adjustment.occurred_on == ~D[2026-10-10]
      assert balance(scope, card.id) == 9_500
    end

    test "adjustments stay out of income and expense reports", %{scope: scope, cash: cash} do
      {:ok, _} =
        Ledger.adjust_balance(scope, cash.id, %{"balance" => "1", "occurred_on" => "2026-10-10"})

      assert {:ok, %{currencies: []}} =
               Networth.Reports.income_expense(scope, %{
                 "from" => "2026-10-01",
                 "to" => "2026-10-31"
               })
    end

    test "concurrent adjustments to the same balance post once", %{scope: scope, cash: cash} do
      1..5
      |> Enum.map(fn _ ->
        Task.async(fn -> Ledger.adjust_balance(scope, cash.id, %{"balance" => "123"}) end)
      end)
      |> Enum.each(&Task.await/1)

      assert balance(scope, cash.id) == 12_300
      assert {:ok, %{transactions: [_]}} = Ledger.list(scope, %{"type" => "adjustment"})
    end

    test "validates input", %{scope: scope, cash: cash, usd: usd} do
      %{scope: other} = register!()

      assert {:error, {:invalid, %{"balance" => _}}} = Ledger.adjust_balance(scope, cash.id, %{})

      assert {:error, {:invalid, %{"balance" => _}}} =
               Ledger.adjust_balance(scope, usd.id, %{"balance" => "1.001"})

      assert Ledger.adjust_balance(other, cash.id, %{"balance" => "1"}) == {:error, :not_found}

      {:ok, _} = Accounts.update(scope, cash.id, %{"archived" => true})

      assert {:error, {:invalid, %{"account_id" => _}}} =
               Ledger.adjust_balance(scope, cash.id, %{"balance" => "1"})
    end
  end
end
