defmodule Mailixir.Address do
  @moduledoc """
  Normalises the many shapes an email address can take into a `{name, email}` tuple.

  Accepted inputs:

    * `"jane@example.com"`
    * `"Jane Doe <jane@example.com>"`
    * `{"Jane Doe", "jane@example.com"}`
    * `{nil, "jane@example.com"}`
    * `%{name: "Jane Doe", email: "jane@example.com"}`
    * `%{"name" => ..., "email" => ...}`
    * any struct implementing `Mailixir.Recipient`
  """

  @type t :: {String.t() | nil, String.t()}
  @type input :: String.t() | t() | %{optional(:name | String.t()) => String.t() | nil} | struct()

  @doc """
  Parses one address into a `{name, email}` tuple.

  Raises `ArgumentError` on input it cannot interpret.
  """
  @spec parse(input()) :: t()
  def parse({name, email}) when is_binary(email) and (is_binary(name) or is_nil(name)),
    do: {blank_to_nil(name), String.trim(email)}

  def parse(%_{} = struct), do: Mailixir.Recipient.to_address(struct)
  def parse(%{email: email} = map), do: parse({Map.get(map, :name), email})
  def parse(%{"email" => email} = map), do: parse({Map.get(map, "name"), email})

  def parse(string) when is_binary(string) do
    case Regex.run(~r/^\s*(?:"?([^"<]*?)"?\s*)?<([^>]+)>\s*$/, string) do
      [_, name, email] -> {blank_to_nil(name), String.trim(email)}
      nil -> {nil, String.trim(string)}
    end
  end

  def parse(other) do
    raise ArgumentError, "cannot interpret #{inspect(other)} as an email address"
  end

  @doc "Parses a single address or a list of addresses into a list of tuples."
  @spec parse_list(input() | [input()] | nil) :: [t()]
  def parse_list(nil), do: []
  def parse_list(list) when is_list(list), do: Enum.map(list, &parse/1)
  def parse_list(single), do: [parse(single)]

  @doc """
  Formats a tuple as an RFC 5322 mailbox: `Jane Doe <jane@example.com>`.

  Display names containing special characters are quoted.
  """
  @spec format(t()) :: String.t()
  def format({nil, email}), do: email
  def format({name, email}), do: "#{quote_name(name)} <#{email}>"

  @doc "Returns just the email part of a tuple."
  @spec email(t()) :: String.t()
  def email({_name, email}), do: email

  @doc "Returns just the display name of a tuple (may be `nil`)."
  @spec name(t()) :: String.t() | nil
  def name({name, _email}), do: name

  defp quote_name(name) do
    if Regex.match?(~r/[^\w\s.'-]/u, name) do
      ~s("#{String.replace(name, ~s("), ~s(\\"))}")
    else
      name
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
