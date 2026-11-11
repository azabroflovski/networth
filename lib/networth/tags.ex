defmodule Networth.Tags do
  @moduledoc """
  Workspace tags. Tags label whole transactions for filtering and reports and
  never affect the ledger, so they can be renamed and deleted freely.
  """

  alias Networth.{Activity, DB, Params, Scope}

  def list(%Scope{} = scope) do
    DB.all("SELECT * FROM tags WHERE workspace_id = $1 ORDER BY lower(name)", [scope.workspace_id])
  end

  def get(%Scope{} = scope, id) do
    with id when is_binary(id) <- Params.cast_id(id),
         %{} = tag <-
           DB.one("SELECT * FROM tags WHERE id = $1 AND workspace_id = $2", [
             id,
             scope.workspace_id
           ]) do
      {:ok, tag}
    else
      _ -> {:error, :not_found}
    end
  end

  def create(%Scope{} = scope, params) do
    with {:ok, name} <- Params.string(params, "name", required: true, max: 50),
         {:ok, color} <- color(params, nil) do
      DB.transact(fn ->
        with {:ok, tag} <-
               "INSERT INTO tags (workspace_id, name, color) VALUES ($1, $2, $3) RETURNING *"
               |> DB.query([scope.workspace_id, name, color])
               |> handle_write() do
          Activity.record(scope, "tag.created", "tag", tag.id, data: %{"name" => tag.name})
          {:ok, tag}
        end
      end)
    end
  end

  def update(%Scope{} = scope, id, params) do
    with {:ok, tag} <- get(scope, id),
         {:ok, name} <- Params.string(params, "name", max: 50, default: tag.name),
         {:ok, color} <- color(params, tag.color) do
      DB.transact(fn ->
        with {:ok, updated} <-
               "UPDATE tags SET name = $3, color = $4 WHERE id = $1 AND workspace_id = $2 RETURNING *"
               |> DB.query([tag.id, scope.workspace_id, name, color])
               |> handle_write() do
          changes = Activity.diff(tag, updated, [:name, :color])

          if changes != %{} do
            Activity.record(scope, "tag.updated", "tag", tag.id,
              changes: changes,
              data: %{"name" => updated.name}
            )
          end

          {:ok, updated}
        end
      end)
    end
  end

  def delete(%Scope{} = scope, id) do
    with {:ok, tag} <- get(scope, id) do
      {:ok, :ok} =
        DB.transaction(fn ->
          DB.query!("DELETE FROM tags WHERE id = $1 AND workspace_id = $2", [
            tag.id,
            scope.workspace_id
          ])

          Activity.record(scope, "tag.deleted", "tag", tag.id, data: %{"name" => tag.name})
        end)

      :ok
    end
  end

  @doc "Checks that all ids are tags of the workspace."
  def validate_ids(%Scope{}, []), do: :ok

  def validate_ids(%Scope{} = scope, ids) do
    %{count: count} =
      DB.one("SELECT count(*) AS count FROM tags WHERE workspace_id = $1 AND id = ANY($2)", [
        scope.workspace_id,
        ids
      ])

    if count == length(ids), do: :ok, else: Params.invalid("tag_ids", "contains unknown tags")
  end

  # Absent key keeps the current color, explicit null clears it.
  defp color(params, current) do
    case Map.fetch(params, "color") do
      :error ->
        {:ok, current}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.downcase(value)

        if Regex.match?(~r/^#[0-9a-f]{6}$/, value),
          do: {:ok, value},
          else: Params.invalid("color", "must be a hex color like #1a2b3c")

      _ ->
        Params.invalid("color", "must be a hex color like #1a2b3c")
    end
  end

  defp handle_write({:ok, result}), do: {:ok, result |> DB.to_maps() |> hd()}

  defp handle_write({:error, error}) do
    case DB.constraint_violation(error) do
      {:unique_violation, "tags_name_index"} -> Params.invalid("name", "already exists")
      _ -> raise error
    end
  end
end
