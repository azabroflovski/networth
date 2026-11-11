defmodule Networth.ActivityTest do
  use Networth.DataCase

  alias Networth.{Activity, Budgets}

  setup do
    owner = register!("owner@example.com")
    member = register!("member@example.com")
    {:ok, family} = Workspaces.create(owner.user.id, %{"name" => "Family"})
    {:ok, scope} = Workspaces.authorize(owner.user.id, family.id)
    %{owner: owner, member: member, family: family, scope: scope}
  end

  defp actions(scope) do
    {:ok, %{events: events}} = Activity.list(scope, %{"limit" => "200"})
    events |> Enum.reverse() |> Enum.map(& &1.action)
  end

  defp last(scope) do
    {:ok, %{events: [event | _]}} = Activity.list(scope)
    event
  end

  test "every kind of change leaves an event, oldest to newest", ctx do
    s = ctx.scope

    {:ok, _} = Workspaces.update(s, %{"name" => "Home", "timezone" => "Asia/Tashkent"})
    {:ok, invitation} = Workspaces.invite(s, %{"email" => "member@example.com"})
    {:ok, other_invitation} = Workspaces.invite(s, %{"email" => "nobody@example.com"})
    :ok = Workspaces.revoke_invitation(s, other_invitation.id)
    {:ok, _} = Workspaces.accept_invitation(ctx.member.user, invitation.id)
    {:ok, _} = Workspaces.update_member(s, ctx.member.user.id, %{"role" => "owner"})

    cash = account!(s, %{"name" => "Cash", "currency" => "UZS", "opening_balance" => "1000"})
    {:ok, _} = Accounts.update(s, cash.id, %{"name" => "Wallet"})
    {:ok, category} = Categories.create(s, %{"name" => "Pets", "kind" => "expense"})
    {:ok, _} = Categories.update(s, category.id, %{"archived" => true})
    {:ok, tag} = Tags.create(s, %{"name" => "Trip"})
    {:ok, _} = Tags.update(s, tag.id, %{"color" => "#00aa00"})

    tx = post!(s, %{"type" => "expense", "account_id" => cash.id, "amount" => "100"})
    {:ok, _} = Ledger.update(s, tx.id, %{"description" => "Groceries"})
    {:ok, _} = Ledger.set_tags(s, tx.id, %{"tag_ids" => [tag.id]})

    {:ok, fixed} =
      Ledger.correct(s, tx.id, %{"type" => "expense", "account_id" => cash.id, "amount" => "80"})

    {:ok, _} = Ledger.reverse(s, fixed.id)
    {:ok, _} = Ledger.adjust_balance(s, cash.id, %{"balance" => "950"})
    :ok = Tags.delete(s, tag.id)

    {:ok, _} =
      Budgets.set(s, %{
        "category_id" => category_id(s, "Food"),
        "currency" => "UZS",
        "amount" => "500"
      })

    {:ok, _} = Workspaces.schedule_deletion(s, %{"confirm" => "Home"})
    {:ok, _} = Workspaces.cancel_deletion(s)

    {:ok, member_scope} = Workspaces.authorize(ctx.member.user.id, ctx.family.id)
    :ok = Workspaces.remove_member(member_scope, ctx.member.user.id)

    assert actions(s) == ~w(
             workspace.created workspace.updated invitation.created invitation.created
             invitation.revoked member.joined member.role_changed account.created account.updated
             category.created category.updated tag.created tag.updated transaction.posted
             transaction.description_changed transaction.tags_changed transaction.corrected
             transaction.reversed account.balance_adjusted tag.deleted budget.set
             workspace.deletion_scheduled workspace.deletion_cancelled member.left
           )
  end

  test "events carry the actor, the changes and a snapshot to render them", ctx do
    s = ctx.scope
    cash = account!(s, %{"name" => "Cash", "currency" => "UZS", "opening_balance" => "1000"})

    assert %{action: "account.created", actor_id: actor, actor_name: "Test User", data: data} =
             last(s)

    assert actor == ctx.owner.user.id

    assert data == %{
             "name" => "Cash",
             "type" => "cash",
             "currency" => "UZS",
             "opening_balance" => "1000.00"
           }

    {:ok, _} = Accounts.update(s, cash.id, %{"name" => "Wallet", "archived" => true})
    assert %{changes: %{"name" => ["Cash", "Wallet"], "archived" => [false, true]}} = last(s)
    {:ok, _} = Accounts.update(s, cash.id, %{"archived" => false})

    tx =
      post!(s, %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "100.50",
        "description" => "Lunch"
      })

    {:ok, _} =
      Ledger.correct(s, tx.id, %{"type" => "expense", "account_id" => cash.id, "amount" => "90"})

    assert %{
             action: "transaction.corrected",
             data: data,
             changes: %{"amounts" => [before, after_]}
           } = last(s)

    assert %{"type" => "expense", "description" => "Lunch"} = data
    assert [%{"account_name" => "Wallet", "amount" => "-100.50", "currency" => "UZS"}] = before
    assert [%{"amount" => "-90.00"}] = after_

    {:ok, _} =
      Budgets.set(s, %{
        "category_id" => category_id(s, "Food"),
        "currency" => "UZS",
        "amount" => "500"
      })

    {:ok, _} =
      Budgets.set(s, %{
        "category_id" => category_id(s, "Food"),
        "currency" => "UZS",
        "amount" => "700"
      })

    assert %{
             action: "budget.set",
             changes: %{"limit" => ["500.00", "700.00"]},
             data: %{"category_name" => "Food"}
           } =
             last(s)
  end

  test "failed or empty changes record nothing", ctx do
    s = ctx.scope
    cash = account!(s)
    before = actions(s)

    assert {:error, _} =
             Ledger.post(s, %{"type" => "expense", "account_id" => cash.id, "amount" => "0"})

    assert {:error, _} = Categories.create(s, %{"name" => "Food", "kind" => "expense"})
    assert {:error, _} = Tags.update(s, missing_id(), %{"name" => "x"})
    {:ok, _} = Accounts.update(s, cash.id, %{"name" => cash.name})
    {:ok, _} = Workspaces.update(s, %{"name" => "Family"})
    {:ok, _} = Workspaces.cancel_deletion(s)
    {:ok, _} = Ledger.adjust_balance(s, cash.id, %{"balance" => "0"})

    assert actions(s) == before
  end

  test "the log belongs to the workspace", ctx do
    account!(ctx.scope)
    account!(ctx.owner.scope)

    assert "account.created" in actions(ctx.owner.scope)
    # The member sees only the creation of their own personal workspace.
    assert actions(ctx.member.scope) == ["workspace.created"]
  end

  test "filters by subject and actor, paginates by cursor", ctx do
    s = ctx.scope
    cash = account!(s)

    for i <- 1..3,
        do: post!(s, %{"type" => "income", "account_id" => cash.id, "amount" => "#{i}"})

    {:ok, %{events: about_cash}} = Activity.list(s, %{"subject_id" => cash.id})
    assert Enum.map(about_cash, & &1.action) == ["account.created"]

    {:ok, %{events: by_member}} = Activity.list(s, %{"actor_id" => ctx.member.user.id})
    assert by_member == []

    {:ok, page1} = Activity.list(s, %{"limit" => "2"})
    {:ok, page2} = Activity.list(s, %{"limit" => "2", "cursor" => page1.next_cursor})
    {:ok, %{events: all}} = Activity.list(s, %{"limit" => "200"})

    assert Enum.map(page1.events ++ page2.events, & &1.id) ==
             all |> Enum.take(4) |> Enum.map(& &1.id)
  end

  test "the log is append-only", ctx do
    account!(ctx.scope)

    for sql <- ["UPDATE activity_events SET action = 'x.y'", "DELETE FROM activity_events"] do
      assert {:error, %Postgrex.Error{postgres: %{message: message}}} = DB.query(sql)
      assert message =~ "append-only"
    end
  end
end
