defmodule Networth.Web.WorkspaceRouter do
  @moduledoc """
  Routes inside one workspace, `/api/workspaces/:wid/...`. The request is
  made on behalf of a member: `authorize_workspace` puts the scope in
  `conn.assigns` before any route runs.
  """

  use Plug.Router

  import Networth.Web.{Auth, Response}

  alias Networth.{Accounts, Activity, Budgets, Categories, Ledger, Reports, Tags, Workspaces}
  alias Networth.Web.JSON, as: View

  plug :authorize_workspace
  plug :match
  plug :dispatch

  # Workspace, members, invitations, activity

  get "/" do
    json(conn, 200, %{workspace: View.workspace(Workspaces.get(scope(conn)))})
  end

  patch "/" do
    render(conn, Workspaces.update(scope(conn), conn.body_params), :workspace, &View.workspace/1)
  end

  delete "/" do
    result = Workspaces.schedule_deletion(scope(conn), conn.body_params)
    render(conn, result, :workspace, &View.workspace/1, 202)
  end

  post "/restore" do
    render(conn, Workspaces.cancel_deletion(scope(conn)), :workspace, &View.workspace/1)
  end

  get "/members" do
    render_list(conn, Workspaces.list_members(scope(conn)), :members, &View.member/1)
  end

  patch "/members/:user_id" do
    result = Workspaces.update_member(scope(conn), user_id, conn.body_params)
    render(conn, result, :member, &View.member/1)
  end

  delete "/members/:user_id" do
    render_empty(conn, Workspaces.remove_member(scope(conn), user_id))
  end

  get "/invitations" do
    render_list(conn, Workspaces.list_invitations(scope(conn)), :invitations, &View.invitation/1)
  end

  post "/invitations" do
    result = Workspaces.invite(scope(conn), conn.body_params)
    render(conn, result, :invitation, &View.invitation/1, 201)
  end

  delete "/invitations/:id" do
    render_empty(conn, Workspaces.revoke_invitation(scope(conn), id))
  end

  get "/activity" do
    render_page(
      conn,
      Activity.list(scope(conn), conn.query_params),
      :events,
      &View.activity_event/1
    )
  end

  # Accounts

  get "/accounts" do
    render_list(conn, Accounts.list(scope(conn)), :accounts, &View.account/1)
  end

  post "/accounts" do
    render(conn, Accounts.create(scope(conn), conn.body_params), :account, &View.account/1, 201)
  end

  get "/accounts/:id" do
    render(conn, Accounts.get(scope(conn), id), :account, &View.account/1)
  end

  patch "/accounts/:id" do
    render(conn, Accounts.update(scope(conn), id, conn.body_params), :account, &View.account/1)
  end

  post "/accounts/:id/adjust" do
    case Ledger.adjust_balance(scope(conn), id, conn.body_params) do
      {:ok, nil} -> json(conn, 200, %{transaction: nil})
      result -> render(conn, result, :transaction, &View.transaction/1, 201)
    end
  end

  get "/accounts/:id/activity" do
    result = Reports.account_activity(scope(conn), id, conn.query_params)
    render(conn, result, :activity, &View.account_activity/1)
  end

  # Transactions

  get "/transactions" do
    render_page(
      conn,
      Ledger.list(scope(conn), conn.query_params),
      :transactions,
      &View.transaction/1
    )
  end

  post "/transactions" do
    render(
      conn,
      Ledger.post(scope(conn), conn.body_params),
      :transaction,
      &View.transaction/1,
      201
    )
  end

  get "/transactions/:id" do
    render(conn, Ledger.get(scope(conn), id), :transaction, &View.transaction/1)
  end

  patch "/transactions/:id" do
    result = Ledger.update(scope(conn), id, conn.body_params)
    render(conn, result, :transaction, &View.transaction/1)
  end

  post "/transactions/:id/correct" do
    result = Ledger.correct(scope(conn), id, conn.body_params)
    render(conn, result, :transaction, &View.transaction/1, 201)
  end

  delete "/transactions/:id" do
    render_empty(conn, Ledger.reverse(scope(conn), id))
  end

  post "/transactions/:id/reverse" do
    result = Ledger.reverse(scope(conn), id, conn.body_params)
    render(conn, result, :transaction, &View.transaction/1, 201)
  end

  put "/transactions/:id/tags" do
    result = Ledger.set_tags(scope(conn), id, conn.body_params)
    render(conn, result, :transaction, &View.transaction/1)
  end

  # Categories and tags

  get "/categories" do
    render_list(conn, Categories.list(scope(conn)), :categories, &View.category/1)
  end

  post "/categories" do
    result = Categories.create(scope(conn), conn.body_params)
    render(conn, result, :category, &View.category/1, 201)
  end

  patch "/categories/:id" do
    result = Categories.update(scope(conn), id, conn.body_params)
    render(conn, result, :category, &View.category/1)
  end

  get "/tags" do
    render_list(conn, Tags.list(scope(conn)), :tags, &View.tag/1)
  end

  post "/tags" do
    render(conn, Tags.create(scope(conn), conn.body_params), :tag, &View.tag/1, 201)
  end

  patch "/tags/:id" do
    render(conn, Tags.update(scope(conn), id, conn.body_params), :tag, &View.tag/1)
  end

  delete "/tags/:id" do
    render_empty(conn, Tags.delete(scope(conn), id))
  end

  # Budgets and reports

  get "/budgets" do
    render_list(conn, Budgets.list(scope(conn)), :budgets, &View.budget/1)
  end

  put "/budgets" do
    render(conn, Budgets.set(scope(conn), conn.body_params), :budget, &View.budget/1)
  end

  get "/reports/budget" do
    render(conn, Budgets.report(scope(conn), conn.query_params), :report, &View.budget_report/1)
  end

  get "/reports/income-expense" do
    result = Reports.income_expense(scope(conn), conn.query_params)
    render(conn, result, :report, &View.income_expense/1)
  end

  get "/reports/net-worth" do
    render(conn, Reports.net_worth(scope(conn), conn.query_params), :report, &View.net_worth/1)
  end

  get "/reports/balances" do
    render(conn, Reports.balances(scope(conn), conn.query_params), :report, &View.balances/1)
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp scope(conn), do: conn.assigns.scope
end
