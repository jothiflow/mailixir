defmodule Mailixir.Adapters.Logger do
  @moduledoc """
  Development adapter: logs the email instead of sending it.

      config :my_app, MyApp.Mailer,
        adapter: Mailixir.Adapters.Logger,
        level: :debug,      # default :info
        log_body: true      # default false — include text/html bodies
  """

  use Mailixir.Adapter, provider: :logger

  require Logger

  alias Mailixir.{Address, Email, Response}

  @impl true
  def deliver(%Email{} = email, config) do
    level = Keyword.get(config, :level, :info)
    id = "logger-#{System.unique_integer([:positive])}"

    Logger.log(level, fn ->
      ["Mailixir.Adapters.Logger ", id, "\n", summary(email, Keyword.get(config, :log_body, false))]
    end)

    {:ok, %Response{id: id, provider: provider(), raw: nil}}
  end

  @doc false
  @spec summary(Email.t(), boolean()) :: iodata()
  def summary(%Email{} = email, log_body?) do
    lines =
      [
        {"From", email.from && Address.format(email.from)},
        {"To", addresses(email.to)},
        {"Cc", addresses(email.cc)},
        {"Bcc", addresses(email.bcc)},
        {"Reply-To", email.reply_to && Address.format(email.reply_to)},
        {"Subject", email.subject},
        {"Template", email.template && inspect(email.template)},
        {"Tags", if(email.tags != [], do: Enum.join(email.tags, ", "))},
        {"Attachments", if(email.attachments != [], do: Enum.map_join(email.attachments, ", ", & &1.filename))}
      ] ++ if(log_body?, do: [{"Text", email.text_body}, {"HTML", email.html_body}], else: [])

    for {label, value} <- lines, value not in [nil, ""] do
      ["  ", label, ": ", value, "\n"]
    end
  end

  defp addresses([]), do: nil
  defp addresses(list), do: Enum.map_join(list, ", ", &Address.format/1)
end
