defmodule MailixirTest do
  use ExUnit.Case, async: false

  alias Mailixir.{Email, Error, FakeAdapter, Response}

  @email Email.new(from: "a@x.com", to: "b@x.com", subject: "s", text_body: "t")

  describe "deliver/2" do
    test "runs the adapter with resolved config" do
      System.put_env("MAILIXIR_TEST_KEY", "from-env")
      on_exit(fn -> System.delete_env("MAILIXIR_TEST_KEY") end)

      assert {:ok, %Response{id: "fake-1", provider: :fake}} =
               Mailixir.deliver(@email,
                 adapter: FakeAdapter,
                 api_key: {:system, "MAILIXIR_TEST_KEY"},
                 region: {:system, "MAILIXIR_MISSING", "eu"}
               )

      assert_received {:fake_deliver, @email, config}
      assert config[:api_key] == "from-env"
      assert config[:region] == "eu"
    end

    test "missing env var" do
      assert {:error, %Error{reason: :invalid_config, message: message}} =
               Mailixir.deliver(@email, adapter: FakeAdapter, api_key: {:system, "MAILIXIR_NOPE"})

      assert message =~ "MAILIXIR_NOPE"
    end

    test "missing or bogus adapter" do
      assert {:error, %Error{reason: :invalid_config, message: "config is missing :adapter"}} =
               Mailixir.deliver(@email, [])

      assert {:error, %Error{reason: :invalid_config, message: msg}} =
               Mailixir.deliver(@email, adapter: Enum)

      assert msg =~ "not a Mailixir.Adapter"
    end

    test "adapter config validation runs before email validation" do
      assert {:error, %Error{reason: :invalid_config, provider: :fake, details: [:api_key]}} =
               Mailixir.deliver(Email.new(), adapter: FakeAdapter)
    end

    test "email validation" do
      assert {:error, %Error{reason: :invalid_email}} =
               Mailixir.deliver(Email.new(), adapter: FakeAdapter, api_key: "k")

      refute_received {:fake_deliver, _, _}
    end
  end

  test "deliver!/2 raises" do
    assert %Response{} = Mailixir.deliver!(@email, adapter: FakeAdapter, api_key: "k")

    assert_raise Error, ~r/from is required/, fn ->
      Mailixir.deliver!(Email.new(), adapter: FakeAdapter, api_key: "k")
    end
  end
end

defmodule Mailixir.DeliverManyTest do
  use ExUnit.Case, async: true

  alias Mailixir.{BatchAdapter, Email, Error, FailingAdapter, Response}

  defp email(subject), do: Email.new(from: "a@x.com", to: "b@x.com", subject: subject, text_body: "t")

  test "sequential fallback collects responses" do
    assert {:ok, [%Response{id: "1"}, %Response{id: "2"}]} =
             Mailixir.deliver_many([email("1"), email("2")], adapter: FailingAdapter)
  end

  test "partial failure returns batch_failure with ordered results" do
    assert {:error,
            %Error{reason: :batch_failure, provider: :failing, message: "1 of 3 emails failed", details: results}} =
             Mailixir.deliver_many([email("1"), email("fail"), email("3")], adapter: FailingAdapter)

    assert [{:ok, %Response{id: "1"}}, {:error, %Error{message: "nope"}}, {:ok, %Response{id: "3"}}] = results
  end

  test "uses the adapter batch callback when present" do
    assert {:ok, [_, _, _]} = Mailixir.deliver_many([email("a"), email("b"), email("c")], adapter: BatchAdapter)
    assert_received {:batch, 3}
  end

  test "validates every email before sending anything" do
    assert {:error, %Error{reason: :invalid_email, message: "email at index 1: " <> _}} =
             Mailixir.deliver_many([email("ok"), Email.new()], adapter: BatchAdapter)

    refute_received {:batch, _}
  end

  test "deliver_many! raises" do
    assert [%Response{}] = Mailixir.deliver_many!([email("x")], adapter: FailingAdapter)

    assert_raise Error, ~r/1 of 1 emails failed/, fn ->
      Mailixir.deliver_many!([email("fail")], adapter: FailingAdapter)
    end
  end
end
