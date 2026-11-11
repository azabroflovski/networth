defmodule Networth.UsersTest do
  use Networth.DataCase

  describe "register/1" do
    test "returns a working token" do
      {:ok, %{user: user, token: token}} =
        Users.register(%{"email" => "t@example.com", "name" => "T", "password" => "password1"})

      assert Users.get_by_token(token).id == user.id
    end

    test "creates the user with a personal workspace they own" do
      %{user: user, workspace: workspace} = register!("Alice@Example.com")

      assert user.email == "alice@example.com"
      assert workspace.name == "Personal"
      assert [%{id: id, role: "owner"}] = Workspaces.list_for_user(user.id)
      assert id == workspace.id
    end

    test "seeds default expense and income categories into the personal workspace" do
      %{scope: scope} = register!()
      categories = Categories.list(scope)

      assert Enum.any?(categories, &(&1.name == "Food" and &1.kind == "expense" and &1.system))
      assert Enum.any?(categories, &(&1.name == "Salary" and &1.kind == "income" and &1.system))
    end

    test "rejects a duplicate email regardless of case and leaves nothing behind" do
      register!("bob@example.com")

      assert {:error, {:invalid, %{"email" => %{code: :already_exists}}}} =
               Users.register(%{
                 "email" => "BOB@example.com",
                 "name" => "Bob",
                 "password" => "password1"
               })

      assert %{n: 1} = DB.one("SELECT count(*) AS n FROM workspaces")
    end

    test "reports every invalid field at once" do
      assert {:error, {:invalid, errors}} =
               Users.register(%{"email" => "nope", "name" => " ", "password" => "short"})

      assert %{
               "email" => %{code: :invalid_email},
               "name" => %{code: :blank},
               "password" => %{code: :invalid_length, min: 8, max: 256}
             } = errors
    end

    test "validates input" do
      assert {:error, {:invalid, %{"email" => _}}} =
               Users.register(%{"email" => "nope", "name" => "X", "password" => "password1"})

      assert {:error, {:invalid, %{"password" => _}}} =
               Users.register(%{"email" => "a@b.c", "name" => "X", "password" => "short"})

      assert {:error, {:invalid, %{"name" => _}}} =
               Users.register(%{"email" => "a@b.c", "name" => " ", "password" => "password1"})
    end

    test "concurrent registrations with the same email create exactly one user" do
      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Users.register(%{
              "email" => "race@example.com",
              "name" => "R",
              "password" => "password1"
            })
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert %{n: 1} = DB.one("SELECT count(*) AS n FROM users")
      assert %{n: 1} = DB.one("SELECT count(*) AS n FROM workspaces")
    end
  end

  describe "authentication" do
    test "authenticates with the right password only" do
      register!("carol@example.com")

      assert {:ok, %{email: "carol@example.com"}} =
               Users.authenticate(" Carol@example.com", "correct horse")

      assert {:error, :invalid_credentials} = Users.authenticate("carol@example.com", "wrong")

      assert {:error, :invalid_credentials} =
               Users.authenticate("nobody@example.com", "correct horse")
    end

    test "tokens resolve to their user until deleted" do
      %{user: user} = register!()
      token = Users.create_token(user.id)

      assert %{id: id} = Users.get_by_token(token)
      assert id == user.id
      assert Users.get_by_token("bogus") == nil

      :ok = Users.delete_token(token)
      assert Users.get_by_token(token) == nil
    end

    test "expired tokens are deleted by the cleanup" do
      %{user: user} = register!()
      expired = Users.create_token(user.id)
      live = Users.create_token(user.id)

      DB.query!(
        "UPDATE user_tokens SET expires_at = now() - interval '1 second' WHERE token_hash = $1",
        [
          :crypto.hash(:sha256, expired)
        ]
      )

      assert Users.delete_expired_tokens() == 1

      assert DB.one("SELECT 1 AS one FROM user_tokens WHERE token_hash = $1", [
               :crypto.hash(:sha256, expired)
             ]) == nil

      assert Users.get_by_token(live)
    end

    test "expired tokens are rejected" do
      %{user: user} = register!()
      token = Users.create_token(user.id)
      DB.query!("UPDATE user_tokens SET expires_at = now() - interval '1 second'")

      assert Users.get_by_token(token) == nil
    end
  end

  describe "login/3" do
    @ip {10, 0, 0, 1}

    setup do
      register!("dave@example.com")
      :ok
    end

    test "returns the user and a working token" do
      assert {:ok, %{user: %{email: "dave@example.com"}, token: token}} =
               Users.login("dave@example.com", "correct horse", @ip)

      assert %{email: "dave@example.com"} = Users.get_by_token(token)
    end

    test "locks an email after 5 failed attempts, even for the right password" do
      for _ <- 1..5,
          do:
            assert(
              Users.login("dave@example.com", "wrong", @ip) == {:error, :invalid_credentials}
            )

      assert {:error, {:rate_limited, retry_after}} =
               Users.login("Dave@Example.com", "correct horse", @ip)

      assert retry_after > 0

      # Another account is not affected.
      register!("erin@example.com")
      assert {:ok, %{user: _, token: _}} = Users.login("erin@example.com", "correct horse", @ip)
    end

    test "a successful login resets the failure count" do
      for _ <- 1..4, do: Users.login("dave@example.com", "wrong", @ip)
      assert {:ok, %{user: _, token: _}} = Users.login("dave@example.com", "correct horse", @ip)
      for _ <- 1..4, do: Users.login("dave@example.com", "wrong", @ip)

      assert {:ok, %{user: _, token: _}} = Users.login("dave@example.com", "correct horse", @ip)
    end

    test "limits all attempts from one address" do
      for i <- 1..20, do: Users.login("nobody#{i}@example.com", "x", @ip)

      assert {:error, {:rate_limited, _}} = Users.login("dave@example.com", "correct horse", @ip)

      assert {:ok, %{user: _, token: _}} =
               Users.login("dave@example.com", "correct horse", {10, 0, 0, 2})
    end
  end
end
