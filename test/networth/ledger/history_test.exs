defmodule Networth.Ledger.HistoryTest do
  use Networth.DataCase

  setup :ledger_setup

  describe "listing" do
    test "filters by account, category (with subcategories), tag, type and date", %{
      scope: scope,
      cash: cash,
      card: card
    } do
      food = category_id(scope, "Food")
      {:ok, cafe} = Categories.create(scope, %{"name" => "Cafe", "parent_id" => food})
      {:ok, friends} = Tags.create(scope, %{"name" => "Friends"})

      a =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "1",
          "category_id" => food,
          "occurred_on" => "2026-10-01"
        })

      b =
        post!(scope, %{
          "type" => "expense",
          "account_id" => card.id,
          "amount" => "1",
          "category_id" => cafe.id,
          "tag_ids" => [friends.id],
          "occurred_on" => "2026-10-05"
        })

      _c =
        post!(scope, %{
          "type" => "income",
          "account_id" => card.id,
          "amount" => "5",
          "occurred_on" => "2026-10-10"
        })

      ids = fn filters ->
        {:ok, %{transactions: txs}} = Ledger.list(scope, filters)
        Enum.map(txs, & &1.id)
      end

      assert ids.(%{"category_id" => food}) == [b.id, a.id]
      assert ids.(%{"category_id" => cafe.id}) == [b.id]
      assert ids.(%{"tag_id" => friends.id}) == [b.id]
      assert ids.(%{"type" => "expense", "account_id" => card.id}) == [b.id]
      assert ids.(%{"type" => "expense", "from" => "2026-10-02", "to" => "2026-10-09"}) == [b.id]
      assert length(ids.(%{"limit" => "2"})) == 2
      assert {:error, {:invalid, %{"limit" => _}}} = Ledger.list(scope, %{"limit" => "1000"})
    end

    test "cursor pagination walks every transaction exactly once", %{scope: scope, cash: cash} do
      # Several transactions share a date, so the order relies on the id tie-break.
      for {date, i} <-
            Enum.with_index(~w(2026-10-01 2026-10-01 2026-10-01 2026-10-02 2026-10-03 2026-10-03)) do
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "#{i + 1}",
          "occurred_on" => date
        })
      end

      {:ok, %{transactions: all, next_cursor: nil}} = Ledger.list(scope, %{"limit" => "200"})

      pages =
        Stream.unfold(%{"limit" => "2"}, fn
          nil ->
            nil

          params ->
            {:ok, page} = Ledger.list(scope, params)
            next = page.next_cursor && Map.put(params, "cursor", page.next_cursor)
            {page.transactions, next}
        end)
        |> Enum.to_list()

      # 6 expenses + 2 opening balances from setup = 8 rows.
      assert Enum.map(pages, &length/1) == [2, 2, 2, 2]
      assert pages |> List.flatten() |> Enum.map(& &1.id) == Enum.map(all, & &1.id)
    end

    test "the last full page has no next cursor", %{scope: scope, cash: cash} do
      # With the 2 opening balances from setup there are exactly 3 rows.
      post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "1"})

      assert {:ok, %{transactions: [_, _, _], next_cursor: nil}} =
               Ledger.list(scope, %{"limit" => "3"})
    end

    test "a cursor combines with filters and is stable when new transactions arrive",
         %{scope: scope, cash: cash, card: card} do
      for i <- 1..3,
          do:
            post!(scope, %{
              "type" => "income",
              "account_id" => card.id,
              "amount" => "#{i}",
              "occurred_on" => "2026-10-0#{i}"
            })

      {:ok, first} = Ledger.list(scope, %{"account_id" => card.id, "limit" => "2"})

      post!(scope, %{
        "type" => "income",
        "account_id" => card.id,
        "amount" => "9",
        "occurred_on" => "2026-10-09"
      })

      post!(scope, %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "1",
        "occurred_on" => "2026-10-01"
      })

      {:ok, second} =
        Ledger.list(scope, %{
          "account_id" => card.id,
          "limit" => "2",
          "cursor" => first.next_cursor
        })

      assert Enum.map(first.transactions ++ second.transactions, & &1.occurred_on) ==
               [~D[2026-10-03], ~D[2026-10-02], ~D[2026-10-01]]

      assert second.next_cursor == nil
    end

    test "rejects a malformed cursor", %{scope: scope} do
      for cursor <- [
            "garbage",
            Base.url_encode64("2026-10-01/not-a-uuid"),
            Base.url_encode64("x/y/z")
          ] do
        assert {:error, {:invalid, %{"cursor" => %{code: :invalid_cursor}}}} =
                 Ledger.list(scope, %{"cursor" => cursor})
      end
    end

    test "tags on a posted transaction can be replaced", %{scope: scope, cash: cash} do
      {:ok, a} = Tags.create(scope, %{"name" => "A"})
      {:ok, b} = Tags.create(scope, %{"name" => "B"})

      tx =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "1",
          "tag_ids" => [a.id]
        })

      assert {:ok, %{tag_ids: [b_id]}} = Ledger.set_tags(scope, tx.id, %{"tag_ids" => [b.id]})
      assert b_id == b.id
      assert {:ok, %{tag_ids: []}} = Ledger.set_tags(scope, tx.id, %{"tag_ids" => []})
    end
  end
end
