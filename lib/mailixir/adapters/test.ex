defmodule Mailixir.Adapters.Test do
  @moduledoc """
  Delivers nothing; instead sends `{:email, %Mailixir.Email{}}` to the calling
  process and to every process in its `$callers` chain, so emails sent from a
  `Task` still reach the test.

      config :my_app, MyApp.Mailer, adapter: Mailixir.Adapters.Test

      import Mailixir.TestAssertions

      test "welcome email" do
        Accounts.register(...)
        assert_email_sent(to: "jane@example.com", subject: "Welcome")
      end

  Returns `{:ok, %Mailixir.Response{id: "test-…", provider: :test}}`.
  """

  use Mailixir.Adapter, provider: :test

  alias Mailixir.Response

  @impl true
  def deliver(email, _config) do
    for pid <- Enum.uniq([self() | Process.get(:"$callers", [])]) do
      send(pid, {:email, email})
    end

    {:ok, %Response{id: "test-#{System.unique_integer([:positive])}", provider: :test, raw: nil}}
  end
end
