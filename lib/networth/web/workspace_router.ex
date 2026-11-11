defmodule Networth.Web.WorkspaceRouter do
  @moduledoc """
  Routes inside one workspace, `/api/workspaces/:wid/...`. The request is
  made on behalf of a member: `authorize_workspace` puts the scope in
  `conn.assigns` before any route runs.
  """

  use Plug.Router

  import Networth.Web.{Auth, Response}

  alias Networth.{Accounts, Activity, Budgets, Categories, Ledger, Reports, Tags, Workspaces}
  alias Networth.Web.Serializer

  plug :authorize_workspace
  plug :match
  plug :dispatch

  # Workspace, members, invitations, activity

  get "/" do
    send_json(conn, 200, %{workspace: Serializer.workspace(Workspaces.get(scope(conn)))})
  end

  patch "/" do
    send_result(
      conn,
      Workspaces.update(scope(conn), conn.body_params),
      :workspace,
      &Serializer.workspace/1
    )
  end

  delete "/" do
    result = Workspaces.schedule_deletion(scope(conn), conn.body_params)
    send_result(conn, result, :workspace, &Serializer.workspace/1, 202)
  end

  post "/restore" do
    send_result(
      conn,
      Workspaces.cancel_deletion(scope(conn)),
      :workspace,
      &Serializer.workspace/1
    )
  end

  get "/members" do
    send_list(conn, Workspaces.list_members(scope(conn)), :members, &Serializer.member/1)
  end

  patch "/members/:user_id" do
    result = Workspaces.update_member(scope(conn), user_id, conn.body_params)
    send_result(conn, result, :member, &Serializer.member/1)
  end

  delete "/members/:user_id" do
    send_empty(conn, Workspaces.remove_member(scope(conn), user_id))
  end

  get "/invitations" do
    send_list(
      conn,
      Workspaces.list_invitations(scope(conn)),
      :invitations,
      &Serializer.invitation/1
    )
  end

  post "/invitations" do
    result = Workspaces.invite(scope(conn), conn.body_params)
    send_result(conn, result, :invitation, &Serializer.invitation/1, 201)
  end

  delete "/invitations/:id" do
    send_empty(conn, Workspaces.revoke_invitation(scope(conn), id))
  end

  get "/activity" do
    send_page(
      conn,
      Activity.list(scope(conn), conn.query_params),
      :events,
      &Serializer.activity_event/1
    )
  end

  # Accounts

  get "/accounts" do
    send_list(conn, Accounts.list(scope(conn)), :accounts, &Serializer.account/1)
  end

  post "/accounts" do
    send_result(
      conn,
      Accounts.create(scope(conn), conn.body_params),
      :account,
      &Serializer.account/1,
      201
    )
  end

  get "/accounts/:id" do
    send_result(conn, Accounts.get(scope(conn), id), :account, &Serializer.account/1)
  end

  patch "/accounts/:id" do
    send_result(
      conn,
      Accounts.update(scope(conn), id, conn.body_params),
      :account,
      &Serializer.account/1
    )
  end

  post "/accounts/:id/adjust" do
    case Ledger.adjust_balance(scope(conn), id, conn.body_params) do
      {:ok, nil} -> send_json(conn, 200, %{transaction: nil})
      result -> send_result(conn, result, :transaction, &Serializer.transaction/1, 201)
    end
  end

  get "/accounts/:id/activity" do
    result = Reports.account_activity(scope(conn), id, conn.query_params)
    send_result(conn, result, :activity, &Serializer.account_activity/1)
  end

  # Transactions

  get "/transactions" do
    send_page(
      conn,
      Ledger.list(scope(conn), conn.query_params),
      :transactions,
      &Serializer.transaction/1
    )
  end

  post "/transactions" do
    send_result(
      conn,
      Ledger.post(scope(conn), conn.body_params),
      :transaction,
      &Serializer.transaction/1,
      201
    )
  end

  get "/transactions/:id" do
    send_result(conn, Ledger.get(scope(conn), id), :transaction, &Serializer.transaction/1)
  end

  patch "/transactions/:id" do
    result = Ledger.update(scope(conn), id, conn.body_params)
    send_result(conn, result, :transaction, &Serializer.transaction/1)
  end

  post "/transactions/:id/correct" do
    result = Ledger.correct(scope(conn), id, conn.body_params)
    send_result(conn, result, :transaction, &Serializer.transaction/1, 201)
  end

  delete "/transactions/:id" do
    send_empty(conn, Ledger.reverse(scope(conn), id))
  end

  post "/transactions/:id/reverse" do
    result = Ledger.reverse(scope(conn), id, conn.body_params)
    send_result(conn, result, :transaction, &Serializer.transaction/1, 201)
  end

  put "/transactions/:id/tags" do
    result = Ledger.set_tags(scope(conn), id, conn.body_params)
    send_result(conn, result, :transaction, &Serializer.transaction/1)
  end

  # Categories and tags

  get "/categories" do
    send_list(conn, Categories.list(scope(conn)), :categories, &Serializer.category/1)
  end

  post "/categories" do
    result = Categories.create(scope(conn), conn.body_params)
    send_result(conn, result, :category, &Serializer.category/1, 201)
  end

  patch "/categories/:id" do
    result = Categories.update(scope(conn), id, conn.body_params)
    send_result(conn, result, :category, &Serializer.category/1)
  end

  get "/tags" do
    send_list(conn, Tags.list(scope(conn)), :tags, &Serializer.tag/1)
  end

  post "/tags" do
    send_result(conn, Tags.create(scope(conn), conn.body_params), :tag, &Serializer.tag/1, 201)
  end

  patch "/tags/:id" do
    send_result(conn, Tags.update(scope(conn), id, conn.body_params), :tag, &Serializer.tag/1)
  end

  delete "/tags/:id" do
    send_empty(conn, Tags.delete(scope(conn), id))
  end

  # Budgets and reports

  get "/budgets" do
    send_list(conn, Budgets.list(scope(conn)), :budgets, &Serializer.budget/1)
  end

  put "/budgets" do
    send_result(conn, Budgets.set(scope(conn), conn.body_params), :budget, &Serializer.budget/1)
  end

  get "/reports/budget" do
    send_result(
      conn,
      Budgets.report(scope(conn), conn.query_params),
      :report,
      &Serializer.budget_report/1
    )
  end

  get "/reports/income-expense" do
    result = Reports.income_expense(scope(conn), conn.query_params)
    send_result(conn, result, :report, &Serializer.income_expense/1)
  end

  get "/reports/net-worth" do
    send_result(
      conn,
      Reports.net_worth(scope(conn), conn.query_params),
      :report,
      &Serializer.net_worth/1
    )
  end

  get "/reports/balances" do
    send_result(
      conn,
      Reports.balances(scope(conn), conn.query_params),
      :report,
      &Serializer.balances/1
    )
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp scope(conn), do: conn.assigns.scope
end
