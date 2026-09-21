defmodule Mailixir.TestUser do
  @moduledoc false
  @derive {Mailixir.Recipient, email: :email, name: :full_name}
  defstruct [:full_name, :email]
end

defmodule Mailixir.TestOrg do
  @moduledoc false
  defstruct [:id, :name]
end

defimpl Mailixir.Recipient, for: Mailixir.TestOrg do
  def to_address(org), do: {org.name, "billing+#{org.id}@acme.com"}
end

defmodule Mailixir.TestUnderived do
  @moduledoc false
  defstruct [:email]
end
