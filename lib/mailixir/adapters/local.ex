defmodule Mailixir.Adapters.Local do
  @moduledoc """
  Development adapter: stores emails in `Mailixir.Local.Mailbox` instead of
  sending them, so they can be browsed with `Mailixir.Plug.Mailbox` or read
  back with `Mailixir.Local.Mailbox.all/0`.

      # config/dev.exs
      config :my_app, MyApp.Mailer, adapter: Mailixir.Adapters.Local

  The response `:id` is the mailbox id of the stored email.
  """

  use Mailixir.Adapter, provider: :local

  alias Mailixir.{Error, Local.Mailbox, Response}

  @impl true
  def validate_config(_config) do
    if Mailbox.running?() do
      :ok
    else
      {:error,
       Error.new(:invalid_config, "Mailixir.Local.Mailbox is not running; is the :mailixir application started?",
         provider: provider()
       )}
    end
  end

  @impl true
  def deliver(email, _config) do
    stored = Mailbox.push(email)
    {:ok, %Response{id: stored.private.mailbox_id, provider: provider(), raw: nil}}
  end
end
