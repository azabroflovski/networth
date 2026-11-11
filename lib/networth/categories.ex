defmodule Networth.Categories do
  @moduledoc """
  Expense and income categories of a workspace, with one optional level of
  subcategories. Categories are archived rather than deleted, because
  transactions keep referring to them.
  """

  alias Networth.{Activity, DB, Params, Scope}

  @defaults [
    {"expense", ~w(Food Transport Housing Health Entertainment Shopping Travel)},
    {"income", ["Salary", "Dividends", "Gifts", "Refunds", "Other income"]}
  ]

  @doc "Inserts the system categories every new workspace starts with."
  def create_defaults(workspace_id) do
    {kinds, names} = Enum.unzip(for {kind, names} <- @defaults, name <- names, do: {kind, name})

    DB.query!(
      """
      INSERT INTO categories (workspace_id, kind, name, system)
      SELECT $1, kind, name, true FROM unnest($2::text[], $3::text[]) AS t(kind, name)
      """,
      [workspace_id, kinds, names]
    )

    :ok
  end

  def list(%Scope{} = scope) do
    DB.all(
      "SELECT * FROM categories WHERE workspace_id = $1 ORDER BY kind, coalesce(parent_id, id), parent_id NULLS FIRST, name",
      [scope.workspace_id]
    )
  end

  def get(%Scope{} = scope, id) do
    with id when is_binary(id) <- Params.cast_id(id),
         %{} = category <-
           DB.one("SELECT * FROM categories WHERE id = $1 AND workspace_id = $2", [
             id,
             scope.workspace_id
           ]) do
      {:ok, category}
    else
      _ -> {:error, :not_found}
    end
  end

  def create(%Scope{} = scope, params) do
    with {:ok, name} <- Params.string(params, "name", required: true),
         {:ok, parent_id} <- Params.id(params, "parent_id"),
         {:ok, parent} <- fetch_parent(scope, parent_id),
         {:ok, kind} <- kind(params, parent) do
      sql = """
      INSERT INTO categories (workspace_id, parent_id, kind, name) VALUES ($1, $2, $3, $4) RETURNING *
      """

      DB.transact(fn ->
        with {:ok, category} <-
               sql |> DB.query([scope.workspace_id, parent_id, kind, name]) |> handle_write() do
          Activity.record(scope, "category.created", "category", category.id,
            data: %{
              "name" => category.name,
              "kind" => category.kind,
              "parent_id" => category.parent_id
            }
          )

          {:ok, category}
        end
      end)
    end
  end

  defp fetch_parent(_scope, nil), do: {:ok, nil}

  defp fetch_parent(scope, parent_id) do
    case get(scope, parent_id) do
      {:ok, %{parent_id: nil} = parent} -> {:ok, parent}
      {:ok, _} -> Params.invalid("parent_id", "must be a top-level category")
      {:error, :not_found} -> Params.invalid("parent_id", "does not exist")
    end
  end

  defp kind(params, nil), do: Params.one_of(params, "kind", ["expense", "income"], required: true)

  defp kind(params, parent) do
    case Map.get(params, "kind", parent.kind) do
      kind when kind == parent.kind -> {:ok, kind}
      _ -> Params.invalid("kind", "must match the parent category")
    end
  end

  @doc "Renames and/or archives (`\"archived\" => true`) a category."
  def update(%Scope{} = scope, id, params) do
    with {:ok, category} <- get(scope, id),
         {:ok, name} <- Params.string(params, "name", default: category.name),
         {:ok, archived} <- Params.boolean(params, "archived") do
      DB.transact(fn ->
        with {:ok, updated} <-
               """
               UPDATE categories SET name = $3,
                 archived_at = CASE WHEN $4::boolean IS NULL THEN archived_at
                                    WHEN $4 THEN coalesce(archived_at, now()) END
               WHERE id = $1 AND workspace_id = $2 RETURNING *
               """
               |> DB.query([category.id, scope.workspace_id, name, archived])
               |> handle_write() do
          record_update(scope, category, updated)
          {:ok, updated}
        end
      end)
    end
  end

  defp record_update(scope, before, updated) do
    editable = &%{name: &1.name, archived: &1.archived_at != nil}
    changes = Activity.diff(editable.(before), editable.(updated), [:name, :archived])

    if changes != %{} do
      Activity.record(scope, "category.updated", "category", updated.id,
        changes: changes,
        data: %{"name" => updated.name}
      )
    end
  end

  defp handle_write({:ok, result}), do: {:ok, result |> DB.to_maps() |> hd()}

  defp handle_write({:error, error}) do
    case DB.constraint_violation(error) do
      {:unique_violation, "categories_name_index"} -> Params.invalid("name", "already exists")
      _ -> raise error
    end
  end
end
