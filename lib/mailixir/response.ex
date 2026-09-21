defmodule Mailixir.Response do
  @moduledoc """
  Successful delivery result. `:id` is the provider's message identifier
  when one is returned; `:raw` holds the decoded provider response for anything
  the normalised fields do not cover.

  Ids are normalised with `normalize_id/1` so they compare equal to the
  `message_id` of the `Mailixir.Event`s the provider later sends.
  """

  @enforce_keys [:provider]
  defstruct [:id, :provider, raw: nil]

  @type t :: %__MODULE__{id: String.t() | nil, provider: atom(), raw: term()}

  @doc "Strips RFC 5322 angle brackets (`<id@host>` → `id@host`) and coerces non-strings; `nil` stays `nil`."
  @spec normalize_id(term()) :: String.t() | nil
  def normalize_id(nil), do: nil

  def normalize_id(id) when is_binary(id),
    do: id |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")

  def normalize_id(id), do: id |> to_string() |> normalize_id()
end
