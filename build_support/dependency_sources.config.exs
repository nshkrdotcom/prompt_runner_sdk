%{
  deps: %{
    agent_session_manager: %{
      path: "../agent_session_manager",
      github: %{repo: "nshkrdotcom/agent_session_manager", branch: "main"},
      hex: "~> 0.12.1",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    cli_subprocess_core: %{
      path: "../cli_subprocess_core",
      github: %{repo: "nshkrdotcom/cli_subprocess_core", branch: "main"},
      hex: "~> 0.5.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    }
  }
}
