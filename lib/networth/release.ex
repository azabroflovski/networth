defmodule Networth.Release do
  @moduledoc """
  Tasks for a built release, where Mix is not available:

      bin/networth eval "Networth.Release.migrate()"
  """

  def migrate do
    Application.load(:networth)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    Networth.DB.Migrator.migrate()
  end
end
