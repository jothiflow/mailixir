defmodule Mailixir.TelemetryTest do
  use ExUnit.Case, async: false

  alias Mailixir.{Email, FakeAdapter, TestMailer}

  @email Email.new(from: "a@x.com", to: "b@x.com", subject: "s", text_body: "t")

  setup do
    handler = "test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler,
      [[:mailixir, :deliver, :start], [:mailixir, :deliver, :stop], [:mailixir, :deliver_many, :stop]],
      fn event, measurements, metadata, _ -> send(parent, {:telemetry, event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "deliver emits start and stop with result and mailer" do
    assert {:ok, response} = TestMailer.deliver(@email)

    assert_received {:telemetry, [:mailixir, :deliver, :start], %{system_time: _}, start}
    assert start.email == @email
    assert start.adapter == FakeAdapter
    assert start.provider == :fake
    assert start.mailer == TestMailer
    refute Map.has_key?(start, :config)

    assert_received {:telemetry, [:mailixir, :deliver, :stop], %{duration: _}, stop}
    assert stop.result == {:ok, response}
  end

  test "custom telemetry metadata is merged" do
    Mailixir.deliver(@email, [adapter: FakeAdapter, api_key: "k"], telemetry_metadata: %{tenant: "t1"})
    assert_received {:telemetry, [:mailixir, :deliver, :start], _, %{tenant: "t1", mailer: nil}}
  end

  test "nothing is emitted when validation fails" do
    Mailixir.deliver(Email.new(), adapter: FakeAdapter, api_key: "k")
    refute_received {:telemetry, _, _, _}
  end

  test "deliver_many emits count" do
    TestMailer.deliver_many([@email, @email])
    assert_received {:telemetry, [:mailixir, :deliver_many, :stop], _, %{count: 2, result: {:ok, [_, _]}}}
  end
end
