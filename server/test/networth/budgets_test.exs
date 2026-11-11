defmodule Networth.BudgetsTest do
  use Networth.DataCase

  alias Networth.Budgets

  setup do
    %{scope: scope} = ctx = register!()

    uzs =
      account!(scope, %{
        "currency" => "UZS",
        "opening_balance" => "10000000",
        "opened_on" => "2026-01-01"
      })

    usd =
      account!(scope, %{
        "currency" => "USD",
        "opening_balance" => "1000",
        "opened_on" => "2026-01-01"
      })

    food = category_id(scope, "Food")
    {:ok, cafe} = Categories.create(scope, %{"name" => "Cafe", "parent_id" => food})

    Map.merge(ctx, %{
      uzs: uzs,
      usd: usd,
      food: food,
      cafe: cafe.id,
      transport: category_id(scope, "Transport")
    })
  end

  defp spend(ctx, account, amount, category, date) do
    post!(ctx.scope, %{
      "type" => "expense",
      "account_id" => account.id,
      "amount" => amount,
      "category_id" => category,
      "occurred_on" => date
    })
  end

  defp set!(ctx, attrs) do
    {:ok, budget} = Budgets.set(ctx.scope, Map.merge(%{"currency" => "UZS"}, attrs))
    budget
  end

  defp report(ctx, month) do
    {:ok, report} = Budgets.report(ctx.scope, %{"month" => month})
    Map.new(report.budgets, &{{&1.category_id, &1.currency}, &1})
  end

  test "limit, spending with subcategories, remaining and percent", ctx do
    set!(ctx, %{"category_id" => ctx.food, "amount" => "500", "month" => "2026-11"})
    spend(ctx, ctx.uzs, "100", ctx.food, "2026-11-03")
    spend(ctx, ctx.uzs, "50", ctx.cafe, "2026-11-04")
    spend(ctx, ctx.uzs, "30", ctx.transport, "2026-11-05")
    spend(ctx, ctx.uzs, "999", ctx.food, "2026-10-31")

    budget = report(ctx, "2026-11")[{ctx.food, "UZS"}]

    assert budget == %{
             category_id: ctx.food,
             name: "Food",
             currency: "UZS",
             limit: 50_000,
             spent: 15_000,
             remaining: 35_000,
             percent: 30
           }
  end

  test "a subcategory budget counts only that subcategory and can go over", ctx do
    set!(ctx, %{"category_id" => ctx.cafe, "amount" => "40", "month" => "2026-11"})
    spend(ctx, ctx.uzs, "100", ctx.food, "2026-11-03")
    spend(ctx, ctx.uzs, "50", ctx.cafe, "2026-11-04")

    assert [%{spent: 5_000, remaining: -1_000, percent: 125}] = Map.values(report(ctx, "2026-11"))
  end

  test "a limit applies from its month until changed; 0 ends it", ctx do
    set!(ctx, %{"category_id" => ctx.food, "amount" => "500", "month" => "2026-10"})
    set!(ctx, %{"category_id" => ctx.food, "amount" => "300", "month" => "2026-12"})
    set!(ctx, %{"category_id" => ctx.food, "amount" => "0", "month" => "2027-02"})

    limit = fn month -> report(ctx, month) |> Map.values() |> Enum.map(& &1.limit) end

    assert limit.("2026-09") == []
    assert limit.("2026-10") == [50_000]
    assert limit.("2026-11") == [50_000]
    assert limit.("2026-12") == [30_000]
    assert limit.("2027-01") == [30_000]
    assert limit.("2027-02") == []

    assert [
             %{starts_on: ~D[2027-02-01]},
             %{starts_on: ~D[2026-12-01]},
             %{starts_on: ~D[2026-10-01]}
           ] =
             Budgets.list(ctx.scope)
  end

  test "setting the same month again replaces the limit", ctx do
    set!(ctx, %{"category_id" => ctx.food, "amount" => "500", "month" => "2026-11"})
    set!(ctx, %{"category_id" => ctx.food, "amount" => "700", "month" => "2026-11"})

    assert [%{amount: 70_000}] = Budgets.list(ctx.scope)
  end

  test "currencies are budgeted separately", ctx do
    set!(ctx, %{
      "category_id" => ctx.food,
      "currency" => "USD",
      "amount" => "20",
      "month" => "2026-11"
    })

    spend(ctx, ctx.uzs, "100000", ctx.food, "2026-11-03")
    spend(ctx, ctx.usd, "5", ctx.food, "2026-11-03")

    assert [%{currency: "USD", spent: 500, limit: 2_000}] = Map.values(report(ctx, "2026-11"))
  end

  test "reversed spending does not count", ctx do
    set!(ctx, %{"category_id" => ctx.food, "amount" => "500", "month" => "2026-11"})
    tx = spend(ctx, ctx.uzs, "100", ctx.food, "2026-11-03")
    {:ok, _} = Ledger.reverse(ctx.scope, tx.id)

    assert [%{spent: 0, percent: 0}] = Map.values(report(ctx, "2026-11"))
  end

  test "the month defaults to the current one in the workspace timezone", ctx do
    {:ok, budget} =
      Budgets.set(ctx.scope, %{"category_id" => ctx.food, "currency" => "UZS", "amount" => "1"})

    {:ok, report} = Budgets.report(ctx.scope, %{})

    current = ctx.scope |> Workspaces.today() |> Date.beginning_of_month()
    assert budget.starts_on == current
    assert report.month == current
    assert [%{limit: 100}] = report.budgets
  end

  test "validates input", ctx do
    {:ok, _} = Categories.update(ctx.scope, ctx.transport, %{"archived" => true})

    base = %{
      "category_id" => ctx.food,
      "currency" => "UZS",
      "amount" => "1",
      "month" => "2026-11"
    }

    for {params, field} <- [
          {%{"category_id" => category_id(ctx.scope, "Salary")}, "category_id"},
          {%{"category_id" => ctx.transport}, "category_id"},
          {%{"category_id" => missing_id()}, "category_id"},
          {%{"currency" => "XXX"}, "currency"},
          {%{"amount" => "-1"}, "amount"},
          {%{"amount" => "0.001"}, "amount"},
          {%{"amount" => 1}, "amount"},
          {%{"month" => "2026-13"}, "month"},
          {%{"month" => "2026-1"}, "month"},
          {%{"month" => "2026-11-01"}, "month"}
        ] do
      assert {:error, {:invalid, errors}} = Budgets.set(ctx.scope, Map.merge(base, params))

      assert Map.has_key?(errors, field),
             "expected #{field} for #{inspect(params)}, got #{inspect(errors)}"
    end

    assert {:error, {:invalid, %{"month" => _}}} = Budgets.report(ctx.scope, %{"month" => "nope"})
  end

  test "budgets are limited to the workspace", ctx do
    %{scope: other} = register!()
    set!(ctx, %{"category_id" => ctx.food, "amount" => "500", "month" => "2026-11"})

    assert {:error, {:invalid, %{"category_id" => %{code: :not_found}}}} =
             Budgets.set(other, %{"category_id" => ctx.food, "currency" => "UZS", "amount" => "1"})

    assert Budgets.list(other) == []
    assert {:ok, %{budgets: []}} = Budgets.report(other, %{"month" => "2026-11"})
  end
end
