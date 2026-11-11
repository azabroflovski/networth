defmodule Networth.ReportsTest do
  use Networth.DataCase

  alias Networth.Reports

  # UZS and USD both have 2 decimal places.
  defp m(major), do: major * 100

  setup do
    %{scope: scope} = ctx = register!()
    opening = %{"opened_on" => "2026-10-01"}

    cash =
      account!(scope, Map.merge(opening, %{"currency" => "UZS", "opening_balance" => "1000000"}))

    card = account!(scope, Map.merge(opening, %{"type" => "card", "currency" => "UZS"}))
    usd = account!(scope, Map.merge(opening, %{"currency" => "USD", "opening_balance" => "500"}))

    food = category_id(scope, "Food")
    transport = category_id(scope, "Transport")
    {:ok, cafe} = Categories.create(scope, %{"name" => "Cafe", "parent_id" => food})

    post = fn attrs -> post!(scope, attrs) end

    post.(%{
      "type" => "expense",
      "account_id" => cash.id,
      "occurred_on" => "2026-10-05",
      "lines" => [
        %{"amount" => "100", "category_id" => food},
        %{"amount" => "50", "category_id" => cafe.id}
      ]
    })

    post.(%{
      "type" => "expense",
      "account_id" => card.id,
      "amount" => "30",
      "category_id" => transport,
      "occurred_on" => "2026-10-06"
    })

    post.(%{
      "type" => "expense",
      "account_id" => cash.id,
      "amount" => "20",
      "occurred_on" => "2026-10-07"
    })

    post.(%{
      "type" => "income",
      "account_id" => card.id,
      "amount" => "1000",
      "category_id" => category_id(scope, "Salary"),
      "occurred_on" => "2026-10-10"
    })

    post.(%{
      "type" => "expense",
      "account_id" => usd.id,
      "amount" => "5",
      "category_id" => food,
      "occurred_on" => "2026-10-12"
    })

    post.(%{
      "type" => "transfer",
      "from_account_id" => cash.id,
      "to_account_id" => card.id,
      "amount" => "100",
      "occurred_on" => "2026-10-15"
    })

    post.(%{
      "type" => "exchange",
      "from_account_id" => usd.id,
      "from_amount" => "100",
      "to_account_id" => card.id,
      "to_amount" => "1270000",
      "occurred_on" => "2026-10-16"
    })

    mistake =
      post.(%{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "40",
        "category_id" => transport,
        "occurred_on" => "2026-10-20"
      })

    {:ok, _} = Ledger.reverse(scope, mistake.id)

    post.(%{
      "type" => "expense",
      "account_id" => cash.id,
      "amount" => "70",
      "category_id" => food,
      "occurred_on" => "2026-11-02"
    })

    Map.merge(ctx, %{
      cash: cash,
      card: card,
      usd: usd,
      food: food,
      transport: transport,
      cafe: cafe
    })
  end

  describe "income_expense/2" do
    test "totals and category breakdown per currency for the period", ctx do
      {:ok, report} =
        Reports.income_expense(ctx.scope, %{"from" => "2026-10-01", "to" => "2026-10-31"})

      assert [usd, uzs] = report.currencies
      assert uzs.currency == "UZS"

      # Food 100 + Cafe 50 rolled up; Transport 30 (the reversed 40 nets out); 20 uncategorized.
      assert uzs.expense.total == m(200)

      assert [
               %{
                 category_id: food,
                 total: food_total,
                 subcategories: [%{category_id: cafe, total: cafe_total}]
               },
               %{category_id: transport, total: transport_total, subcategories: []},
               %{category_id: nil, name: nil, total: uncategorized}
             ] = uzs.expense.categories

      assert {food, cafe, transport} == {ctx.food, ctx.cafe.id, ctx.transport}

      assert {food_total, cafe_total, transport_total, uncategorized} ==
               {m(150), m(50), m(30), m(20)}

      assert %{total: income, categories: [%{name: "Salary"}]} = uzs.income
      assert income == m(1000)
      assert uzs.net == m(800)

      assert usd.currency == "USD"
      assert usd.expense.total == m(5)
      assert usd.income == %{total: 0, categories: []}
      assert usd.net == -m(5)
    end

    test "only operations dated inside the period count", ctx do
      {:ok, report} =
        Reports.income_expense(ctx.scope, %{"from" => "2026-11-01", "to" => "2026-11-30"})

      assert [%{currency: "UZS", expense: %{total: total}, income: %{total: 0}}] =
               report.currencies

      assert total == m(70)

      {:ok, empty} =
        Reports.income_expense(ctx.scope, %{"from" => "2026-09-01", "to" => "2026-09-30"})

      assert empty.currencies == []
    end

    test "a fully reversed category disappears", ctx do
      {:ok, report} =
        Reports.income_expense(ctx.scope, %{"from" => "2026-10-20", "to" => "2026-10-20"})

      assert report.currencies == []
    end

    test "another workspace's data is not counted", ctx do
      %{scope: other} = register!()
      other_cash = account!(other, %{"currency" => "UZS"})

      post!(other, %{
        "type" => "expense",
        "account_id" => other_cash.id,
        "amount" => "999",
        "occurred_on" => "2026-10-05"
      })

      {:ok, report} =
        Reports.income_expense(ctx.scope, %{"from" => "2026-10-01", "to" => "2026-10-31"})

      assert Enum.find(report.currencies, &(&1.currency == "UZS")).expense.total == m(200)
    end

    test "requires a valid period", ctx do
      assert {:error, {:invalid, %{"from" => %{code: :required}}}} =
               Reports.income_expense(ctx.scope, %{"to" => "2026-10-31"})

      assert {:error, {:invalid, %{"to" => _}}} =
               Reports.income_expense(ctx.scope, %{"from" => "2026-10-31", "to" => "2026-10-01"})
    end
  end

  describe "balances/2" do
    test "balances at the end of a given date", ctx do
      balances = fn on ->
        {:ok, %{accounts: accounts}} = Reports.balances(ctx.scope, %{"on" => on})
        Map.new(accounts, &{&1.id, &1.balance})
      end

      assert balances.("2026-09-30") == %{ctx.cash.id => 0, ctx.card.id => 0, ctx.usd.id => 0}

      assert balances.("2026-10-09") == %{
               ctx.cash.id => m(1_000_000 - 150 - 20),
               ctx.card.id => -m(30),
               ctx.usd.id => m(500)
             }

      oct = balances.("2026-10-31")
      assert oct[ctx.cash.id] == m(1_000_000 - 150 - 20 - 100)
      assert oct[ctx.card.id] == m(-30 + 1000 + 100 + 1_270_000)
      assert oct[ctx.usd.id] == m(500 - 5 - 100)

      # The latest date agrees with the current balance.
      assert balances.("2026-11-30")[ctx.cash.id] == balance(ctx.scope, ctx.cash.id)
    end

    test "requires a date", ctx do
      assert {:error, {:invalid, %{"on" => %{code: :required}}}} =
               Reports.balances(ctx.scope, %{})
    end
  end

  describe "net_worth/2" do
    test "assets, liabilities and net per currency", ctx do
      credit =
        account!(ctx.scope, %{
          "type" => "credit_card",
          "currency" => "UZS",
          "opening_balance" => "300",
          "opened_on" => "2026-10-01"
        })

      {:ok, _} = Accounts.update(ctx.scope, ctx.usd.id, %{"archived" => true})

      {:ok, report} = Reports.net_worth(ctx.scope, %{"on" => "2026-10-31"})

      uzs_assets = m(1_000_000 - 150 - 20 - 100) + m(-30 + 1000 + 100 + 1_270_000)

      assert report.currencies == [
               %{currency: "USD", assets: m(395), liabilities: 0, net: m(395)},
               %{
                 currency: "UZS",
                 assets: uzs_assets,
                 liabilities: m(300),
                 net: uzs_assets - m(300)
               }
             ]

      assert credit.kind == "liability"
    end

    test "defaults to today in the workspace timezone and agrees with current balances", ctx do
      {:ok, report} = Reports.net_worth(ctx.scope, %{})

      assert report.on == Workspaces.today(ctx.scope)

      expected =
        ctx.scope
        |> Accounts.list()
        |> Enum.filter(&(&1.currency == "UZS"))
        |> Enum.map(& &1.balance)
        |> Enum.sum()

      assert Enum.find(report.currencies, &(&1.currency == "UZS")).net == expected
    end

    test "before any account had money everything is zero", ctx do
      {:ok, report} = Reports.net_worth(ctx.scope, %{"on" => "2026-09-30"})

      assert Enum.all?(
               report.currencies,
               &(&1.assets == 0 and &1.liabilities == 0 and &1.net == 0)
             )
    end
  end

  describe "account_activity/3" do
    test "opening balance, money in and out, closing balance", ctx do
      {:ok, activity} =
        Reports.account_activity(ctx.scope, ctx.cash.id, %{
          "from" => "2026-10-05",
          "to" => "2026-10-31"
        })

      assert activity.opening_balance == m(1_000_000)
      # 150 + 20 + 100 transfer + 40 mistake out; the reversal brings 40 back in.
      assert activity.outflow == m(310)
      assert activity.inflow == m(40)
      assert activity.closing_balance == m(1_000_000 - 270)
    end

    test "uses the natural sign of a liability: debt growth is inflow", ctx do
      credit =
        account!(ctx.scope, %{
          "type" => "credit_card",
          "currency" => "UZS",
          "opening_balance" => "300",
          "opened_on" => "2026-10-01"
        })

      post!(ctx.scope, %{
        "type" => "expense",
        "account_id" => credit.id,
        "amount" => "50",
        "occurred_on" => "2026-10-03"
      })

      post!(ctx.scope, %{
        "type" => "transfer",
        "from_account_id" => ctx.cash.id,
        "to_account_id" => credit.id,
        "amount" => "100",
        "occurred_on" => "2026-10-04"
      })

      {:ok, activity} =
        Reports.account_activity(ctx.scope, credit.id, %{
          "from" => "2026-10-01",
          "to" => "2026-10-31"
        })

      assert {activity.opening_balance, activity.inflow, activity.outflow,
              activity.closing_balance} ==
               {0, m(350), m(100), m(250)}

      assert activity.closing_balance == balance(ctx.scope, credit.id)
    end

    test "is limited to the workspace", ctx do
      %{scope: other} = register!()
      params = %{"from" => "2026-10-01", "to" => "2026-10-31"}

      assert Reports.account_activity(other, ctx.cash.id, params) == {:error, :not_found}
    end
  end
end
