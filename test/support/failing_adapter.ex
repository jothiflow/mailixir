defmodule Mailixir.FailingAdapter do
  @moduledoc false
  use Mailixir.Adapter, provider: :failing

  @impl true
  def deliver(%{subject: "fail"}, _config), do: {:error, Mailixir.Error.new(:api_error, "nope", provider: :failing)}
  def deliver(email, _config), do: {:ok, %Mailixir.Response{id: email.subject, provider: :failing}}
end

defmodule Mailixir.BatchAdapter do
  @moduledoc false
  use Mailixir.Adapter, provider: :batch

  @impl true
  def deliver(_email, _config), do: raise("deliver/2 should not be called")

  @impl true
  def deliver_many(emails, _config) do
    send(self(), {:batch, length(emails)})
    {:ok, Enum.map(emails, &%Mailixir.Response{id: &1.subject, provider: :batch})}
  end
end
