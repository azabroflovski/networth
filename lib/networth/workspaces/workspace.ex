defmodule Networth.Workspaces.Workspace do
  @moduledoc """
  A financial space. `role` is the role of the user it was loaded for
  (`owner` or `member`); `deletion_scheduled_at` is set while a deletion is
  pending.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          timezone: String.t(),
          deletion_scheduled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          role: String.t() | nil
        }

  defstruct [:id, :name, :timezone, :deletion_scheduled_at, :inserted_at, :role]
end
