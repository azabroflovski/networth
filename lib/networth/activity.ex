defmodule Networth.Activity do
  @moduledoc """
  Workspace activity log: who did what to which object.

  Domain functions call `record/5` inside the database transaction of the
  change, so an event exists exactly when the change committed. Edits of a
  transaction description are recorded by the database itself
  (`transactions_guard`), so they cannot happen without a trace.

  An event is `actor · action (resource.verb) · subject · changes · data`:
  `changes` holds `%{field => [old, new]}` for updates, `data` a snapshot
  that lets a client render the event without loading the subject. Money in
  events is stored as decimal strings with their currency.
  """

  alias Networth.{Currencies, DB, Money, Params, Scope}

  def record(%Scope{} = scope, action, subject_type, subject_id, opts \\ []) do
    DB.query!(
      """
      INSERT INTO activity_events (workspace_id, actor_id, action, subject_type, subject_id, changes, data)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      """,
      [
        scope.workspace_id,
        scope.user_id,
        action,
        subject_type,
        subject_id,
        Keyword.get(opts, :changes, %{}),
        Keyword.get(opts, :data, %{})
      ]
    )

    :ok
  end

  @doc "`%{field => [old, new]}` for the given fields whose values differ."
  def diff(old, new, fields) do
    for field <- fields, Map.get(old, field) != Map.get(new, field), into: %{} do
      {to_string(field), [Map.get(old, field), Map.get(new, field)]}
    end
  end

  def money(amount, currency), do: Money.format(amount, Currencies.exponent!(currency))

  @doc """
  Events of the workspace, newest first. Filters: subject_id, actor_id.
  Paginated by `limit` and `cursor` (the returned `next_cursor`).
  """
  def list(%Scope{} = scope, params \\ %{}) do
    with {:ok, subject_id} <- Params.id(params, "subject_id"),
         {:ok, actor_id} <- Params.id(params, "actor_id"),
         {:ok, cursor} <- Params.id(params, "cursor"),
         {:ok, limit} <- Params.integer(params, "limit", 50, 1, 200) do
      {conditions, args} =
        {["e.workspace_id = $1"], [scope.workspace_id]}
        |> DB.where(subject_id, &"e.subject_id = #{&1}")
        |> DB.where(actor_id, &"e.actor_id = #{&1}")
        |> DB.where(cursor, &"e.id < #{&1}")

      events =
        DB.all(
          """
          SELECT e.id, e.action, e.subject_type, e.subject_id, e.actor_id, u.name AS actor_name,
            e.changes, e.data, e.inserted_at
          FROM activity_events e JOIN users u ON u.id = e.actor_id
          WHERE #{Enum.join(conditions, " AND ")}
          ORDER BY e.id DESC LIMIT $#{length(args) + 1}
          """,
          args ++ [limit + 1]
        )

      {page, rest} = Enum.split(events, limit)
      {:ok, %{events: page, next_cursor: if(rest != [], do: List.last(page).id)}}
    end
  end
end
