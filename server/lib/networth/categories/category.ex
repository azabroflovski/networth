defmodule Networth.Categories.Category do
  @moduledoc "An expense or income category; `parent_id` is set on subcategories."

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          parent_id: String.t() | nil,
          kind: String.t(),
          name: String.t(),
          system: boolean(),
          archived_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  defstruct [:id, :workspace_id, :parent_id, :kind, :name, :system, :archived_at, :inserted_at]
end
