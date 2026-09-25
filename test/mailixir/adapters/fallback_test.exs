defmodule Mailixir.Adapters.FallbackTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Adapters.Fallback, Email, Error, Response}

  defmodule Flaky do
    @moduledoc false
    use Mailixir.Adapter, provider: :flaky, required_config: [:mode]

    @impl true
    def deliver(_email, config) do
      send(self(), {:attempted, config[:name]})
      result(config[:mode], config)
    end

    defp result(:ok, config), do: {:ok, %Response{id: config[:name], provider: :flaky}}
    defp result(:refused, _), do: transport(%Req.TransportError{reason: :econnrefused}, "refused")
    defp result(:timeout, _), do: transport(%Req.TransportError{reason: :timeout}, "timeout")
    defp result(:closed, _), do: transport(%Req.TransportError{reason: :closed}, "closed")
    defp result(:unavailable, _), do: http("boom", 503)
    defp result(:rate, _), do: http("slow down", 429)
    defp result(:server, config), do: http("boom", config[:status] || 500)
    defp result(:client, _), do: http("bad from", 422)

    defp transport(details, message) do
      {:error, Error.new(:transport, message, provider: :flaky, details: details)}
    end

    defp http(message, status) do
      {:error, Error.new(:api_error, message, provider: :flaky, status: status)}
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

  test "fails over on a refused connection, 503 and 429" do
    assert {:ok, %Response{id: :d}} =
             Mailixir.deliver(@email, config(a: :refused, b: :unavailable, c: :rate, d: :ok))

    for name <- [:a, :b, :c, :d], do: assert_received({:attempted, ^name})
  end

  test "does not fail over when the provider may already have accepted" do
    for modes <- [[a: :timeout, b: :ok], [a: :closed, b: :ok]] do
      assert {:error, %Error{reason: :transport, provider: :flaky}} = Mailixir.deliver(@email, config(modes))
      refute_received {:attempted, :b}
    end

    for status <- [500, 502, 504] do
      adapters = [
        [adapter: Flaky, name: :a, mode: :server, status: status],
        [adapter: Flaky, name: :b, mode: :ok]
      ]

      assert {:error, %Error{status: ^status, provider: :flaky}} =
               Mailixir.deliver(@email, adapter: Fallback, adapters: adapters)

      refute_received {:attempted, :b}
    end
  end

  test "does not fail over on 4xx" do
    assert {:error, %Error{status: 422, provider: :flaky}} = Mailixir.deliver(@email, config(a: :client, b: :ok))
    refute_received {:attempted, :b}
  end

  test "all adapters failing returns an aggregate error" do
    assert {:error, %Error{reason: :api_error, provider: :fallback, status: 503, message: message, details: details}} =
             Mailixir.deliver(@email, config(a: :refused, b: :unavailable))

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

    Mailixir.deliver(@email, config(a: :refused, b: :ok))
    assert_received {:failover, %{attempt: 1}, %{adapter: Flaky, provider: :flaky, error: %Error{reason: :transport}}}
  end

  test "resolves system env per adapter config" do
    System.put_env("MAILIXIR_FALLBACK_MODE", "ok")
    on_exit(fn -> System.delete_env("MAILIXIR_FALLBACK_MODE") end)

    config = [
      adapter: Fallback,
      adapters: [[adapter: Flaky, name: :env, mode: :refused], [adapter: Flaky, name: :b, mode: :ok]]
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

  describe "Error.not_accepted?/1" do
    defp transport(details) do
      Error.new(:transport, "down", provider: :flaky, details: details)
    end

    defp http(status) do
      Error.new(:api_error, "boom", provider: :flaky, status: status)
    end

    test "a refused connection, DNS failure, unreachable host or TLS handshake was not accepted" do
      for reason <- [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :protocol_not_negotiated] do
        assert Error.not_accepted?(transport(%Req.TransportError{reason: reason})), inspect(reason)
      end

      assert Error.not_accepted?(transport(%Req.TransportError{reason: {:tls_alert, {:handshake_failure, ~c"x"}}}))
      assert Error.not_accepted?(transport(%Req.TransportError{reason: {:bad_alpn_protocol, "h3"}}))
      assert Error.not_accepted?(transport(%Mint.TransportError{reason: :econnrefused}))
      assert Error.not_accepted?(transport(%Finch.TransportError{reason: :nxdomain}))

      assert Error.not_accepted?(transport({:network_failure, "smtp.example", {:error, :econnrefused}}))
      assert Error.not_accepted?(transport({:network_failure, {:error, :enetunreach}}))

      refused = transport(%Req.TransportError{reason: :econnrefused})
      assert Error.transport_reason(refused) == :econnrefused
      assert Error.transport_reason(http(503)) == nil
    end

    test "429 and 503 were not accepted" do
      assert Error.not_accepted?(http(429))
      assert Error.not_accepted?(http(503))
      assert Fallback.failover?(http(503))
    end

    test "a timeout, a close, a reset and any other 5xx may already have been accepted" do
      for reason <- [:timeout, :closed, :econnreset] do
        error = transport(%Req.TransportError{reason: reason})
        refute Error.not_accepted?(error), inspect(reason)
        refute Fallback.failover?(error), inspect(reason)
      end

      refute Error.not_accepted?(transport(%Mint.TransportError{reason: :timeout}))
      refute Error.not_accepted?(transport({:network_failure, "smtp.example", {:error, :timeout}}))
      refute Error.not_accepted?(transport(nil))

      for status <- [500, 502, 504, 422, nil] do
        refute Error.not_accepted?(http(status)), inspect(status)
      end
    end
  end
end
