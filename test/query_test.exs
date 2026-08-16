# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.QueryTest do
  use ExUnit.Case, async: true

  defmodule Params do
    @enforce_keys [:tags]
    defstruct [:tags, active: :__archastro_unset__, filter: :__archastro_unset__]

    @type t :: %__MODULE__{
            tags: [String.t()],
            active: boolean() | ArchAstro.SDK.Unset.t(),
            filter: ArchAstro.SDK.JSON.object() | ArchAstro.SDK.Unset.t()
          }

    @spec to_map(t()) :: ArchAstro.SDK.JSON.object()
    def to_map(value) do
      %{"tags" => value.tags}
      |> ArchAstro.SDK.Codec.put_optional("active", value.active)
      |> ArchAstro.SDK.Codec.put_optional("filter", value.filter)
    end
  end

  test "uses repeated keys for arrays and JSON for composite values" do
    params = %Params{tags: ["one", "two"], active: false, filter: %{"kind" => "agent"}}

    assert ArchAstro.SDK.Query.encode(params) ==
             "active=false&filter=%7B%22kind%22%3A%22agent%22%7D&tags=one&tags=two"
  end

  test "omits unset struct fields" do
    assert ArchAstro.SDK.Query.append("https://example.test/path", %Params{tags: []}) ==
             "https://example.test/path"
  end

  test "omits nil params instead of sending the string null" do
    assert ArchAstro.SDK.Query.encode(%{"cursor" => nil, "limit" => 5}) == "limit=5"

    assert ArchAstro.SDK.Query.append("https://example.test/path", %{"cursor" => nil}) ==
             "https://example.test/path"
  end

  test "omits nil elements inside repeated params" do
    assert ArchAstro.SDK.Query.encode(%{"tags" => ["one", nil, "two"]}) == "tags=one&tags=two"
  end
end
