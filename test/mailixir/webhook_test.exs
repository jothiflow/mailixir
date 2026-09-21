defmodule Mailixir.WebhookTest do
  use ExUnit.Case, async: true

  alias Mailixir.Webhook

  test "header lookup is case-insensitive and accepts maps" do
    assert Webhook.header([{"X-Foo", "1"}], "x-foo") == "1"
    assert Webhook.header(%{"x-foo" => "1"}, "X-FOO") == "1"
    assert Webhook.header([], "x") == nil
  end

  test "unix handles seconds, milliseconds, floats and strings" do
    assert Webhook.unix(1_600_000_000) == ~U[2020-09-13 12:26:40Z]
    assert Webhook.unix(1_600_000_000_500) == ~U[2020-09-13 12:26:40Z]
    assert Webhook.unix(1_600_000_000.9) == ~U[2020-09-13 12:26:40Z]
    assert Webhook.unix("1600000000") == ~U[2020-09-13 12:26:40Z]
    assert Webhook.unix("nope") == nil
    assert Webhook.unix(nil) == nil
  end

  test "iso8601 tolerates spaces, offsets and missing zones" do
    assert Webhook.iso8601("2020-10-09 00:00:00") == ~U[2020-10-09 00:00:00Z]
    assert Webhook.iso8601("2020-10-09T02:00:00+02:00") == ~U[2020-10-09 00:00:00Z]
    assert Webhook.iso8601("2020-10-09T00:00:00.123Z") == ~U[2020-10-09 00:00:00Z]
    assert Webhook.iso8601("garbage") == nil
  end

  test "secure_compare" do
    assert Webhook.secure_compare("abc", "abc")
    refute Webhook.secure_compare("abc", "abd")
    refute Webhook.secure_compare("abc", "ab")
    refute Webhook.secure_compare(nil, "ab")
  end
end
