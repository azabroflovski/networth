defmodule Networth.EntitiesTest do
  @moduledoc "The core returns its entities as structs, never as bare query rows."
  use Networth.DataCase

  alias Networth.{Activity, Budgets}
  alias Networth.Accounts.Account
  alias Networth.Activity.Event
  alias Networth.Budgets.Budget
  alias Networth.Categories.Category
  alias Networth.Ledger.{Entry, Exchange, Transaction}
  alias Networth.Tags.Tag
  alias Networth.Users.User
  alias Networth.Workspaces.{Invitation, Member, Workspace}

  test "every context returns its entity struct" do
    assert {:ok, %{user: %User{} = user, workspace: %Workspace{role: "owner"}}} =
             Users.register(%{
               "email" => "s@example.com",
               "name" => "S",
               "password" => "password1"
             })

    assert %User{} = Users.get(user.id)
    assert [%Workspace{} = ws] = Workspaces.list_for_user(user.id)
    {:ok, scope} = Workspaces.authorize(user.id, ws.id)
    assert %Workspace{} = Workspaces.get(scope)
    assert [%Member{}] = Workspaces.list_members(scope)
    assert {:ok, %Invitation{}} = Workspaces.invite(scope, %{"email" => "x@example.com"})
    assert {:ok, [%Invitation{}]} = Workspaces.list_invitations(scope)

    assert {:ok, %Account{} = uzs} =
             Accounts.create(scope, %{
               "name" => "U",
               "type" => "cash",
               "currency" => "UZS",
               "opening_balance" => "10"
             })

    assert {:ok, %Account{} = usd} =
             Accounts.create(scope, %{
               "name" => "D",
               "type" => "cash",
               "currency" => "USD",
               "opening_balance" => "10"
             })

    assert [%Account{}, %Account{}] = Accounts.list(scope)
    assert [%Account{} | _] = Accounts.list(scope, on: ~D[2026-01-01])

    assert [%Category{} | _] = Categories.list(scope)
    assert {:ok, %Category{}} = Categories.create(scope, %{"name" => "Pets", "kind" => "expense"})
    assert {:ok, %Tag{} = tag} = Tags.create(scope, %{"name" => "T"})
    assert [%Tag{}] = Tags.list(scope)

    assert {:ok, %Budget{}} =
             Budgets.set(scope, %{
               "category_id" => category_id(scope, "Food"),
               "currency" => "UZS",
               "amount" => "1"
             })

    assert [%Budget{}] = Budgets.list(scope)

    assert {:ok, %Transaction{entries: [%Entry{} | _], exchange: %Exchange{}}} =
             Ledger.post(scope, %{
               "type" => "exchange",
               "from_account_id" => usd.id,
               "from_amount" => "1",
               "to_account_id" => uzs.id,
               "to_amount" => "12700",
               "tag_ids" => [tag.id]
             })

    assert {:ok, %{transactions: [%Transaction{} | _]}} = Ledger.list(scope)
    assert {:ok, %{events: [%Event{} | _]}} = Activity.list(scope)
  end
end
