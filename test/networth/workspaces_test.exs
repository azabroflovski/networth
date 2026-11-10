defmodule Networth.WorkspacesTest do
  use Networth.DataCase

  test "a user can create additional workspaces and owns them" do
    %{user: user} = register!()

    assert {:ok, family} = Workspaces.create(user.id, %{"name" => "Family"})
    assert family.role == "owner"
    assert [%{name: "Personal"}, %{name: "Family"}] = Workspaces.list_for_user(user.id)

    {:ok, scope} = Workspaces.authorize(user.id, family.id)
    assert Enum.any?(Categories.list(scope), &(&1.name == "Food"))
  end

  describe "timezone" do
    test "is set at creation, validated and changeable by the owner" do
      %{user: user} = register!()

      assert {:ok, %{timezone: "Asia/Tashkent"} = ws} =
               Workspaces.create(user.id, %{"name" => "Home", "timezone" => "Asia/Tashkent"})

      assert {:error, {:invalid, %{"timezone" => _}}} =
               Workspaces.create(user.id, %{"name" => "X", "timezone" => "Mars/Olympus"})

      {:ok, scope} = Workspaces.authorize(user.id, ws.id)

      assert {:ok, %{timezone: "Europe/Berlin", name: "Home"}} =
               Workspaces.update(scope, %{"timezone" => "Europe/Berlin"})
    end

    test "registration accepts the timezone of the personal workspace" do
      assert {:ok, %{workspace: %{timezone: "Asia/Tashkent"}}} =
               Users.register(%{
                 "email" => "tz@example.com",
                 "name" => "T",
                 "password" => "password1",
                 "timezone" => "Asia/Tashkent"
               })

      assert {:error, {:invalid, %{"timezone" => _}}} =
               Users.register(%{
                 "email" => "tz2@example.com",
                 "name" => "T",
                 "password" => "password1",
                 "timezone" => "nope"
               })

      assert %{n: 1} = DB.one("SELECT count(*) AS n FROM users")
    end

    test "default dates are today in the workspace timezone" do
      %{user: user} = register!()

      {:ok, east} =
        Workspaces.create(user.id, %{"name" => "East", "timezone" => "Pacific/Kiritimati"})

      {:ok, west} =
        Workspaces.create(user.id, %{"name" => "West", "timezone" => "Pacific/Pago_Pago"})

      {:ok, east} = Workspaces.authorize(user.id, east.id)
      {:ok, west} = Workspaces.authorize(user.id, west.id)

      # UTC+14 and UTC-11 are 25 hours apart: their dates always differ.
      east_tx =
        post!(east, %{"type" => "income", "account_id" => account!(east).id, "amount" => "1"})

      west_tx =
        post!(west, %{"type" => "income", "account_id" => account!(west).id, "amount" => "1"})

      assert Date.diff(east_tx.occurred_on, west_tx.occurred_on) in [1, 2]

      assert east_tx.occurred_on ==
               DateTime.utc_now() |> DateTime.add(14, :hour) |> DateTime.to_date()
    end
  end

  test "non-members cannot access a workspace" do
    %{workspace: workspace} = register!()
    %{user: stranger} = register!()

    assert Workspaces.authorize(stranger.id, workspace.id) == {:error, :not_found}
    assert Workspaces.authorize(stranger.id, "not-an-id") == {:error, :not_found}
  end

  describe "invitations" do
    setup do
      owner = register!("owner@example.com")
      invitee = register!("invitee@example.com")
      {:ok, family} = Workspaces.create(owner.user.id, %{"name" => "Family"})
      {:ok, family_scope} = Workspaces.authorize(owner.user.id, family.id)
      %{owner: owner, invitee: invitee, family: family, family_scope: family_scope}
    end

    test "an invited user accepts and becomes a member", ctx do
      assert {:ok, invitation} =
               Workspaces.invite(ctx.family_scope, %{"email" => "Invitee@example.com"})

      assert [%{id: id, workspace_name: "Family"}] =
               Workspaces.pending_invitations(ctx.invitee.user)

      assert id == invitation.id

      assert {:ok, %{id: family_id, role: "member"}} =
               Workspaces.accept_invitation(ctx.invitee.user, id)

      assert family_id == ctx.family.id

      assert {:ok, %Scope{role: "member"}} =
               Workspaces.authorize(ctx.invitee.user.id, ctx.family.id)

      assert Workspaces.pending_invitations(ctx.invitee.user) == []

      roles = ctx.family_scope |> Workspaces.list_members() |> Enum.map(&{&1.email, &1.role})
      assert roles == [{"owner@example.com", "owner"}, {"invitee@example.com", "member"}]
    end

    test "only the addressee can accept an invitation", ctx do
      {:ok, invitation} = Workspaces.invite(ctx.family_scope, %{"email" => "invitee@example.com"})
      %{user: other} = register!()

      assert Workspaces.accept_invitation(other, invitation.id) == {:error, :not_found}
      assert Workspaces.authorize(other.id, ctx.family.id) == {:error, :not_found}
    end

    test "members cannot invite or manage invitations", ctx do
      {:ok, invitation} = Workspaces.invite(ctx.family_scope, %{"email" => "invitee@example.com"})
      {:ok, _} = Workspaces.accept_invitation(ctx.invitee.user, invitation.id)
      {:ok, member_scope} = Workspaces.authorize(ctx.invitee.user.id, ctx.family.id)

      assert Workspaces.invite(member_scope, %{"email" => "x@example.com"}) ==
               {:error, :forbidden}

      assert Workspaces.list_invitations(member_scope) == {:error, :forbidden}
      assert Workspaces.update(member_scope, %{"name" => "Mine"}) == {:error, :forbidden}
    end

    test "rejects duplicate and pointless invitations", ctx do
      {:ok, _} = Workspaces.invite(ctx.family_scope, %{"email" => "invitee@example.com"})

      assert {:error, {:invalid, %{"email" => "already has a pending invitation"}}} =
               Workspaces.invite(ctx.family_scope, %{"email" => "invitee@example.com"})

      assert {:error, {:invalid, %{"email" => "is already a member"}}} =
               Workspaces.invite(ctx.family_scope, %{"email" => "owner@example.com"})
    end

    test "the owner can revoke a pending invitation", ctx do
      {:ok, invitation} = Workspaces.invite(ctx.family_scope, %{"email" => "invitee@example.com"})

      assert Workspaces.revoke_invitation(ctx.family_scope, invitation.id) == :ok
      assert Workspaces.accept_invitation(ctx.invitee.user, invitation.id) == {:error, :not_found}
    end
  end
end
