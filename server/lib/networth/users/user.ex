defmodule Networth.Users.User do
  @moduledoc "A person's account. The password hash never leaves `Networth.Users`."

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t(),
          name: String.t(),
          inserted_at: DateTime.t()
        }

  defstruct [:id, :email, :name, :inserted_at]
end
