defmodule Mailixir.Adapters.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mailixir.{Adapters.Logger, Email, Response}

  @email Email.new(
           from: {"A", "a@x.com"},
           to: ["b@x.com", {"C", "c@x.com"}],
           subject: "Hello",
           text_body: "secret body",
           tags: ["t1"],
           attachments: [{"f.txt", "x"}]
         )

  setup do
    level = Elixir.Logger.level()
    Elixir.Logger.configure(level: :debug)
    on_exit(fn -> Elixir.Logger.configure(level: level) end)
  end

  test "logs a summary without bodies by default" do
    log =
      capture_log([level: :info], fn ->
        assert {:ok, %Response{provider: :logger, id: "logger-" <> _}} =
                 Mailixir.deliver(@email, adapter: Logger, level: :info)
      end)

    assert log =~ "From: A <a@x.com>"
    assert log =~ "To: b@x.com, C <c@x.com>"
    assert log =~ "Subject: Hello"
    assert log =~ "Tags: t1"
    assert log =~ "Attachments: f.txt"
    refute log =~ "secret body"
  end

  test "log_body includes bodies at the configured level" do
    log =
      capture_log([level: :warning], fn ->
        Mailixir.deliver(@email, adapter: Logger, level: :warning, log_body: true)
      end)

    assert log =~ "Text: secret body"
  end
end
