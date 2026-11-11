defmodule Networth.Web.WorkspacesTest do
  @moduledoc "Workspace access, invitations and members over HTTP."
  use Networth.ConnCase

  test "another user's workspace looks nonexistent" do
    {_alice, alice_ws} = register("alice@example.com")
    {bob, _} = register("bob@example.com")

    assert {404, %{"error" => "not_found"}} =
             request(:get, "/api/workspaces/#{alice_ws}/accounts", nil, bob)

    assert {404, _} =
             request(:post, "/api/workspaces/#{alice_ws}/transactions", %{type: "income"}, bob)
  end

  test "invitation flow over HTTP" do
    {alice, _} = register("alice@example.com")
    {bob, _} = register("bob@example.com")

    {201, %{"workspace" => %{"id" => family}}} =
      request(:post, "/api/workspaces", %{name: "Family"}, alice)

    {201, %{"invitation" => %{"id" => inv}}} =
      request(:post, "/api/workspaces/#{family}/invitations", %{email: "bob@example.com"}, alice)

    assert {200, %{"invitations" => [%{"id" => ^inv, "workspace_name" => "Family"}]}} =
             request(:get, "/api/invitations", nil, bob)

    assert {200, %{"workspace" => %{"id" => ^family, "role" => "member"}}} =
             request(:post, "/api/invitations/#{inv}/accept", nil, bob)

    assert {403, _} =
             request(
               :post,
               "/api/workspaces/#{family}/invitations",
               %{email: "c@example.com"},
               bob
             )

    assert {200, %{"members" => [_, _]}} =
             request(:get, "/api/workspaces/#{family}/members", nil, bob)
  end

  test "member management over HTTP" do
    {alice, _} = register("alice@example.com")
    {bob, _} = register("bob@example.com")

    {201, %{"workspace" => %{"id" => family}}} =
      request(:post, "/api/workspaces", %{name: "Family"}, alice)

    {201, %{"invitation" => %{"id" => inv}}} =
      request(:post, "/api/workspaces/#{family}/invitations", %{email: "bob@example.com"}, alice)

    {200, _} = request(:post, "/api/invitations/#{inv}/accept", nil, bob)

    {200, %{"members" => members}} =
      request(:get, "/api/workspaces/#{family}/members", nil, alice)

    ids = Map.new(members, &{&1["email"], &1["user_id"]})
    members_path = "/api/workspaces/#{family}/members"

    assert {409, %{"error" => "last_owner"}} =
             request(:delete, "#{members_path}/#{ids["alice@example.com"]}", nil, alice)

    assert {200, %{"member" => %{"role" => "owner"}}} =
             request(:patch, "#{members_path}/#{ids["bob@example.com"]}", %{role: "owner"}, alice)

    assert {204, nil} =
             request(:delete, "#{members_path}/#{ids["alice@example.com"]}", nil, alice)

    assert {404, _} = request(:get, "/api/workspaces/#{family}", nil, alice)

    assert {200, %{"members" => [%{"email" => "bob@example.com", "role" => "owner"}]}} =
             request(:get, members_path, nil, bob)
  end
end
