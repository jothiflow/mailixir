%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/", "mix.exs"]},
      strict: true,
      checks: %{
        extra: [
          # gen_smtp_server_session dictates handle_HELO/handle_DATA/... names.
          {Credo.Check.Readability.FunctionNames, files: %{excluded: ["test/support/smtp_server.ex"]}}
        ]
      }
    }
  ]
}
