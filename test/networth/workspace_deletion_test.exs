defmodule Networth.WorkspaceDeletionTest do
  use Networth.DataCase

  @tables ~w(accounts categories tags transactions ledger_entries exchanges transaction_tags
             transaction_changes budgets workspace_invitations workspace_members)

  setup do
    owner = register!("owner@example.com")
    member = register!("member@example.com")
    stranger = register!("stranger@example.com")

    {:ok, family} = Workspaces.create(owner.user.id, %{"name" => "Family"})
    {:ok, scope} = Workspaces.authorize(owner.user.id, family.id)
    {:ok, invitation} = Workspaces.invite(scope, %{"email" => "member@example.com"})
    {:ok, _} = Workspaces.accept_invitation(member.user, invitation.id)
    {:ok, _} = Workspaces.invite(scope, %{"email" => "someone@example.com"})

    fill(scope)
    fill(owner.scope)
    fill(stranger.scope)

    %{owner: owner, member: member, stranger: stranger, family: family, scope: scope}
  end

  # Every kind of workspace data, so the purge has to handle all tables.
  defp fill(scope) do
    uzs = account!(scope, %{"currency" => "UZS", "opening_balance" => "1000000"})
    usd = account!(scope, %{"currency" => "USD", "opening_balance" => "100"})
    {:ok, tag} = Tags.create(scope, %{"name" => "Home"})
    food = category_id(scope, "Food")
    {:ok, cafe} = Categories.create(scope, %{"name" => "Cafe", "parent_id" => food})

    expense =
      post!(scope, %{
        "type" => "expense",
        "account_id" => uzs.id,
        "lines" => [
          %{"amount" => "10", "category_id" => food},
          %{"amount" => "5", "category_id" => cafe.id}
        ],
        "tag_ids" => [tag.id]
      })

    post!(scope, %{
      "type" => "exchange",
      "from_account_id" => usd.id,
      "from_amount" => "10",
      "to_account_id" => uzs.id,
      "to_amount" => "127000",
      "fee" => "1"
    })

    {:ok, _} = Ledger.update(scope, expense.id, %{"description" => "Lunch"})

    {:ok, _} =
      Ledger.correct(scope, expense.id, %{
        "type" => "expense",
        "account_id" => uzs.id,
        "amount" => "12"
      })

    {:ok, _} =
      Networth.Budgets.set(scope, %{"category_id" => food, "currency" => "UZS", "amount" => "500"})
  end

  defp counts(workspace_id) do
    Map.new(@tables, fn table ->
      %{n: n} =
        DB.one("SELECT count(*) AS n FROM #{table} WHERE workspace_id = $1", [workspace_id])

      {table, n}
    end)
  end

  defp make_due(workspace_id) do
    DB.query!(
      "UPDATE workspaces SET deletion_scheduled_at = now() - interval '1 second' WHERE id = $1",
      [
        workspace_id
      ]
    )
  end

  test "scheduling needs the owner and the exact name; the workspace keeps working", ctx do
    {:ok, member_scope} = Workspaces.authorize(ctx.member.user.id, ctx.family.id)

    assert Workspaces.schedule_deletion(member_scope, %{"confirm" => "Family"}) ==
             {:error, :forbidden}

    assert {:error, {:invalid, %{"confirm" => _}}} =
             Workspaces.schedule_deletion(ctx.scope, %{"confirm" => "family"})

    assert {:ok, %{deletion_scheduled_at: at}} =
             Workspaces.schedule_deletion(ctx.scope, %{"confirm" => "Family"})

    assert DateTime.diff(at, DateTime.utc_now(), :day) in 6..7

    assert {:ok, _} =
             Ledger.post(ctx.scope, %{
               "type" => "income",
               "account_id" => account!(ctx.scope).id,
               "amount" => "1"
             })

    assert {:ok, %{deletion_scheduled_at: nil}} = Workspaces.cancel_deletion(ctx.scope)
  end

  test "purges a due workspace with all its data and nothing else", ctx do
    personal_before = counts(ctx.owner.workspace.id)
    stranger_before = counts(ctx.stranger.workspace.id)
    assert Enum.all?(counts(ctx.family.id), fn {_table, n} -> n > 0 end)

    {:ok, _} = Workspaces.schedule_deletion(ctx.scope, %{"confirm" => "Family"})
    make_due(ctx.family.id)

    assert Workspaces.purge_due_deletions() == 1

    assert Enum.all?(counts(ctx.family.id), fn {_table, n} -> n == 0 end)
    assert DB.one("SELECT 1 AS one FROM workspaces WHERE id = $1", [ctx.family.id]) == nil
    assert Workspaces.authorize(ctx.owner.user.id, ctx.family.id) == {:error, :not_found}
    assert Workspaces.authorize(ctx.member.user.id, ctx.family.id) == {:error, :not_found}

    assert counts(ctx.owner.workspace.id) == personal_before
    assert counts(ctx.stranger.workspace.id) == stranger_before
    assert %{n: 3} = DB.one("SELECT count(*) AS n FROM users")

    assert ledger_totals(ctx.owner.scope) == [
             %{currency: "USD", total: 0},
             %{currency: "UZS", total: 0}
           ]
  end

  test "a workspace is not purged before its time or after cancellation", ctx do
    {:ok, _} = Workspaces.schedule_deletion(ctx.scope, %{"confirm" => "Family"})
    assert Workspaces.purge_due_deletions() == 0

    make_due(ctx.family.id)
    {:ok, _} = Workspaces.cancel_deletion(ctx.scope)
    assert Workspaces.purge_due_deletions() == 0

    assert {:ok, _} = Workspaces.authorize(ctx.owner.user.id, ctx.family.id)
  end

  test "the personal workspace can be deleted too", ctx do
    {:ok, _} = Workspaces.schedule_deletion(ctx.owner.scope, %{"confirm" => "Personal"})
    make_due(ctx.owner.workspace.id)

    assert Workspaces.purge_due_deletions() == 1
    assert [%{name: "Family"}] = Workspaces.list_for_user(ctx.owner.user.id)
  end

  test "ledger rows still cannot be deleted outside a purge of their workspace", ctx do
    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             DB.query("DELETE FROM ledger_entries WHERE workspace_id = $1", [ctx.family.id])

    assert message =~ "append-only"

    # The purge setting only unlocks the workspace it names.
    result =
      DB.transaction(fn ->
        DB.query!("SELECT set_config('networth.purge_workspace', $1, true)", [
          ctx.stranger.workspace.id
        ])

        DB.rollback(DB.query("DELETE FROM transactions WHERE workspace_id = $1", [ctx.family.id]))
      end)

    assert {:error, {:error, %Postgrex.Error{postgres: %{message: message}}}} = result
    assert message =~ "append-only"
  end

  test "deletion over HTTP", ctx do
    token = Users.create_token(ctx.owner.user.id)

    call = fn method, path, body ->
      conn =
        Plug.Test.conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Networth.Web.Router.call([])

      {conn.status, Jason.decode!(conn.resp_body)}
    end

    path = "/api/workspaces/#{ctx.family.id}"

    assert {422, _} = call.(:delete, path, %{confirm: "nope"})

    assert {202, %{"workspace" => %{"deletion_scheduled_at" => at}}} =
             call.(:delete, path, %{confirm: "Family"})

    assert is_binary(at)

    assert {200, %{"workspace" => %{"deletion_scheduled_at" => nil}}} =
             call.(:post, path <> "/restore", %{})
  end
end
