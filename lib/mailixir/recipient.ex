defprotocol Mailixir.Recipient do
  @moduledoc """
  Turns application structs into email addresses so they can be passed
  straight to `Mailixir.Email.to/2` and friends.

  Derive it on any struct with an email field, optionally naming the field
  that holds the display name:

      defmodule MyApp.User do
        @derive {Mailixir.Recipient, email: :email, name: :full_name}
        defstruct [:full_name, :email]
      end

      Mailixir.Email.new(to: %MyApp.User{full_name: "Jane", email: "jane@example.com"})

  Or implement it by hand when the address needs computing:

      defimpl Mailixir.Recipient, for: MyApp.Org do
        def to_address(org), do: {org.name, "billing+\#{org.id}@acme.com"}
      end
  """

  @fallback_to_any true

  @doc "Returns the `{name, email}` tuple for the value."
  @spec to_address(t) :: Mailixir.Address.t()
  def to_address(value)
end

defimpl Mailixir.Recipient, for: Any do
  defmacro __deriving__(module, _struct, opts) do
    email_key = Keyword.fetch!(opts, :email)
    name_key = Keyword.get(opts, :name)

    quote do
      defimpl Mailixir.Recipient, for: unquote(module) do
        def to_address(struct) do
          Mailixir.Address.parse({
            unquote(if name_key, do: quote(do: Map.get(struct, unquote(name_key))), else: nil),
            Map.fetch!(struct, unquote(email_key))
          })
        end
      end
    end
  end

  def to_address(%module{}) do
    raise Protocol.UndefinedError,
      protocol: Mailixir.Recipient,
      value: struct(module),
      description:
        "add `@derive {Mailixir.Recipient, email: :email_field, name: :name_field}` to #{inspect(module)} " <>
          "or implement the protocol for it"
  end

  def to_address(value) do
    raise Protocol.UndefinedError, protocol: Mailixir.Recipient, value: value
  end
end
