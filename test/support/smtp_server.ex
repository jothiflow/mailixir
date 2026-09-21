defmodule Mailixir.TestSMTPServer do
  @moduledoc """
  Minimal gen_smtp server session used to exercise `Mailixir.Adapters.SMTP`
  end-to-end. Accepted messages are sent to the test process as
  `{:smtp, from, recipients, data}`. Credentials `user` / `pass` are accepted;
  `reject@x.com` is refused at RCPT.
  """

  @behaviour :gen_smtp_server_session

  def start(test_pid) do
    ref = {__MODULE__, make_ref()}

    {:ok, _pid} =
      :gen_smtp_server.start(ref, __MODULE__,
        port: 0,
        address: {127, 0, 0, 1},
        domain: ~c"localhost",
        sessionoptions: [callbackoptions: [pid: test_pid]]
      )

    {ref, :ranch.get_port(ref)}
  end

  def stop(ref), do: :gen_smtp_server.stop(ref)

  @impl true
  def init(hostname, _count, _address, options), do: {:ok, [hostname, " ESMTP test"], %{pid: options[:pid]}}

  @impl true
  def handle_HELO(_hostname, state), do: {:ok, state}

  @impl true
  def handle_EHLO(_hostname, extensions, state), do: {:ok, extensions ++ [{~c"AUTH", ~c"PLAIN LOGIN"}], state}

  @impl true
  def handle_AUTH(type, "user", "pass", state) when type in [:plain, :login], do: {:ok, state}
  def handle_AUTH(_type, _username, _credential, _state), do: :error

  @impl true
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl true
  def handle_MAIL_extension(_extension, _state), do: :error

  @impl true
  def handle_RCPT("reject@x.com", state), do: {:error, ~c"550 No such user here", state}
  def handle_RCPT(_to, state), do: {:ok, state}

  @impl true
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl true
  def handle_DATA(from, to, data, state) do
    send(state.pid, {:smtp, from, to, data})
    {:ok, ~c"queued as test-123", state}
  end

  @impl true
  def handle_RSET(state), do: state

  @impl true
  def handle_VRFY(_address, state), do: {:error, ~c"252 VRFY disabled", state}

  @impl true
  def handle_other(_verb, _args, state), do: {~c"500 Error: command not recognized", state}

  @impl true
  def handle_STARTTLS(state), do: state

  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}

  @impl true
  def terminate(reason, state), do: {:ok, reason, state}
end
