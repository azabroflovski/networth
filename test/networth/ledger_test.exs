defmodule Networth.LedgerTest do
  use Networth.DataCase

  setup do
    ctx = register!()

    cash =
      account!(ctx.scope, %{
        "name" => "Cash UZS",
        "currency" => "UZS",
        "opening_balance" => "1000000"
      })

    card = account!(ctx.scope, %{"name" => "Card UZS", "type" => "card", "currency" => "UZS"})

    usd =
      account!(ctx.scope, %{"name" => "Cash USD", "currency" => "USD", "opening_balance" => "500"})

    Map.merge(ctx, %{cash: cash, card: card, usd: usd})
  end

  describe "posting" do
    test "an expense debits the expense account and credits the source", %{
      scope: scope,
      cash: cash
    } do
      food = category_id(scope, "Food")

      tx =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "200000",
          "category_id" => food,
          "occurred_on" => "2026-11-10",
          "description" => "Groceries"
        })

      assert tx.type == "expense"
      assert tx.occurred_on == ~D[2026-11-10]

      assert [
               %{account_type: "expense", amount: 20_000_000, category_id: ^food},
               %{account_id: id, amount: -20_000_000, category_id: nil}
             ] = tx.entries

      assert id == cash.id
      assert balance(scope, cash.id) == 80_000_000
    end

    test "an income credits the income account", %{scope: scope, card: card} do
      tx =
        post!(scope, %{
          "type" => "income",
          "account_id" => card.id,
          "amount" => "15000000",
          "category_id" => category_id(scope, "Salary")
        })

      assert [
               %{account_id: id, amount: 1_500_000_000},
               %{account_type: "income", amount: -1_500_000_000}
             ] = tx.entries

      assert id == card.id
      assert balance(scope, card.id) == 1_500_000_000
    end

    test "an expense on a credit card increases the debt", %{scope: scope} do
      credit = account!(scope, %{"type" => "credit_card", "currency" => "USD"})
      post!(scope, %{"type" => "expense", "account_id" => credit.id, "amount" => "50"})

      assert balance(scope, credit.id) == 5000
    end

    test "a transfer moves money between accounts of the same currency", %{
      scope: scope,
      cash: cash,
      card: card
    } do
      tx =
        post!(scope, %{
          "type" => "transfer",
          "from_account_id" => cash.id,
          "to_account_id" => card.id,
          "amount" => "1000000"
        })

      assert Enum.all?(tx.entries, &is_nil(&1.category_id))
      assert balance(scope, cash.id) == 0
      assert balance(scope, card.id) == 100_000_000
    end

    test "transfers require distinct accounts and the same currency", %{
      scope: scope,
      cash: cash,
      usd: usd
    } do
      assert {:error, {:invalid, %{"to_account_id" => "must differ from from_account_id"}}} =
               Ledger.post(scope, %{
                 "type" => "transfer",
                 "from_account_id" => cash.id,
                 "to_account_id" => cash.id,
                 "amount" => "1"
               })

      assert {:error,
              {:invalid, %{"to_account_id" => "has a different currency; use an exchange"}}} =
               Ledger.post(scope, %{
                 "type" => "transfer",
                 "from_account_id" => usd.id,
                 "to_account_id" => cash.id,
                 "amount" => "1"
               })
    end

    test "an exchange balances each currency through exchange accounts and keeps the details",
         %{scope: scope, usd: usd, card: card} do
      tx =
        post!(scope, %{
          "type" => "exchange",
          "from_account_id" => usd.id,
          "from_amount" => "100",
          "to_account_id" => card.id,
          "to_amount" => "1270000"
        })

      assert balance(scope, usd.id) == 40_000
      assert balance(scope, card.id) == 127_000_000

      assert %{
               from_account_id: from_id,
               from_amount: 10_000,
               from_currency: "USD",
               to_account_id: to_id,
               to_amount: 127_000_000,
               to_currency: "UZS",
               rate: rate
             } = tx.exchange

      assert {from_id, to_id} == {usd.id, card.id}
      assert Decimal.equal?(rate, 12_700)
      assert ledger_totals(scope) == [%{currency: "USD", total: 0}, %{currency: "UZS", total: 0}]
    end

    test "an exchange fee is taken from the source account as an expense line",
         %{scope: scope, usd: usd, card: card} do
      {:ok, fees} = Categories.create(scope, %{"name" => "Bank fees", "kind" => "expense"})

      tx =
        post!(scope, %{
          "type" => "exchange",
          "from_account_id" => usd.id,
          "from_amount" => "100",
          "to_account_id" => card.id,
          "to_amount" => "1270000",
          "fee" => "1.50",
          "fee_category_id" => fees.id
        })

      assert balance(scope, usd.id) == 50_000 - 10_000 - 150
      assert balance(scope, card.id) == 127_000_000
      assert %{fee_amount: 150, rate: rate} = tx.exchange
      assert Decimal.equal?(rate, 12_700)

      assert Enum.any?(
               tx.entries,
               &(&1.account_type == "expense" and &1.amount == 150 and &1.category_id == fees.id)
             )

      assert ledger_totals(scope) == [%{currency: "USD", total: 0}, %{currency: "UZS", total: 0}]

      {:ok, _} = Ledger.reverse(scope, tx.id)
      assert balance(scope, usd.id) == 50_000
    end

    test "validates the exchange fee", %{scope: scope, usd: usd, card: card} do
      base = %{
        "type" => "exchange",
        "from_account_id" => usd.id,
        "from_amount" => "100",
        "to_account_id" => card.id,
        "to_amount" => "1270000"
      }

      for {params, field} <- [
            {%{"fee" => "-1"}, "fee"},
            {%{"fee" => "0.001"}, "fee"},
            {%{"fee" => 1}, "fee"},
            {%{"fee_category_id" => category_id(scope, "Food")}, "fee_category_id"},
            {%{"fee" => "1", "fee_category_id" => category_id(scope, "Salary")},
             "fee_category_id"},
            {%{"fee" => "1", "fee_category_id" => missing_id()}, "fee_category_id"}
          ] do
        assert {:error, {:invalid, errors}} = Ledger.post(scope, Map.merge(base, params))

        assert Map.has_key?(errors, field),
               "expected #{field} for #{inspect(params)}, got #{inspect(errors)}"
      end

      assert %{exchange: %{fee_amount: 0}} = post!(scope, Map.put(base, "fee", "0"))
    end

    test "an exchange between same-currency accounts is rejected", %{
      scope: scope,
      cash: cash,
      card: card
    } do
      assert {:error, {:invalid, %{"to_account_id" => _}}} =
               Ledger.post(scope, %{
                 "type" => "exchange",
                 "from_account_id" => cash.id,
                 "from_amount" => "1",
                 "to_account_id" => card.id,
                 "to_amount" => "1"
               })
    end

    test "currencies with 0 and 3 decimal places", %{scope: scope} do
      yen = account!(scope, %{"currency" => "JPY"})
      dinar = account!(scope, %{"currency" => "KWD"})

      post!(scope, %{"type" => "income", "account_id" => yen.id, "amount" => "1500"})
      post!(scope, %{"type" => "income", "account_id" => dinar.id, "amount" => "1.255"})

      assert balance(scope, yen.id) == 1500
      assert balance(scope, dinar.id) == 1255

      assert {:error, {:invalid, %{"amount" => "JPY allows at most 0 decimal places"}}} =
               Ledger.post(scope, %{"type" => "income", "account_id" => yen.id, "amount" => "1.5"})
    end

    test "rejects invalid operations", %{scope: scope, cash: cash} do
      base = %{"type" => "expense", "account_id" => cash.id, "amount" => "10"}

      for {override, field} <- [
            {%{"type" => "gift"}, "type"},
            {%{"amount" => "0"}, "amount"},
            {%{"amount" => "-10"}, "amount"},
            {%{"amount" => 10}, "amount"},
            {%{"amount" => nil}, "amount"},
            {%{"account_id" => missing_id()}, "account_id"},
            {%{"category_id" => category_id(scope, "Salary")}, "category_id"},
            {%{"occurred_on" => "yesterday"}, "occurred_on"},
            {%{"tag_ids" => [missing_id()]}, "tag_ids"}
          ] do
        assert {:error, {:invalid, errors}} = Ledger.post(scope, Map.merge(base, override))
        assert Map.has_key?(errors, field), "expected error on #{field} for #{inspect(override)}"
      end

      assert {:ok, %{transactions: [_]}} = Ledger.list(scope, %{"account_id" => cash.id})
    end

    test "every posting keeps the ledger balanced per currency", %{
      scope: scope,
      cash: cash,
      card: card,
      usd: usd
    } do
      post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "123.45"})
      post!(scope, %{"type" => "income", "account_id" => usd.id, "amount" => "10"})

      post!(scope, %{
        "type" => "transfer",
        "from_account_id" => cash.id,
        "to_account_id" => card.id,
        "amount" => "5"
      })

      post!(scope, %{
        "type" => "exchange",
        "from_account_id" => card.id,
        "from_amount" => "5",
        "to_account_id" => usd.id,
        "to_amount" => "0.01"
      })

      assert ledger_totals(scope) == [%{currency: "USD", total: 0}, %{currency: "UZS", total: 0}]
    end
  end

  describe "split" do
    test "one expense split across categories credits the account once", %{
      scope: scope,
      card: card
    } do
      {:ok, household} = Categories.create(scope, %{"name" => "Household", "kind" => "expense"})
      food = category_id(scope, "Food")

      tx =
        post!(scope, %{
          "type" => "expense",
          "account_id" => card.id,
          "description" => "Supermarket receipt",
          "lines" => [
            %{"amount" => "200000", "category_id" => food},
            %{"amount" => "100000", "category_id" => household.id}
          ]
        })

      assert [
               %{account_type: "expense", amount: 20_000_000, category_id: ^food},
               %{account_type: "expense", amount: 10_000_000, category_id: household_id},
               %{account_id: card_id, amount: -30_000_000, category_id: nil}
             ] = tx.entries

      assert {household_id, card_id} == {household.id, card.id}
      assert balance(scope, card.id) == -30_000_000

      ids = fn category ->
        {:ok, %{transactions: txs}} = Ledger.list(scope, %{"category_id" => category})
        Enum.map(txs, & &1.id)
      end

      assert ids.(food) == [tx.id]
      assert ids.(household.id) == [tx.id]
    end

    test "a split income debits the account once", %{scope: scope, card: card} do
      tx =
        post!(scope, %{
          "type" => "income",
          "account_id" => card.id,
          "lines" => [
            %{"amount" => "100", "category_id" => category_id(scope, "Salary")},
            %{"amount" => "50"}
          ]
        })

      assert [%{amount: 15_000}, %{amount: -10_000}, %{amount: -5_000, category_id: nil}] =
               tx.entries

      assert balance(scope, card.id) == 15_000
    end

    test "reversal negates every line with its category, so per-category totals net to zero",
         %{scope: scope, cash: cash} do
      food = category_id(scope, "Food")
      transport = category_id(scope, "Transport")

      tx =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "lines" => [
            %{"amount" => "10", "category_id" => food},
            %{"amount" => "5", "category_id" => transport}
          ]
        })

      {:ok, _} = Ledger.reverse(scope, tx.id)

      totals =
        DB.all(
          "SELECT category_id, sum(amount)::bigint AS total FROM ledger_entries WHERE workspace_id = $1 AND category_id IS NOT NULL GROUP BY category_id",
          [scope.workspace_id]
        )

      assert Enum.sort(Enum.map(totals, &{&1.category_id, &1.total})) ==
               Enum.sort([{food, 0}, {transport, 0}])
    end

    test "validates lines", %{scope: scope, cash: cash} do
      base = %{"type" => "expense", "account_id" => cash.id}
      food = category_id(scope, "Food")

      for {params, field} <- [
            {%{"lines" => []}, "lines"},
            {%{"lines" => "x"}, "lines"},
            {%{"lines" => [1]}, "lines"},
            {%{"lines" => [%{"amount" => "1"}], "amount" => "1"}, "lines"},
            {%{"lines" => [%{"amount" => "1"}], "category_id" => food}, "lines"},
            {%{"lines" => [%{"amount" => "1"}, %{"amount" => "0"}]}, "lines.1.amount"},
            {%{"lines" => [%{"amount" => "1.001"}]}, "lines.0.amount"},
            {%{"lines" => [%{"amount" => "1", "category_id" => category_id(scope, "Salary")}]},
             "lines.0.category_id"},
            {%{"lines" => List.duplicate(%{"amount" => "1"}, 51)}, "lines"},
            {%{"lines" => List.duplicate(%{"amount" => "90000000000000000.00"}, 2)}, "lines"}
          ] do
        assert {:error, {:invalid, errors}} = Ledger.post(scope, Map.merge(base, params))

        assert Map.has_key?(errors, field),
               "expected #{field} for #{inspect(params)}, got #{inspect(errors)}"
      end
    end
  end

  describe "client-generated ids" do
    @v7 "019a6c2e-7d3e-7b21-9f4a-1c2d3e4f5a6b"

    test "a transaction can be posted with an id generated by the client", %{
      scope: scope,
      cash: cash
    } do
      tx =
        post!(scope, %{
          "type" => "expense",
          "account_id" => cash.id,
          "amount" => "1",
          "id" => String.upcase(@v7)
        })

      assert tx.id == @v7
      assert {:ok, %{id: @v7}} = Ledger.get(scope, @v7)
    end

    test "a taken id is a conflict, not a replay", %{scope: scope, cash: cash} do
      params = %{"type" => "expense", "account_id" => cash.id, "amount" => "1", "id" => @v7}
      post!(scope, params)

      assert Ledger.post(scope, params) == {:error, :id_taken}
      assert balance(scope, cash.id) == 99_999_900

      %{scope: other} = register!()
      other_cash = account!(other)
      assert Ledger.post(other, %{params | "account_id" => other_cash.id}) == {:error, :id_taken}
    end

    test "with an idempotency key, a retry with the same id returns the transaction", %{
      scope: scope,
      cash: cash
    } do
      params = %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "1",
        "id" => @v7,
        "idempotency_key" => "k"
      }

      assert post!(scope, params).id == @v7
      assert post!(scope, params).id == @v7
      assert balance(scope, cash.id) == 99_999_900
    end

    test "concurrent retries with the same id and key return one transaction", %{
      scope: scope,
      cash: cash
    } do
      params = %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "1",
        "id" => @v7,
        "idempotency_key" => "k"
      }

      results =
        1..6
        |> Enum.map(fn _ -> Task.async(fn -> Ledger.post(scope, params) end) end)
        |> Enum.map(&Task.await/1)

      assert [{:ok, %{id: @v7}}] = Enum.uniq(results)
      assert balance(scope, cash.id) == 99_999_900
    end

    test "only UUIDv7 ids are accepted", %{scope: scope, cash: cash} do
      for id <- ["019a6c2e-7d3e-4b21-9f4a-1c2d3e4f5a6b", "42", 42] do
        assert {:error, {:invalid, %{"id" => "must be a UUIDv7"}}} =
                 Ledger.post(scope, %{
                   "type" => "expense",
                   "account_id" => cash.id,
                   "amount" => "1",
                   "id" => id
                 })
      end
    end

    test "concurrent posts with the same id post once", %{scope: scope, cash: cash} do
      params = %{"type" => "expense", "account_id" => cash.id, "amount" => "1", "id" => @v7}

      results =
        1..6
        |> Enum.map(fn _ -> Task.async(fn -> Ledger.post(scope, params) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :id_taken})) == 5
      assert balance(scope, cash.id) == 99_999_900
    end
  end

  describe "idempotency" do
    test "repeating a request with the same key returns the original transaction", %{
      scope: scope,
      cash: cash
    } do
      params = %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "10",
        "idempotency_key" => "abc"
      }

      first = post!(scope, params)
      second = post!(scope, params)

      assert first.id == second.id
      assert balance(scope, cash.id) == 99_999_000
    end

    test "reusing a key with different params is rejected", %{scope: scope, cash: cash} do
      params = %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "10",
        "idempotency_key" => "k"
      }

      post!(scope, params)

      assert Ledger.post(scope, %{params | "amount" => "11"}) == {:error, :idempotency_key_reused}
      assert balance(scope, cash.id) == 99_999_000
    end

    test "concurrent requests with the same key post once", %{scope: scope, cash: cash} do
      params = %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "10",
        "idempotency_key" => "race"
      }

      ids =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> post!(scope, params).id end) end)
        |> Enum.map(&Task.await/1)

      assert ids |> Enum.uniq() |> length() == 1
      assert balance(scope, cash.id) == 99_999_000
    end
  end

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
      assert {:ok, %{transactions: history}} = Ledger.list(scope, %{"account_id" => cash.id})
      assert Enum.map(history, & &1.type) == ~w(expense reversal expense opening_balance)
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

  describe "editing" do
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

      assert {:ok, [first, second]} = Ledger.changes(scope, tx.id)

      assert {first.field, first.old_value, first.new_value} ==
               {"description", "Prodcuts", "Products"}

      assert {second.old_value, second.new_value} == {"Products", nil}
      assert first.changed_by == user.id
      assert first.changed_by_name == "Test User"
    end

    test "an unchanged description writes nothing", %{scope: scope, tx: tx} do
      assert {:ok, ^tx} = Ledger.update(scope, tx.id, %{"description" => "Prodcuts"})
      assert {:ok, []} = Ledger.changes(scope, tx.id)
    end

    test "money, accounts, categories and dates cannot be edited", %{scope: scope, tx: tx} do
      for field <- ~w(amount account_id category_id occurred_on lines type) do
        assert {:error, {:invalid, %{^field => message}}} =
                 Ledger.update(scope, tx.id, %{field => "x", "description" => "y"})

        assert message =~ "reverse"
      end

      assert {:error, {:invalid, %{"description" => "is required"}}} =
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
      assert {:ok, [%{changed_by: by}]} = Ledger.changes(scope, tx.id)
      assert by == member.user.id
    end

    test "other workspaces cannot edit or read the history", %{tx: tx} do
      %{scope: other} = register!()

      assert Ledger.update(other, tx.id, %{"description" => "x"}) == {:error, :not_found}
      assert Ledger.changes(other, tx.id) == {:error, :not_found}
    end

    test "concurrent edits form an unbroken history", %{scope: scope, tx: tx} do
      1..6
      |> Enum.map(fn i ->
        Task.async(fn -> Ledger.update(scope, tx.id, %{"description" => "v#{i}"}) end)
      end)
      |> Enum.each(&Task.await/1)

      {:ok, changes} = Ledger.changes(scope, tx.id)
      {:ok, %{description: final}} = Ledger.get(scope, tx.id)

      assert length(changes) == 6
      assert hd(changes).old_value == "Prodcuts"
      assert List.last(changes).new_value == final

      for [a, b] <- Enum.chunk_every(changes, 2, 1, :discard),
          do: assert(b.old_value == a.new_value)
    end

    test "the database refuses an edit without an author and keeps the history append-only",
         %{scope: scope, tx: tx} do
      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               DB.query("UPDATE transactions SET description = 'sneaky' WHERE id = $1", [tx.id])

      assert message =~ "requires networth.user_id"

      {:ok, _} = Ledger.update(scope, tx.id, %{"description" => "Products"})

      for sql <- [
            "UPDATE transaction_changes SET new_value = 'x' WHERE transaction_id = $1",
            "DELETE FROM transaction_changes WHERE transaction_id = $1"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} = DB.query(sql, [tx.id])
        assert message =~ "append-only"
      end
    end
  end

  describe "concurrency" do
    test "concurrent transfers keep balances exact", %{scope: scope, cash: cash, card: card} do
      tasks =
        for i <- 1..20 do
          {from, to} = if rem(i, 2) == 0, do: {cash, card}, else: {card, cash}
          amount = if rem(i, 2) == 0, do: "1000", else: "10"

          Task.async(fn ->
            post!(scope, %{
              "type" => "transfer",
              "from_account_id" => from.id,
              "to_account_id" => to.id,
              "amount" => amount
            })
          end)
        end

      Enum.each(tasks, &Task.await/1)

      # 10 x 1000 cash -> card, 10 x 10 card -> cash
      assert balance(scope, cash.id) == 100_000_000 - 1_000_000 + 10_000
      assert balance(scope, card.id) == 1_000_000 - 10_000
      assert %{n: 20} = DB.one("SELECT count(*) AS n FROM transactions WHERE type = 'transfer'")
    end
  end

  describe "rollback" do
    test "a failure after writes started leaves no partial records", %{scope: scope, cash: cash} do
      before =
        DB.one(
          "SELECT count(*) AS t, (SELECT count(*) FROM ledger_entries) AS e FROM transactions"
        )

      # Tag ids are validated after the system expense account is created
      # inside the transaction; the whole transaction must roll back.
      assert {:error, {:invalid, _}} =
               Ledger.post(scope, %{
                 "type" => "expense",
                 "account_id" => cash.id,
                 "amount" => "1",
                 "tag_ids" => [missing_id()]
               })

      assert DB.one(
               "SELECT count(*) AS t, (SELECT count(*) FROM ledger_entries) AS e FROM transactions"
             ) == before

      assert %{n: 0} = DB.one("SELECT count(*) AS n FROM accounts WHERE type = 'expense'")
    end
  end

  describe "database invariants" do
    @describetag capture_log: true

    setup %{scope: scope, cash: cash} do
      %{tx: post!(scope, %{"type" => "expense", "account_id" => cash.id, "amount" => "1"})}
    end

    test "posted transactions and entries cannot be updated or deleted", %{tx: tx} do
      for sql <- [
            "UPDATE ledger_entries SET amount = amount * 2 WHERE transaction_id = $1",
            "DELETE FROM ledger_entries WHERE transaction_id = $1",
            "UPDATE transactions SET occurred_on = '2000-01-01' WHERE id = $1",
            "DELETE FROM transactions WHERE id = $1"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} = DB.query(sql, [tx.id])
        assert message =~ "append-only"
      end
    end

    test "unbalanced entries are rejected at commit", %{scope: scope, cash: cash} do
      assert_raise Postgrex.Error, ~r/transaction [0-9a-f-]{36} is not balanced/, fn ->
        DB.transaction(fn ->
          %{id: id} =
            DB.one(
              "INSERT INTO transactions (workspace_id, type, occurred_on, created_by) VALUES ($1, 'income', current_date, $2) RETURNING id",
              [scope.workspace_id, scope.user_id]
            )

          income = Accounts.system_account(scope.workspace_id, "income", "UZS")

          DB.query!(
            "INSERT INTO ledger_entries (workspace_id, transaction_id, account_id, currency, account_kind, amount) VALUES ($1, $2, $3, 'UZS', 'asset', 100), ($1, $2, $4, 'UZS', 'income', -99)",
            [scope.workspace_id, id, cash.id, income.id]
          )
        end)
      end

      assert {:ok, %{transactions: []}} = Ledger.list(scope, %{"type" => "income"})
    end

    test "a transaction without entries is rejected at commit", %{scope: scope} do
      assert_raise Postgrex.Error, ~r/fewer than two ledger entries/, fn ->
        DB.transaction(fn ->
          DB.query!(
            "INSERT INTO transactions (workspace_id, type, occurred_on, created_by) VALUES ($1, 'income', current_date, $2)",
            [scope.workspace_id, scope.user_id]
          )
        end)
      end
    end

    test "entries must match the account currency", %{scope: scope, cash: cash, usd: usd, tx: tx} do
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               DB.query(
                 "INSERT INTO ledger_entries (workspace_id, transaction_id, account_id, currency, account_kind, amount) VALUES ($1, $2, $3, 'USD', 'asset', 1), ($1, $2, $4, 'USD', 'asset', -1)",
                 [scope.workspace_id, tx.id, cash.id, usd.id]
               )
    end
  end

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
        assert {:error, {:invalid, %{"cursor" => "is invalid"}}} =
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
