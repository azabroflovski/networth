defmodule Networth.Tags.Tag do
  @moduledoc "A label for whole transactions."

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          name: String.t(),
          color: String.t() | nil,
          inserted_at: DateTime.t()
        }

  defstruct [:id, :workspace_id, :name, :color, :inserted_at]
end
