defmodule Networth.Web.OpenAPITest do
  @moduledoc """
  docs/openapi.json is the API contract for clients. Every route of the
  routers is documented there and every documented operation exists.
  """
  use ExUnit.Case, async: true

  @spec_path "../docs/openapi.json"
  @routers [
    {"lib/networth/web/router.ex", ""},
    {"lib/networth/web/workspace_router.ex", "/api/workspaces/{wid}"}
  ]

  defp routes do
    for {file, prefix} <- @routers,
        [_, method, path] <-
          Regex.scan(~r/^  (get|post|put|patch|delete) "([^"]+)"/m, File.read!(file)),
        into: MapSet.new() do
      path = Regex.replace(~r/:(\w+)/, path, "{\\1}")
      {method, String.trim_trailing(prefix <> path, "/")}
    end
  end

  defp documented do
    for {path, operations} <- Jason.decode!(File.read!(@spec_path))["paths"],
        method <- Map.keys(operations),
        into: MapSet.new(),
        do: {method, path}
  end

  test "the spec documents exactly the routes the server has" do
    routes = routes()
    documented = documented()

    assert MapSet.size(routes) > 40
    assert MapSet.difference(routes, documented) == MapSet.new(), "routes missing from the spec"

    assert MapSet.difference(documented, routes) == MapSet.new(),
           "documented operations with no route"
  end

  test "every $ref points to a defined component" do
    spec = Jason.decode!(File.read!(@spec_path))

    refs =
      ~r/"\$ref":\s*"#\/components\/(\w+)\/(\w+)"/
      |> Regex.scan(File.read!(@spec_path), capture: :all_but_first)
      |> Enum.uniq()

    assert refs != []

    for [section, name] <- refs do
      assert get_in(spec, ["components", section, name]),
             "#/components/#{section}/#{name} is not defined"
    end
  end
end
