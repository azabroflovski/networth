defmodule Networth.Ledger.CorrectionTest do
  use Networth.DataCase

  setup :ledger_setup

  describe "correct/3" do
    setup %{scope: scope, cash: cash} do
      {:ok, tag} = Tags.create(scope, %{"name" => "Home"})

      tx =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "500",
          "category_id" => category_id(scope, "Food"),
          "occurred_on" => "2026-10-05",
          "description" => "Groceries",
          "tag_ids" => [tag.id]
        })

      %{tx: tx, tag: tag}
    end

    test "replaces the operation, keeping date, description and tags by default",
         %{scope: scope, cash: cash, tx: tx, tag: tag} do
      assert {:ok, fixed} =
               Ledger.correct(scope, tx.id, %{
                 "type" => "expense",
                 "account_id" => cash.id,
                 "amount" => "50"
               })

      assert fixed.replaces_id == tx.id

      assert {fixed.occurred_on, fixed.description, fixed.tag_ids} ==
               {~D[2026-10-05], "Groceries", [tag.id]}

      assert balance(scope, cash.id) == 100_000_000 - 5_000

      {:ok, original} = Ledger.get(scope, tx.id)

      assert {:ok, %{type: "reversal", occurred_on: ~D[2026-10-05]}} =
               Ledger.get(scope, original.reversed_by_id)

      # The history shows only the current version.
      {:ok, %{transactions: history}} = Ledger.list(scope, %{"type" => "expense"})
      assert Enum.map(history, & &1.id) == [fixed.id]
    end

    test "can change anything, including the type and the account", %{
      scope: scope,
      card: card,
      tx: tx
    } do
      assert {:ok, fixed} =
               Ledger.correct(scope, tx.id, %{
                 "type" => "income",
                 "account_id" => card.id,
                 "amount" => "7",
                 "occurred_on" => "2026-10-06",
                 "tag_ids" => []
               })

      assert {fixed.type, fixed.occurred_on, fixed.tag_ids} == {"income", ~D[2026-10-06], []}
      assert balance(scope, card.id) == 700
    end

    test "a correction can itself be corrected", %{scope: scope, cash: cash, tx: tx} do
      {:ok, first} =
        Ledger.correct(scope, tx.id, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "50"
        })

      {:ok, second} =
        Ledger.correct(scope, first.id, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "60"
        })

      assert second.replaces_id == first.id
      assert balance(scope, cash.id) == 100_000_000 - 6_000
    end

    test "an operation is corrected once; invalid input changes nothing", %{
      scope: scope,
      cash: cash,
      tx: tx
    } do
      params = %{"type" => "expense", "account_id" => cash.id, "amount" => "50"}

      assert {:error, {:invalid, %{"amount" => _}}} =
               Ledger.correct(scope, tx.id, %{params | "amount" => "0"})

      assert {:ok, %{reversed_by_id: nil}} = Ledger.get(scope, tx.id)

      {:ok, _} = Ledger.correct(scope, tx.id, params)
      assert Ledger.correct(scope, tx.id, params) == {:error, :already_reversed}
      assert balance(scope, cash.id) == 100_000_000 - 5_000
    end

    test "only regular operations can be corrected", %{scope: scope, cash: cash, tx: tx} do
      {:ok, reversal} = Ledger.reverse(scope, tx.id)

      {:ok, %{transactions: [opening]}} =
        Ledger.list(scope, %{"type" => "opening_balance", "account_id" => cash.id})

      params = %{"type" => "expense", "account_id" => cash.id, "amount" => "1"}

      assert {:error, {:invalid, %{"id" => _}}} = Ledger.correct(scope, reversal.id, params)
      assert {:error, {:invalid, %{"id" => _}}} = Ledger.correct(scope, opening.id, params)
      assert Ledger.correct(scope, missing_id(), params) == {:error, :not_found}
    end

    test "retries with an idempotency key return the correction", %{
      scope: scope,
      cash: cash,
      tx: tx
    } do
      params = %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "50",
        "idempotency_key" => "fix-1"
      }

      results =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Ledger.correct(scope, tx.id, params) end) end)
        |> Enum.map(&Task.await/1)

      assert [{:ok, %{replaces_id: replaces_id}}] = Enum.uniq(results)
      assert replaces_id == tx.id
      assert balance(scope, cash.id) == 100_000_000 - 5_000
    end

    test "concurrent corrections without a key: one wins", %{scope: scope, cash: cash, tx: tx} do
      results =
        for amount <- ~w(10 20 30 40) do
          Task.async(fn ->
            Ledger.correct(scope, tx.id, %{
              "type" => "expense",
              "account_id" => cash.id,
              "amount" => amount
            })
          end)
        end
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_reversed})) == 3
      assert ledger_totals(scope) == [%{currency: "USD", total: 0}, %{currency: "UZS", total: 0}]
    end
  end
end
