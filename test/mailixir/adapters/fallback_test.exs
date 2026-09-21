defmodule Mailixir.Adapters.FallbackTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Adapters.Fallback, Email, Error, Response}

  defmodule Flaky do
    @moduledoc false
    use Mailixir.Adapter, provider: :flaky, required_config: [:mode]

    @impl true
    def deliver(email, config) do
      send(self(), {:attempted, config[:name]})

      case config[:mode] do
        :ok -> {:ok, %Response{id: config[:name], provider: :flaky}}
        :transport -> {:error, Error.new(:transport, "down", provider: :flaky)}
        :server -> {:error, Error.new(:api_error, "boom", provider: :flaky, status: 503)}
        :rate -> {:error, Error.new(:api_error, "slow down", provider: :flaky, status: 429)}
        :client -> {:error, Error.new(:api_error, "bad from", provider: :flaky, status: 422)}
      end
    end
  end

  @email Email.new(from: "a@x.com", to: "b@x.com", subject: "s", text_body: "t")

  defp config(modes) do
    adapters = for {name, mode} <- modes, do: [adapter: Flaky, name: name, mode: mode]
    [adapter: Fallback, adapters: adapters]
  end

  test "first success wins" do
    assert {:ok, %Response{id: :a, provider: :flaky}} = Mailixir.deliver(@email, config(a: :ok, b: :ok))
    assert_received {:attempted, :a}
    refute_received {:attempted, :b}
  end

  test "fails over on transport, 5xx and 429 errors" do
    assert {:ok, %Response{id: :d}} = Mailixir.deliver(@email, config(a: :transport, b: :server, c: :rate, d: :ok))
    for name <- [:a, :b, :c, :d], do: assert_received({:attempted, ^name})
  end

  test "does not fail over on 4xx" do
    assert {:error, %Error{status: 422, provider: :flaky}} = Mailixir.deliver(@email, config(a: :client, b: :ok))
    refute_received {:attempted, :b}
  end

  test "all adapters failing returns an aggregate error" do
    assert {:error, %Error{reason: :api_error, provider: :fallback, status: 503, message: message, details: details}} =
             Mailixir.deliver(@email, config(a: :transport, b: :server))

    assert message == "all 2 adapters failed; last: [flaky] boom"
    assert [{Flaky, %Error{reason: :transport}}, {Flaky, %Error{status: 503}}] = details
  end

  test "custom failover policy" do
    config = Keyword.put(config(a: :client, b: :ok), :failover_on, fn %Error{} -> true end)
    assert {:ok, %Response{id: :b}} = Mailixir.deliver(@email, config)
  end

  test "emits failover telemetry" do
    handler = "fallback-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:mailixir, :fallback, :failover],
      fn _, m, meta, _ -> send(parent, {:failover, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Mailixir.deliver(@email, config(a: :transport, b: :ok))
    assert_received {:failover, %{attempt: 1}, %{adapter: Flaky, provider: :flaky, error: %Error{reason: :transport}}}
  end

  test "resolves system env per adapter config" do
    System.put_env("MAILIXIR_FALLBACK_MODE", "ok")
    on_exit(fn -> System.delete_env("MAILIXIR_FALLBACK_MODE") end)

    config = [
      adapter: Fallback,
      adapters: [[adapter: Flaky, name: :env, mode: :transport], [adapter: Flaky, name: :b, mode: :ok]]
    ]

    assert {:ok, %Response{id: :b}} = Mailixir.deliver(@email, config)
  end

  test "validates every adapter config upfront" do
    assert {:error, %Error{reason: :invalid_config, details: [:mode]}} =
             Mailixir.deliver(@email, adapter: Fallback, adapters: [[adapter: Flaky, mode: :ok], [adapter: Flaky]])

    refute_received {:attempted, _}
  end

  test "rejects empty or malformed adapters" do
    assert {:error, %Error{reason: :invalid_config, message: ":adapters must be a non-empty list of adapter configs"}} =
             Mailixir.deliver(@email, adapter: Fallback, adapters: [])

    assert {:error, %Error{reason: :invalid_config, message: "each entry in :adapters needs an :adapter module"}} =
             Mailixir.deliver(@email, adapter: Fallback, adapters: [[mode: :ok]])

    assert {:error, %Error{reason: :invalid_config}} = Mailixir.deliver(@email, adapter: Fallback, adapters: [:nope])
  end
end
