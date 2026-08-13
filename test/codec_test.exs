defmodule ArchAstro.SDK.CodecTest do
  use ExUnit.Case, async: true

  defmodule Cat do
    defstruct [:lives]

    @type t :: %__MODULE__{lives: integer()}
    @spec from_map(ArchAstro.SDK.JSON.object()) :: t()
    def from_map(value), do: %__MODULE__{lives: value["lives"]}
    @spec matches?(ArchAstro.SDK.JSON.t()) :: boolean()
    def matches?(value), do: ArchAstro.SDK.Codec.matches?(value, {:object, [{"lives", :integer}]})
  end

  defmodule Dog do
    defstruct [:good]

    @type t :: %__MODULE__{good: boolean()}
    @spec from_map(ArchAstro.SDK.JSON.object()) :: t()
    def from_map(value), do: %__MODULE__{good: value["good"]}
    @spec matches?(ArchAstro.SDK.JSON.t()) :: boolean()
    def matches?(value), do: ArchAstro.SDK.Codec.matches?(value, {:object, [{"good", :boolean}]})
  end

  test "plain unions select the matching referenced shape" do
    descriptor = {:union, [{:ref, Cat}, {:ref, Dog}]}

    assert %Dog{good: true} = ArchAstro.SDK.Codec.decode(%{"good" => true}, descriptor)
    assert %Cat{lives: 9} = ArchAstro.SDK.Codec.decode(%{"lives" => 9}, descriptor)
  end

  test "plain unions reject an unmatched wire value" do
    assert_raise ArgumentError, ~r/does not match any union variant/, fn ->
      ArchAstro.SDK.Codec.decode(%{"unknown" => true}, {:union, [{:ref, Cat}, {:ref, Dog}]})
    end
  end

  test "discriminated unions reject unknown wire tags" do
    descriptor = {:union, [{:ref, Cat}], {"kind", %{"cat" => Cat}}}

    assert_raise ArgumentError, ~r/does not select a known union variant/, fn ->
      ArchAstro.SDK.Codec.decode(%{"kind" => "bird", "lives" => 9}, descriptor)
    end
  end

  test "generated struct decoding rejects missing required fields" do
    assert_raise ArgumentError, ~r/required fields/, fn ->
      ArchAstro.SDK.Codec.struct_from_map(Cat, %{}, lives: {"lives", :integer})
    end
  end

  test "primitive and collection decoding rejects values outside generated specs" do
    assert_raise ArgumentError, fn -> ArchAstro.SDK.Codec.decode("1", :integer) end
    assert_raise ArgumentError, fn -> ArchAstro.SDK.Codec.decode([1, "2"], {:list, :integer}) end
    assert_raise ArgumentError, fn -> ArchAstro.SDK.Codec.decode("other", {:enum, ["known"]}) end
    assert_raise ArgumentError, fn -> ArchAstro.SDK.Codec.decode("not-a-date", :datetime) end

    assert_raise ArgumentError, fn ->
      ArchAstro.SDK.Codec.decode(%{"count" => "1"}, {:object, [{"count", :integer}]})
    end
  end

  test "OpenAPI number decoding accepts integer and fractional JSON numbers" do
    assert ArchAstro.SDK.Codec.decode(1, :float) == 1
    assert ArchAstro.SDK.Codec.decode(1.5, :float) == 1.5
  end

  test "empty channel object acknowledgements accept Phoenix's ok sentinel" do
    assert :ok = ArchAstro.SDK.Codec.decode(:ok, {:object, []})
    assert %{} = ArchAstro.SDK.Codec.decode(%{}, {:object, []})

    assert_raise ArgumentError, fn ->
      ArchAstro.SDK.Codec.decode(:ok, {:object, [{"id", :string}]})
    end
  end

  test "inline objects omit absent optional fields" do
    descriptor = {:object, [{"name", :string}, {"note", {:optional, :string}}]}
    assert %{"name" => "Ada"} = ArchAstro.SDK.Codec.decode(%{"name" => "Ada"}, descriptor)
  end

  test "datetime union matching agrees with datetime decoding" do
    descriptor = {:union, [:datetime, {:enum, ["not-a-date"]}]}
    assert "not-a-date" = ArchAstro.SDK.Codec.decode("not-a-date", descriptor)
  end
end
