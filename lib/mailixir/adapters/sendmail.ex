defmodule Mailixir.Adapters.Sendmail do
  @moduledoc """
  Pipes the MIME-encoded message to a local `sendmail` binary.

  ## Configuration

    * `:path` — defaults to `/usr/sbin/sendmail`
    * `:args` — defaults to `["-i"]`; the sender (`-f`) and every recipient,
      including Bcc, are appended explicitly so `-t` is not needed
    * `:timeout` — not supported; the command runs to completion

  The response `:id` is the generated `Message-ID`; `:raw` is the command output.
  """

  use Mailixir.Adapter, provider: :sendmail

  alias Mailixir.{Email, Error, MIME, Response}

  @default_path "/usr/sbin/sendmail"

  @impl true
  def validate_config(config) do
    path = Keyword.get(config, :path, @default_path)

    if File.exists?(path) do
      :ok
    else
      {:error, Error.new(:invalid_config, "sendmail binary not found at #{path}", provider: provider(), details: path)}
    end
  end

  @impl true
  def deliver(%Email{} = email, config) do
    message_id = MIME.message_id(email)
    {from, recipients} = MIME.envelope(email)
    raw = MIME.encode(email, message_id: message_id)
    path = Keyword.get(config, :path, @default_path)
    args = Keyword.get(config, :args, ["-i"]) ++ ["-f", from, "--" | recipients]

    with_message_file(raw, fn file ->
      # sendmail reads the message until EOF on stdin, which an Erlang port cannot
      # signal without closing the whole port, so the message goes through a file.
      case System.cmd("/bin/sh", ["-c", ~s(exec "$0" "$@" < "$MAILIXIR_MESSAGE"), path | args],
             env: [{"MAILIXIR_MESSAGE", file}],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          {:ok, %Response{id: message_id, provider: provider(), raw: String.trim(output)}}

        {output, status} ->
          {:error,
           Error.new(:api_error, "sendmail exited with status #{status}: #{String.trim(output)}",
             provider: provider(),
             status: status,
             details: output
           )}
      end
    end)
  end

  defp with_message_file(raw, fun) do
    file = Path.join(System.tmp_dir!(), "mailixir-#{System.unique_integer([:positive])}.eml")

    try do
      File.write!(file, raw)
      File.chmod!(file, 0o600)
      fun.(file)
    after
      File.rm(file)
    end
  end
end
