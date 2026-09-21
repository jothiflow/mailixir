defmodule Mailixir.MailerTest do
  use ExUnit.Case, async: false

  alias Mailixir.{Email, TestMailer}

  @email Email.new(from: "a@x.com", to: "b@x.com", subject: "s", text_body: "t")

  setup do
    on_exit(fn -> Application.delete_env(:mailixir, TestMailer) end)
  end

  test "static config is the baseline" do
    assert TestMailer.config() == [adapter: Mailixir.FakeAdapter, api_key: "static"]
  end

  test "app env overrides static, call overrides app env" do
    Application.put_env(:mailixir, TestMailer, api_key: "app", domain: "d")
    assert TestMailer.config()[:api_key] == "app"
    assert TestMailer.config(api_key: "call")[:api_key] == "call"
    assert TestMailer.config()[:domain] == "d"
  end

  test "deliver/2 and deliver!/2 go through Mailixir" do
    assert {:ok, _} = TestMailer.deliver(@email)
    assert_received {:fake_deliver, _, [adapter: Mailixir.FakeAdapter, api_key: "static"]}

    assert %Mailixir.Response{} = TestMailer.deliver!(@email, api_key: "other")
    assert_received {:fake_deliver, _, config}
    assert config[:api_key] == "other"
  end
end
