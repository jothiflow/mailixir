defmodule Mailixir.TestAssertions do
  @moduledoc """
  ExUnit helpers for `Mailixir.Adapters.Test`.

      import Mailixir.TestAssertions
  """

  alias Mailixir.{Address, Email}

  @doc """
  Asserts an email was delivered through the test adapter and returns it.

  Accepts a keyword list of expected fields. Address fields (`:from`, `:to`,
  `:cc`, `:bcc`, `:reply_to`) accept any `Mailixir.Address` input and, for
  list fields, match when every expected address is present.

      email = assert_email_sent(to: "jane@example.com", subject: "Welcome")
      assert email.html_body =~ "Hello"
  """
  defmacro assert_email_sent(expected \\ []) do
    quote do
      ExUnit.Assertions.assert_receive({:email, %Mailixir.Email{} = email}, 100)
      Mailixir.TestAssertions.match_fields!(email, unquote(expected))
      email
    end
  end

  @doc "Asserts no email at all was delivered through the test adapter."
  defmacro assert_no_email_sent do
    quote do
      ExUnit.Assertions.refute_receive({:email, %Mailixir.Email{}}, 50)
    end
  end

  @doc """
  Asserts no delivered email matches the given fields. With no fields, same as
  `assert_no_email_sent/0`. Emails that were delivered but do not match stay
  in the mailbox for later assertions.
  """
  defmacro refute_email_sent(expected \\ []) do
    quote do
      Mailixir.TestAssertions.refute_match!(unquote(expected))
    end
  end

  @doc "Returns every email delivered so far, oldest first, without consuming them."
  @spec delivered_emails() :: [Email.t()]
  def delivered_emails do
    {:messages, messages} = Process.info(self(), :messages)
    for {:email, %Email{} = email} <- messages, do: email
  end

  @doc false
  def refute_match!(expected) do
    Process.sleep(50)

    case Enum.filter(delivered_emails(), &match_fields?(&1, expected)) do
      [] ->
        :ok

      [email | _] ->
        raise ExUnit.AssertionError,
          message: "expected no email matching #{inspect(expected)}, but one was sent: #{inspect(email)}"
    end
  end

  @doc false
  @spec match_fields?(Email.t(), keyword()) :: boolean()
  def match_fields?(%Email{} = email, expected) do
    Enum.all?(expected, fn {field, value} -> matches?(field, Map.fetch!(email, field), value) end)
  end

  @doc false
  @spec match_fields!(Email.t(), keyword()) :: :ok
  def match_fields!(%Email{} = email, expected) do
    Enum.each(expected, fn {field, value} ->
      actual = Map.fetch!(email, field)

      unless matches?(field, actual, value) do
        raise ExUnit.AssertionError,
          message: "expected email #{field} to match #{inspect(value)}, got: #{inspect(actual)}"
      end
    end)
  end

  defp matches?(field, actual, expected) when field in [:to, :cc, :bcc] do
    expected = Address.parse_list(expected)
    Enum.all?(expected, &(&1 in actual))
  end

  defp matches?(field, actual, expected) when field in [:from, :reply_to] do
    not is_nil(expected) and actual == Address.parse(expected)
  end

  defp matches?(_field, actual, %Regex{} = regex) when is_binary(actual),
    do: Regex.match?(regex, actual)

  defp matches?(_field, actual, expected), do: actual == expected
end
