defmodule Networth.Users do
  @moduledoc """
  User accounts, password authentication and bearer tokens.

  Registration creates the user, their personal workspace and a first token
  in one database transaction; login returns a new token too.
  """

  alias Networth.{DB, Params, RateLimit, Workspaces}

  @user_columns "id, email, name, inserted_at"

  def register(params) do
    with {:ok, %{email: email, name: name, password: password}} <-
           Params.all(
             email: email(params),
             name: Params.string(params, "name", required: true),
             password: password(params)
           ) do
      DB.transaction(fn ->
        user = insert_user(email, name, password)
        workspace_params = %{"name" => "Personal", "timezone" => params["timezone"]}

        workspace =
          case Workspaces.create(user.id, workspace_params) do
            {:ok, workspace} -> workspace
            {:error, reason} -> DB.rollback(reason)
          end

        %{user: user, workspace: workspace, token: create_token(user.id)}
      end)
    end
  end

  defp insert_user(email, name, password) do
    sql =
      "INSERT INTO users (email, name, password_hash) VALUES ($1, $2, $3) RETURNING #{@user_columns}"

    case DB.query(sql, [email, name, hash_password(password)]) do
      {:ok, result} ->
        result |> DB.to_maps() |> hd()

      {:error, error} ->
        case DB.constraint_violation(error) do
          {:unique_violation, "users_email_index"} ->
            DB.rollback({:invalid, %{"email" => %{code: :already_exists}}})

          _ ->
            raise error
        end
    end
  end

  def get(id), do: DB.one("SELECT #{@user_columns} FROM users WHERE id = $1", [id])

  @doc """
  Password login with brute-force protection: too many failed attempts for
  an email, or too many attempts from one client address, are refused with
  `{:error, {:rate_limited, retry_after_seconds}}` before checking the
  password. Returns `{:ok, %{user: user, token: token}}`.
  """
  def login(email, password, client_ip) do
    limits = Application.fetch_env!(:networth, :login_limits)
    {ip_limit, ip_window} = limits[:per_ip]
    {email_limit, email_window} = limits[:per_email]
    ip_key = {:login_ip, client_ip}
    email_key = {:login_email, is_binary(email) && normalize_email(email)}

    with :ok <- RateLimit.check(ip_key, ip_limit),
         :ok <- RateLimit.check(email_key, email_limit) do
      RateLimit.record(ip_key, ip_window)

      case authenticate(email, password) do
        {:ok, user} ->
          RateLimit.reset(email_key)
          {:ok, %{user: user, token: create_token(user.id)}}

        error ->
          RateLimit.record(email_key, email_window)
          error
      end
    else
      {:error, retry_after} -> {:error, {:rate_limited, retry_after}}
    end
  end

  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    row =
      DB.one("SELECT #{@user_columns}, password_hash FROM users WHERE email = $1", [
        normalize_email(email)
      ])

    cond do
      row && verify_password(password, row.password_hash) ->
        {:ok, Map.delete(row, :password_hash)}

      row ->
        {:error, :invalid_credentials}

      true ->
        # Spend the same time as a real check so response time does not reveal registered emails.
        hash_password(password)
        {:error, :invalid_credentials}
    end
  end

  def authenticate(_email, _password), do: {:error, :invalid_credentials}

  @doc "Creates a bearer token. Only its hash is stored."
  def create_token(user_id) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    ttl_seconds = Application.fetch_env!(:networth, :token_ttl_days) * 86_400

    DB.query!(
      "INSERT INTO user_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, now() + make_interval(secs => $3))",
      [user_id, token_hash(token), ttl_seconds]
    )

    token
  end

  def get_by_token(token) when is_binary(token) do
    DB.one(
      """
      SELECT u.id, u.email, u.name, u.inserted_at
      FROM user_tokens t JOIN users u ON u.id = t.user_id
      WHERE t.token_hash = $1 AND t.expires_at > now()
      """,
      [token_hash(token)]
    )
  end

  def delete_token(token) when is_binary(token) do
    DB.query!("DELETE FROM user_tokens WHERE token_hash = $1", [token_hash(token)])
    :ok
  end

  @doc "Deletes expired tokens; returns how many were deleted."
  def delete_expired_tokens do
    %{num_rows: n} = DB.query!("DELETE FROM user_tokens WHERE expires_at <= now()")
    n
  end

  def normalize_email(email), do: email |> String.trim() |> String.downcase()

  def email(params) do
    with {:ok, email} <- Params.string(params, "email", required: true, max: 254) do
      email = normalize_email(email)

      if Regex.match?(~r/^[^@\s]+@[^@\s]+$/, email),
        do: {:ok, email},
        else: Params.invalid("email", :invalid_email)
    end
  end

  defp password(params) do
    case Map.get(params, "password") do
      p when is_binary(p) and byte_size(p) >= 8 and byte_size(p) <= 256 -> {:ok, p}
      p when is_binary(p) -> Params.invalid("password", :invalid_length, %{min: 8, max: 256})
      _ -> Params.invalid("password", :required)
    end
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)

  # Format: pbkdf2-sha256$<iterations>$<salt>$<hash>, base64 without padding.
  defp hash_password(password) do
    iterations = Application.fetch_env!(:networth, :password_iterations)
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)
    Enum.join(["pbkdf2-sha256", iterations, b64(salt), b64(hash)], "$")
  end

  defp verify_password(password, encoded) do
    ["pbkdf2-sha256", iterations, salt, hash] = String.split(encoded, "$")
    salt = Base.decode64!(salt, padding: false)
    expected = Base.decode64!(hash, padding: false)
    actual = :crypto.pbkdf2_hmac(:sha256, password, salt, String.to_integer(iterations), 32)
    :crypto.hash_equals(actual, expected)
  end

  defp b64(bin), do: Base.encode64(bin, padding: false)
end
