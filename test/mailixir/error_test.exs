defmodule Mailixir.ErrorTest do
  use ExUnit.Case, async: true

  alias Mailixir.Error

  test "message includes provider when present" do
    assert Exception.message(Error.new(:api_error, "boom")) == "boom"

    assert Exception.message(Error.new(:api_error, "boom", provider: :resend, status: 422)) ==
             "[resend] boom"
  end

  test "is raisable" do
    assert_raise Error, "[brevo] nope", fn ->
      raise Error.new(:transport, "nope", provider: :brevo)
    end
  end
end
