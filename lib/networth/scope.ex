defmodule Networth.Scope do
  @moduledoc """
  The authorized context for workspace data: who acts and in which workspace.

  Built only by `Networth.Workspaces.authorize/2` after a membership check.
  Every function touching workspace data takes a scope and filters by
  `workspace_id`.
  """

  @enforce_keys [:user_id, :workspace_id, :role]
  defstruct [:user_id, :workspace_id, :role]

  def owner?(%__MODULE__{role: role}), do: role == "owner"

  def require_owner(scope), do: if(owner?(scope), do: :ok, else: {:error, :forbidden})
end
