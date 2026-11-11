defmodule Networth.Workspaces.Member do
  @moduledoc "A user's membership in a workspace."

  @type t :: %__MODULE__{
          user_id: String.t(),
          email: String.t(),
          name: String.t(),
          role: String.t(),
          inserted_at: DateTime.t()
        }

  defstruct [:user_id, :email, :name, :role, :inserted_at]
end
