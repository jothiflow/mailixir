defmodule Mailixir.FakeAdapter do
  @moduledoc false
  use Mailixir.Adapter, provider: :fake, required_config: [:api_key]

  @impl true
  def deliver(email, config) do
    send(self(), {:fake_deliver, email, config})
    {:ok, %Mailixir.Response{id: "fake-1", provider: :fake}}
  end
end
