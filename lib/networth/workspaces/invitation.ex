defmodule Networth.Workspaces.Invitation do
  @moduledoc """
  An invitation to a workspace, addressed to an email. `workspace_name` is
  loaded for the invited user's list of pending invitations.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          workspace_name: String.t() | nil,
          email: String.t() | nil,
          invited_by: String.t() | nil,
          accepted_by: String.t() | nil,
          accepted_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  defstruct [
    :id,
    :workspace_id,
    :workspace_name,
    :email,
    :invited_by,
    :accepted_by,
    :accepted_at,
    :inserted_at
  ]
end
