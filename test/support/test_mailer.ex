defmodule Mailixir.TestMailer do
  @moduledoc false
  use Mailixir.Mailer, otp_app: :mailixir, adapter: Mailixir.FakeAdapter, api_key: "static"
end
