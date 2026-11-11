defmodule Networth.Activity.Event do
  @moduledoc """
  One entry of the activity log: who (`actor_id`, `actor_name`) did what
  (`action`, `resource.verb`) to which object (`subject_type`,
  `subject_id`). `changes` holds `%{field => [old, new]}`, `data` a snapshot
  for rendering.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          action: String.t(),
          subject_type: String.t(),
          subject_id: String.t() | nil,
          actor_id: String.t(),
          actor_name: String.t(),
          changes: map(),
          data: map(),
          inserted_at: DateTime.t()
        }

  defstruct [
    :id,
    :action,
    :subject_type,
    :subject_id,
    :actor_id,
    :actor_name,
    :changes,
    :data,
    :inserted_at
  ]
end
