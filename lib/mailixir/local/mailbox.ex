defmodule Mailixir.Local.Mailbox do
  @moduledoc """
  In-memory store behind `Mailixir.Adapters.Local` and `Mailixir.Plug.Mailbox`.

  Started automatically by the `:mailixir` application. Keeps the most recent
  `#{500}` emails, newest first. Stored emails carry `:mailbox_id` and
  `:received_at` in their `:private` map.
  """

  use GenServer

  alias Mailixir.Email

  @max_size 500

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Stores an email and returns it with `:mailbox_id` / `:received_at` set."
  @spec push(Email.t()) :: Email.t()
  def push(%Email{} = email), do: GenServer.call(__MODULE__, {:push, email})

  @doc "All stored emails, newest first."
  @spec all() :: [Email.t()]
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Fetches one email by its `:mailbox_id`."
  @spec get(String.t()) :: Email.t() | nil
  def get(id) when is_binary(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Removes one email."
  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "Removes every email."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "True when the mailbox process is running."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_call({:push, email}, _from, emails) do
    stored =
      email
      |> Email.put_private(:mailbox_id, generate_id())
      |> Email.put_private(:received_at, DateTime.utc_now(:second))

    {:reply, stored, Enum.take([stored | emails], @max_size)}
  end

  def handle_call(:all, _from, emails), do: {:reply, emails, emails}

  def handle_call({:get, id}, _from, emails) do
    {:reply, Enum.find(emails, &(&1.private.mailbox_id == id)), emails}
  end

  def handle_call({:delete, id}, _from, emails) do
    {:reply, :ok, Enum.reject(emails, &(&1.private.mailbox_id == id))}
  end

  def handle_call(:clear, _from, _emails), do: {:reply, :ok, []}

  defp generate_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
