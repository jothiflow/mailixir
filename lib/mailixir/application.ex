defmodule Mailixir.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Mailixir.Local.Mailbox], strategy: :one_for_one, name: Mailixir.Supervisor)
  end
end
