defmodule Mailixir.Adapters.TestTest do
  use ExUnit.Case, async: true

  import Mailixir.TestAssertions
  alias Mailixir.{Adapters, Email, Response}

  @config [adapter: Adapters.Test]
  @email Email.new(
           from: {"A", "a@x.com"},
           to: ["b@x.com", "c@x.com"],
           subject: "Hello",
           text_body: "t"
         )

  test "sends the email to the caller" do
    assert {:ok, %Response{provider: :test, id: "test-" <> _}} = Mailixir.deliver(@email, @config)
    assert assert_email_sent() == @email
  end

  test "reaches the test process from a Task" do
    Task.async(fn -> Mailixir.deliver(@email, @config) end) |> Task.await()
    assert_email_sent(subject: "Hello")
  end

  test "field matching" do
    Mailixir.deliver(@email, @config)

    email =
      assert_email_sent(
        from: "A <a@x.com>",
        to: "c@x.com",
        subject: ~r/hel/i,
        text_body: "t"
      )

    assert email.subject == "Hello"
  end

  test "mismatch raises with a useful message" do
    Mailixir.deliver(@email, @config)

    error = assert_raise ExUnit.AssertionError, fn -> assert_email_sent(subject: "Nope") end
    assert error.message =~ ~s(expected email subject to match "Nope", got: "Hello")
  end

  test "assert_no_email_sent and refute_email_sent" do
    assert_no_email_sent()
    refute_email_sent()

    Mailixir.deliver(@email, @config)
    refute_email_sent(subject: "Other")
    assert [%Email{subject: "Hello"}] = delivered_emails()

    error = assert_raise ExUnit.AssertionError, fn -> refute_email_sent(to: "b@x.com") end
    assert error.message =~ "expected no email matching"
    assert_email_sent(subject: "Hello")
  end
end
