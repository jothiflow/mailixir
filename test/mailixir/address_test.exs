defmodule Mailixir.AddressTest do
  use ExUnit.Case, async: true

  alias Mailixir.Address

  describe "parse/1" do
    test "bare email" do
      assert Address.parse(" jane@example.com ") == {nil, "jane@example.com"}
    end

    test "RFC mailbox with and without quotes" do
      assert Address.parse("Jane Doe <jane@example.com>") == {"Jane Doe", "jane@example.com"}

      assert Address.parse(~s("Doe, Jane" <jane@example.com>)) ==
               {"Doe, Jane", "jane@example.com"}

      assert Address.parse("<jane@example.com>") == {nil, "jane@example.com"}
    end

    test "tuples and maps" do
      assert Address.parse({"Jane", "jane@example.com"}) == {"Jane", "jane@example.com"}
      assert Address.parse({"  ", "jane@example.com"}) == {nil, "jane@example.com"}

      assert Address.parse(%{name: "Jane", email: "jane@example.com"}) ==
               {"Jane", "jane@example.com"}

      assert Address.parse(%{"email" => "jane@example.com"}) == {nil, "jane@example.com"}
    end

    test "rejects garbage" do
      assert_raise ArgumentError, fn -> Address.parse(42) end
    end
  end

  test "parse_list/1 wraps singles and maps lists" do
    assert Address.parse_list(nil) == []
    assert Address.parse_list("a@x.com") == [{nil, "a@x.com"}]

    assert Address.parse_list(["a@x.com", {"B", "b@x.com"}]) == [
             {nil, "a@x.com"},
             {"B", "b@x.com"}
           ]
  end

  describe "format/1" do
    test "plain and named" do
      assert Address.format({nil, "a@x.com"}) == "a@x.com"
      assert Address.format({"Jane Doe", "a@x.com"}) == "Jane Doe <a@x.com>"
    end

    test "quotes names with specials" do
      assert Address.format({"Doe, Jane", "a@x.com"}) == ~s("Doe, Jane" <a@x.com>)
      assert Address.format({~s(Say "hi"), "a@x.com"}) == ~s("Say \\"hi\\"" <a@x.com>)
    end
  end
end
