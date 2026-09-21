defmodule Mailixir.RecipientTest do
  use ExUnit.Case, async: true

  alias Mailixir.{Address, Email, TestOrg, TestUnderived, TestUser}

  test "derived struct" do
    assert Address.parse(%TestUser{full_name: "Jane", email: "jane@x.com"}) == {"Jane", "jane@x.com"}
    assert Address.parse(%TestUser{full_name: " ", email: "jane@x.com"}) == {nil, "jane@x.com"}
  end

  test "manual implementation" do
    assert Address.parse(%TestOrg{id: 7, name: "Org"}) == {"Org", "billing+7@acme.com"}
  end

  test "works through Email builders" do
    email = Email.new(from: %TestOrg{id: 1, name: "Acme"}, to: [%TestUser{full_name: "J", email: "j@x.com"}, "k@x.com"])
    assert email.from == {"Acme", "billing+1@acme.com"}
    assert email.to == [{"J", "j@x.com"}, {nil, "k@x.com"}]
  end

  test "underived struct raises with guidance" do
    error = assert_raise Protocol.UndefinedError, fn -> Address.parse(%TestUnderived{email: "x"}) end
    assert Exception.message(error) =~ "@derive {Mailixir.Recipient"
  end
end
