defmodule Mailixir.Adapters.SendmailTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Adapters.Sendmail, Email, Error, Response}

  @email Email.new(from: "a@x.com", to: "b@x.com", bcc: "hidden@x.com", subject: "Hi", text_body: "Body")

  setup do
    dir = Path.join(System.tmp_dir!(), "mailixir-sendmail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    ok = Path.join(dir, "sendmail")
    File.write!(ok, "#!/bin/sh\ncat > #{dir}/message.eml\necho \"$@\" > #{dir}/args\necho accepted\n")
    File.chmod!(ok, 0o755)

    failing = Path.join(dir, "sendmail-fail")
    File.write!(failing, "#!/bin/sh\necho 'cannot deliver' >&2\nexit 75\n")
    File.chmod!(failing, 0o755)

    {:ok, dir: dir, ok: ok, failing: failing}
  end

  test "pipes the message and passes sender and all recipients", %{dir: dir, ok: path} do
    assert {:ok, %Response{provider: :sendmail, id: id, raw: "accepted"}} =
             Mailixir.deliver(@email, adapter: Sendmail, path: path)

    assert File.read!(Path.join(dir, "args")) |> String.trim() == "-i -f a@x.com -- b@x.com hidden@x.com"
    message = File.read!(Path.join(dir, "message.eml"))
    assert message =~ "Message-ID: <#{id}>"
    assert message =~ "Subject: Hi"
    refute message =~ "hidden@x.com"
    refute dir |> File.ls!() |> Enum.any?(&String.ends_with?(&1, ".eml.tmp"))
  end

  test "custom args", %{dir: dir, ok: path} do
    Mailixir.deliver!(@email, adapter: Sendmail, path: path, args: ["-i", "-oi"])
    assert File.read!(Path.join(dir, "args")) =~ "-i -oi -f a@x.com"
  end

  test "non-zero exit", %{failing: path} do
    assert {:error, %Error{reason: :api_error, provider: :sendmail, status: 75, message: message}} =
             Mailixir.deliver(@email, adapter: Sendmail, path: path)

    assert message == "sendmail exited with status 75: cannot deliver"
  end

  test "missing binary" do
    assert {:error, %Error{reason: :invalid_config, message: "sendmail binary not found at /nope/sendmail"}} =
             Mailixir.deliver(@email, adapter: Sendmail, path: "/nope/sendmail")
  end
end
