defmodule Mailixir.Adapters.SMTPTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Adapters.SMTP, Email, Error, Response, TestSMTPServer}

  setup do
    {server, port} = TestSMTPServer.start(self())
    on_exit(fn -> TestSMTPServer.stop(server) end)

    config = [
      adapter: SMTP,
      relay: "127.0.0.1",
      port: port,
      username: "user",
      password: "pass",
      auth: :always,
      tls: :never,
      no_mx_lookups: true
    ]

    {:ok, config: config}
  end

  @email Email.new(
           from: {"Acme", "a@x.com"},
           to: "b@x.com",
           cc: "c@x.com",
           bcc: "hidden@x.com",
           subject: "Héllo",
           text_body: "Body café"
         )

  test "delivers over a real SMTP session", %{config: config} do
    assert {:ok, %Response{provider: :smtp, id: id, raw: "queued as test-123"}} = Mailixir.deliver(@email, config)
    assert id =~ ~r/^[0-9a-f]{24}@x\.com$/

    assert_receive {:smtp, "a@x.com", recipients, data}, 2_000
    assert Enum.sort(recipients) == ["b@x.com", "c@x.com", "hidden@x.com"]
    assert data =~ "Message-ID: <#{id}>"
    assert data =~ "Subject: =?UTF-8?B?"
    assert data =~ "Body caf=C3=A9"
    refute data =~ "hidden@x.com"
  end

  test "server rejection becomes an api_error", %{config: config} do
    email = Email.new(from: "a@x.com", to: "reject@x.com", subject: "s", text_body: "t")

    assert {:error, %Error{reason: :api_error, provider: :smtp, message: message}} = Mailixir.deliver(email, config)
    assert message =~ "permanent_failure on 127.0.0.1: 550 No such user here"
  end

  test "bad credentials", %{config: config} do
    assert {:error, %Error{reason: :api_error, message: message}} =
             Mailixir.deliver(@email, Keyword.put(config, :password, "wrong"))

    assert message =~ ~r/auth/i
  end

  test "connection refused is a transport error", %{config: config} do
    assert {:error, %Error{reason: :transport, provider: :smtp, message: ":econnrefused connecting to 127.0.0.1"}} =
             Mailixir.deliver(@email, Keyword.merge(config, port: 1, retries: 0))
  end

  test "missing relay" do
    assert {:error, %Error{reason: :invalid_config, details: [:relay]}} = Mailixir.deliver(@email, adapter: SMTP)
  end

  test "client_options picks the port from ssl" do
    assert SMTP.client_options(relay: "r")[:port] == 25
    assert SMTP.client_options(relay: "r", ssl: true)[:port] == 465
    assert SMTP.client_options(relay: "r", ssl: true, port: 2465)[:port] == 2465
    refute Keyword.has_key?(SMTP.client_options(relay: "r", adapter: SMTP, api_key: "x"), :api_key)
  end
end
